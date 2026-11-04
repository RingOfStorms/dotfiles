package term

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/coder/websocket"
)

// The protocol, one WebSocket per attached browser:
//
//	browser -> server  ?id=…&from=N&gen=G     the session, the first output byte the browser
//	                                          still needs, and the generation of the attachment
//	                                          that last drew its screen (0: none)
//	server -> browser  binary                 output bytes, contiguous from the last offset
//	                   {"t":"hello","id":…,"gen":G}  first message: the session id to
//	                                          reconnect with and this attachment's generation
//	                   {"t":"reset","at":N}   the requested offset is gone: clear the screen;
//	                                          the next output starts at byte N
//	                   {"t":"replay","until":N}  output before byte N is history being
//	                                          redrawn: do not answer the terminal
//	                                          queries in it
//	                   {"t":"exit","code":N}  the shell ended (after its last output)
//	                   close 4001             another browser attached to this session
//	browser -> server  binary                 input bytes
//	                   {"t":"resize","cols":C,"rows":R}
//	                   {"t":"close"}          end the shell
//
// The browser counts the output bytes it has written to its screen; that
// count is the `from` it reconnects with. It keeps the generation from hello
// with its screen (in memory: a reload has no screen) and reconnects with it.
//
// Output contains terminal queries (cursor position, colours, device
// attributes), and xterm.js answers them as input. That is right for output
// the shell writes now, but output redrawn from the buffer was asked long ago,
// often by a program that has since exited: answering it again types the
// replies into whatever runs now. So the server marks history explicitly:
// after hello on a reload (from 0 into a shell this browser did not just
// start) and after every reset, it sends replay with the buffer's end at that
// moment, and no binary message straddles that offset. The browser drops what
// its terminal says until it has parsed every byte before it.
//
// A reconnect from a nonzero offset is a continuation, but another browser
// may have had the shell in between: then gen is not the attachment this one
// replaces. Output that was written to the other browser was answered there
// (written to its socket counts; whether it was shown is unknown), so it is
// history up to how far the session had delivered output when this browser
// attached. The session keeps its newest replay boundary, and a continuation
// that starts before it gets the rest as history again (the same replay
// message), so a socket dropped during a redraw does not turn its remainder
// live. Everything else is live: a new shell's output, and a continuation's
// output nobody was sent, whose queries (asked while no browser was attached)
// are still waiting for an answer.

// StatusTakenOver closes a socket whose session was attached elsewhere.
const StatusTakenOver websocket.StatusCode = 4001

// errKicked is writeOutput refusing to draw on a screen that lost the shell.
var errKicked = errors.New("attached elsewhere")

type message struct {
	T     string `json:"t"`
	ID    string `json:"id,omitempty"`
	Gen   uint64 `json:"gen,omitempty"`
	At    int64  `json:"at,omitempty"`
	Until int64  `json:"until,omitempty"`
	Code  *int   `json:"code,omitempty"`
	Cols  int    `json:"cols,omitempty"`
	Rows  int    `json:"rows,omitempty"`
}

const (
	maxFrame     = 64 << 10
	writeTimeout = 20 * time.Second
	pingEvery    = 25 * time.Second
)

// Serve attaches the browser on c to the session and runs the protocol until
// the socket closes, the shell ends, or another browser takes over. from is
// the first output byte the browser still needs and last the generation of
// the attachment that last drew its screen. created says the shell was
// started for this browser, so all of its output is live; otherwise from 0
// means a browser that lost its screen, and the buffered output is history.
func (s *Session) Serve(ctx context.Context, c *websocket.Conn, from int64, last uint64, created bool) {
	gen, history, kicked := s.attach(last)
	defer s.detach(gen)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer c.CloseNow()

	// A pasted block arrives as one message.
	c.SetReadLimit(1 << 20)
	go func() {
		defer cancel()
		s.readLoop(ctx, c, kicked)
	}()
	// Pings keep proxies from timing out an idle shell and notice a phone
	// that vanished without closing its socket.
	go func() {
		t := time.NewTicker(pingEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				pctx, done := context.WithTimeout(ctx, writeTimeout)
				err := c.Ping(pctx)
				done()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()

	if writeJSON(ctx, c, message{T: "hello", ID: s.ID, Gen: gen}) != nil {
		return
	}
	redraw := !created && from == 0 // everything buffered now is history
	var until int64                 // output before this offset is history
	if !created && from > 0 {
		until = history
	}
	announce := until > from
	for {
		size := maxFrame
		if from < until {
			size = min(size, int(until-from))
		}
		ch, exited, code, wait := s.since(from, size)
		if ch.Reset {
			if writeJSON(ctx, c, message{T: "reset", At: ch.At}) != nil {
				return
			}
			redraw = true
		}
		if redraw {
			redraw = false
			until = ch.End
			announce = ch.End > ch.At
		}
		// ch.Data ends at or before ch.End, and chunks are capped at until,
		// so every binary message is either all history or all live.
		if announce {
			announce = false
			s.replayed(gen, until)
			if writeJSON(ctx, c, message{T: "replay", Until: until}) != nil {
				return
			}
		}
		if len(ch.Data) > 0 {
			if err := s.writeOutput(ctx, c, kicked, ch.Data, ch.Next); err != nil {
				if err == errKicked {
					_ = c.Close(StatusTakenOver, "attached elsewhere")
				}
				return
			}
		}
		from = ch.Next
		if ch.More {
			continue
		}
		if exited {
			if writeJSON(ctx, c, message{T: "exit", Code: &code}) == nil {
				_ = c.Close(websocket.StatusNormalClosure, "shell exited")
			}
			return
		}
		select {
		case <-wait:
		case <-kicked:
			_ = c.Close(StatusTakenOver, "attached elsewhere")
			return
		case <-ctx.Done():
			return
		}
	}
}

// readLoop forwards the browser's input until the socket ends. Once another
// browser has taken over, input is dropped: it is this screen's answers to
// output that is the new attachment's to answer. The check is not ordered
// with the shell, so input already read when the takeover happens may still
// reach it.
func (s *Session) readLoop(ctx context.Context, c *websocket.Conn, kicked <-chan struct{}) {
	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		select {
		case <-kicked:
			continue
		default:
		}
		switch typ {
		case websocket.MessageBinary:
			if s.Write(data) != nil {
				return
			}
		case websocket.MessageText:
			var m message
			if json.Unmarshal(data, &m) != nil {
				continue
			}
			switch m.T {
			case "resize":
				_ = s.Resize(m.Cols, m.Rows)
			case "close":
				s.Kill()
			}
		}
	}
}

func writeJSON(ctx context.Context, c *websocket.Conn, m message) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return c.Write(ctx, websocket.MessageText, b)
}

// writeOutput writes output ending at next to the socket of the attachment
// kicked belongs to and counts it as delivered, unless that attachment has
// been taken over: then it writes nothing and returns errKicked.
func (s *Session) writeOutput(ctx context.Context, c *websocket.Conn, kicked <-chan struct{}, data []byte, next int64) error {
	s.out.Lock()
	defer s.out.Unlock()
	select {
	case <-kicked:
		return errKicked
	default:
	}
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	if err := c.Write(ctx, websocket.MessageBinary, data); err != nil {
		return err
	}
	s.mu.Lock()
	s.delivered = max(s.delivered, next)
	s.mu.Unlock()
	return nil
}
