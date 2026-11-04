package term

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// harness serves one Manager the way the web handler does: ?id=, ?from= and
// ?gen=.
type harness struct {
	m   *Manager
	srv *httptest.Server
}

func newHarness(t *testing.T, cfg Config) *harness {
	t.Helper()
	if cfg.Shell == "" {
		cfg.Shell = "/bin/sh"
	}
	if cfg.Dir == "" {
		cfg.Dir = t.TempDir()
	}
	// A predictable prompt-free shell: no rc files, no PS1 noise to match.
	cfg.Env = append(ShellEnv(os.Environ()), "PS1=", "ENV=/dev/null", "HOME="+cfg.Dir)
	h := &harness{m: NewManager(cfg)}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		from, _ := strconv.ParseInt(q.Get("from"), 10, 64)
		last, _ := strconv.ParseUint(q.Get("gen"), 10, 64)
		s, created, err := h.m.Open(q.Get("id"), 80, 24)
		if err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		if created {
			from = 0
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		s.Serve(r.Context(), c, from, last, created)
	}))
	t.Cleanup(func() {
		h.srv.Close()
		h.m.Close()
	})
	return h
}

// client is one browser: it counts output bytes like term.js does.
type client struct {
	t       *testing.T
	c       *websocket.Conn
	id      string
	gen     uint64 // from hello: the attachment drawing this screen
	offset  int64
	screen  bytes.Buffer // output since the dial (or the last reset)
	resets  []int64
	replays []int64 // replay boundaries, in arrival order
	exit    *int
}

// dial attaches a browser with no screen of its own but what from says.
func (h *harness) dial(t *testing.T, id string, from int64) *client {
	t.Helper()
	return h.open(t, id, from, 0)
}

// reconnect is cl's page coming back after its socket dropped: the same
// screen, so the same offset and attachment generation.
func (h *harness) reconnect(t *testing.T, cl *client) *client {
	t.Helper()
	return h.open(t, cl.id, cl.offset, cl.gen)
}

func (h *harness) open(t *testing.T, id string, from int64, gen uint64) *client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.srv.URL, "http") + "/?id=" + id +
		"&from=" + strconv.FormatInt(from, 10) + "&gen=" + strconv.FormatUint(gen, 10)
	c, resp, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		var body []byte
		if resp != nil && resp.Body != nil {
			body, _ = io.ReadAll(resp.Body)
		}
		t.Fatalf("%v: %s", err, body)
	}
	cl := &client{t: t, c: c, offset: from}
	t.Cleanup(func() { c.CloseNow() })
	cl.next(5 * time.Second)
	if cl.id == "" {
		t.Fatal("no hello")
	}
	return cl
}

// session returns the live session with this id.
func (h *harness) session(t *testing.T, id string) *Session {
	t.Helper()
	h.m.mu.Lock()
	s := h.m.sessions[id]
	h.m.mu.Unlock()
	if s == nil {
		t.Fatalf("no session %s", id)
	}
	return s
}

// waitLocked polls cond under the session lock.
func waitLocked(t *testing.T, s *Session, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.mu.Lock()
		ok := cond()
		s.mu.Unlock()
		if ok {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// next reads one message; it returns the close error when the socket ends.
func (cl *client) next(timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	typ, data, err := cl.c.Read(ctx)
	if err != nil {
		return err
	}
	if typ == websocket.MessageBinary {
		if n := len(cl.replays); n > 0 {
			if until := cl.replays[n-1]; cl.offset < until && cl.offset+int64(len(data)) > until {
				cl.t.Fatalf("output [%d,%d) straddles the replay boundary %d", cl.offset, cl.offset+int64(len(data)), until)
			}
		}
		cl.offset += int64(len(data))
		cl.screen.Write(data)
		return nil
	}
	var m message
	if err := json.Unmarshal(data, &m); err != nil {
		cl.t.Fatal(err)
	}
	switch m.T {
	case "hello":
		cl.id = m.ID
		cl.gen = m.Gen
	case "reset":
		cl.resets = append(cl.resets, m.At)
		cl.offset = m.At
		cl.screen.Reset()
	case "replay":
		cl.replays = append(cl.replays, m.Until)
	case "exit":
		cl.exit = m.Code
	}
	return nil
}

func (cl *client) input(s string) {
	cl.t.Helper()
	if err := cl.c.Write(context.Background(), websocket.MessageBinary, []byte(s)); err != nil {
		cl.t.Fatal(err)
	}
}

// waitFor reads until the screen contains want.
func (cl *client) waitFor(want string) {
	cl.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(cl.screen.String(), want) {
		if time.Now().After(deadline) {
			cl.t.Fatalf("screen never showed %q; got %q", want, cl.screen.String())
		}
		if err := cl.next(time.Until(deadline)); err != nil {
			cl.t.Fatalf("socket ended waiting for %q: %v (screen %q)", want, err, cl.screen.String())
		}
	}
}

// closed reads until the socket ends and returns its close status.
func (cl *client) closed() websocket.StatusCode {
	cl.t.Helper()
	for {
		if err := cl.next(5 * time.Second); err != nil {
			return websocket.CloseStatus(err)
		}
	}
}

// at is the output offset of the last want on a screen that has had no
// reset since the dial, or -1.
func (cl *client) at(dialedFrom int64, want string) int64 {
	i := strings.LastIndex(cl.screen.String(), want)
	if i < 0 {
		return -1
	}
	return dialedFrom + int64(i)
}

func TestReconnectContinuesFromOffset(t *testing.T) {
	h := newHarness(t, Config{})
	a := h.dial(t, "", 0)
	a.input("echo one-$((1+1))\n")
	a.waitFor("one-2")
	a.c.Close(websocket.StatusNormalClosure, "")

	// Output produced while nobody is attached is kept.
	s, _, err := h.m.Open(a.id, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Write([]byte("echo two-$((2+1))\n")); err != nil {
		t.Fatal(err)
	}

	b := h.reconnect(t, a)
	if b.id != a.id {
		t.Fatalf("reconnect got a new shell %s, want %s", b.id, a.id)
	}
	b.waitFor("two-3")
	if len(b.resets) != 0 {
		t.Fatalf("continuation sent a reset: %v", b.resets)
	}
	if strings.Contains(b.screen.String(), "one-2") {
		t.Fatalf("continuation replayed output the browser already had: %q", b.screen.String())
	}
}

func TestReplayAfterScrollbackOverflowResets(t *testing.T) {
	h := newHarness(t, Config{Scrollback: 1024})
	a := h.dial(t, "", 0)
	// Far more than the buffer keeps.
	a.input("i=0; while [ $i -lt 400 ]; do echo line-$i; i=$((i+1)); done; echo done-$((6*7))\n")
	a.waitFor("done-42")

	// A browser without its screen (from=0) gets what is left, from a line
	// boundary, behind a reset.
	b := h.dial(t, a.id, 0)
	b.waitFor("done-42")
	if len(b.resets) != 1 || b.resets[0] == 0 {
		t.Fatalf("resets = %v, want one reset past byte 0", b.resets)
	}
	if strings.Contains(b.screen.String(), "line-0\r\n") {
		t.Fatal("replay contains output older than the scrollback limit")
	}
	if len(b.replays) != 1 || b.replays[0] <= b.resets[0] {
		t.Fatalf("replays = %v after reset at %d, want one boundary past it", b.replays, b.resets[0])
	}

	// A reconnect whose offset fell out of the buffer is redrawn the same
	// way: what it gets is history, not the continuation it asked for.
	c := h.dial(t, a.id, 1)
	c.waitFor("done-42")
	if len(c.resets) != 1 || len(c.replays) != 1 {
		t.Fatalf("stale offset: resets = %v replays = %v, want one of each", c.resets, c.replays)
	}
}

// Output redrawn from the buffer is marked as history up to where the buffer
// ended at attach; a new shell and a reconnect continuation are all live.
func TestReplayMarksOnlyHistory(t *testing.T) {
	h := newHarness(t, Config{})
	a := h.dial(t, "", 0)
	a.input("echo old-$((1+1))\n")
	a.waitFor("old-2")
	if len(a.replays) != 0 {
		t.Fatalf("new shell marked output as history: %v", a.replays)
	}
	a.c.Close(websocket.StatusNormalClosure, "")

	// A reload: no screen, so everything buffered is history.
	b := h.dial(t, a.id, 0)
	b.waitFor("old-2")
	if len(b.resets) != 0 || len(b.replays) != 1 || b.replays[0] == 0 {
		t.Fatalf("reload: resets = %v replays = %v; want one boundary covering the redraw", b.resets, b.replays)
	}
	until := b.replays[0]
	b.input("echo new-$((2*4))\n")
	b.waitFor("new-8")
	if len(b.replays) != 1 || b.offset <= until {
		t.Fatalf("live output after reload: replays = %v offset %d, want it past the boundary %d", b.replays, b.offset, until)
	}
	b.c.Close(websocket.StatusNormalClosure, "")

	// A reconnect continues live, including output from while it was away.
	s, _, err := h.m.Open(a.id, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Write([]byte("echo away-$((3*3))\n")); err != nil {
		t.Fatal(err)
	}
	c := h.reconnect(t, b)
	c.waitFor("away-9")
	if len(c.resets) != 0 || len(c.replays) != 0 {
		t.Fatalf("continuation: resets = %v replays = %v, want none", c.resets, c.replays)
	}
}

// A reconnect with no other attachment in between continues live, including
// output that was written to its old socket but never reached the page.
func TestReconnectWithoutTakeoverIsLive(t *testing.T) {
	h := newHarness(t, Config{})
	a := h.dial(t, "", 0)
	a.input("echo one-$((1+1))\n")
	a.waitFor("one-2")
	s := h.session(t, a.id)
	// Delivered to the socket, not read: lost with the connection.
	a.input("printf '\\033[6n'; echo two-$((2+1))\n")
	waitLocked(t, s, "the query delivered to A's socket", func() bool {
		return bytes.Contains(s.buf, []byte("two-3")) && s.delivered == s.end
	})
	a.c.CloseNow()
	waitLocked(t, s, "A detached", func() bool { return !s.attached })

	b := h.reconnect(t, a)
	b.waitFor("two-3")
	if len(b.resets) != 0 || len(b.replays) != 0 {
		t.Fatalf("continuation: resets = %v replays = %v, want none", b.resets, b.replays)
	}
}

// takeover is A -> B -> A's way back: A draws some output, another tab B
// takes the shell over and runs something that asks the terminal a question,
// then B goes away. It returns A, the session and how far output had been
// delivered to B.
func takeover(t *testing.T, h *harness) (a *client, s *Session, handled int64) {
	t.Helper()
	a = h.dial(t, "", 0)
	a.input("echo a-$((1+1))\n")
	a.waitFor("a-2")
	s = h.session(t, a.id)

	b := h.dial(t, a.id, 0)
	if got := a.closed(); got != StatusTakenOver {
		t.Fatalf("A closed with %v, want %d", got, StatusTakenOver)
	}
	b.input("printf '\\033[6n'; echo b-$((2+2))\n")
	b.waitFor("b-4")
	query := b.at(0, "\x1b[6n")
	if query < a.offset {
		t.Fatalf("B's query at %d, want it after A's offset %d", query, a.offset)
	}
	b.c.CloseNow()
	waitLocked(t, s, "B detached", func() bool { return !s.attached })
	s.mu.Lock()
	handled = s.delivered
	s.mu.Unlock()
	if handled <= query {
		t.Fatalf("delivered %d does not cover B's query at %d", handled, query)
	}
	return a, s, handled
}

// What B was sent was answered by B. A coming back with its old offset must
// redraw it as history, not answer the query again into whatever runs now;
// what the shell writes after that is live again, also across a plain
// reconnect.
func TestReconnectAfterTakeoverMarksDeliveredOutputAsHistory(t *testing.T) {
	h := newHarness(t, Config{})
	a, s, handled := takeover(t, h)

	back := h.reconnect(t, a)
	back.waitFor("b-4")
	if len(back.resets) != 0 || len(back.replays) != 1 || back.replays[0] != handled {
		t.Fatalf("A back: resets = %v replays = %v, want one boundary at %d and no reset", back.resets, back.replays, handled)
	}
	back.input("echo fresh-$((3*3))\n")
	back.waitFor("fresh-9")
	if len(back.replays) != 1 || back.at(a.offset, "fresh-9") < handled {
		t.Fatalf("fresh output: replays = %v at %d, want it live past %d", back.replays, back.at(a.offset, "fresh-9"), handled)
	}

	back.c.CloseNow()
	waitLocked(t, s, "A detached again", func() bool { return !s.attached })
	if err := s.Write([]byte("printf '\\033[6n'; echo later-$((4*4))\n")); err != nil {
		t.Fatal(err)
	}
	again := h.reconnect(t, back)
	again.waitFor("later-16")
	if len(again.resets) != 0 || len(again.replays) != 0 {
		t.Fatalf("plain reconnect after the redraw: resets = %v replays = %v, want none", again.resets, again.replays)
	}
}

// A socket that drops during that redraw comes back with the generation it
// was given, from before the boundary: the rest of the redraw is still
// history, and what follows it is still live.
func TestReconnectDuringTakeoverRedrawKeepsBoundary(t *testing.T) {
	h := newHarness(t, Config{})
	a, _, handled := takeover(t, h)

	back := h.reconnect(t, a)
	if err := back.next(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if len(back.replays) != 1 || back.replays[0] != handled || back.offset != a.offset {
		t.Fatalf("A back: replays = %v offset %d, want the boundary %d before any output from %d", back.replays, back.offset, handled, a.offset)
	}
	back.c.CloseNow() // none of the redraw reached the screen

	again := h.reconnect(t, back)
	again.waitFor("b-4")
	if len(again.resets) != 0 || len(again.replays) != 1 || again.replays[0] != handled {
		t.Fatalf("A again: resets = %v replays = %v, want one boundary at %d and no reset", again.resets, again.replays, handled)
	}
	again.input("echo fresh-$((3*3))\n")
	again.waitFor("fresh-9")
	if len(again.replays) != 1 || again.at(a.offset, "fresh-9") < handled {
		t.Fatalf("fresh output: replays = %v at %d, want it live past %d", again.replays, again.at(a.offset, "fresh-9"), handled)
	}
}

// Output the shell wrote after B left reached no browser: its queries are
// still waiting, so the history boundary stops where B's output ended.
func TestReconnectAfterTakeoverKeepsUndeliveredOutputLive(t *testing.T) {
	h := newHarness(t, Config{})
	a, s, handled := takeover(t, h)
	if err := s.Write([]byte("printf '\\033[5n'; echo away-$((3*3))\n")); err != nil {
		t.Fatal(err)
	}
	waitLocked(t, s, "output while detached", func() bool { return bytes.Contains(s.buf, []byte("away-9")) })

	back := h.reconnect(t, a)
	back.waitFor("away-9")
	if len(back.resets) != 0 || len(back.replays) != 1 || back.replays[0] != handled {
		t.Fatalf("A back: resets = %v replays = %v, want one boundary at %d and no reset", back.resets, back.replays, handled)
	}
	if q := back.at(a.offset, "\x1b[5n"); q < handled {
		t.Fatalf("query written while detached at %d, inside the history before %d", q, handled)
	}
}

func TestSecondBrowserTakesOver(t *testing.T) {
	h := newHarness(t, Config{})
	a := h.dial(t, "", 0)
	b := h.dial(t, a.id, a.offset)
	if b.id != a.id {
		t.Fatal("second browser got a different shell")
	}
	if got := a.closed(); got != StatusTakenOver {
		t.Fatalf("first browser closed with %v, want %d", got, StatusTakenOver)
	}
	// The newer attachment still drives the shell.
	b.input("echo still-$((3*3))\n")
	b.waitFor("still-9")
}

func TestShellExitDeliversOutputThenExit(t *testing.T) {
	h := newHarness(t, Config{})
	a := h.dial(t, "", 0)
	a.input("echo bye-$((4+4)); exit 3\n")
	var err error
	for err == nil {
		err = a.next(5 * time.Second)
	}
	if !strings.Contains(a.screen.String(), "bye-8") {
		t.Fatalf("final output lost: %q", a.screen.String())
	}
	if a.exit == nil || *a.exit != 3 {
		t.Fatalf("exit = %v, want 3", a.exit)
	}
	if websocket.CloseStatus(err) != websocket.StatusNormalClosure {
		t.Fatalf("close = %v, want normal closure", err)
	}
	// The id is spent: asking for it again starts a new shell.
	b := h.dial(t, a.id, a.offset)
	if b.id == a.id {
		t.Fatal("an exited shell's id was reattached")
	}
}

func TestDetachedShellIsHungUp(t *testing.T) {
	h := newHarness(t, Config{Detach: 200 * time.Millisecond})
	a := h.dial(t, "", 0)
	a.c.Close(websocket.StatusNormalClosure, "")

	deadline := time.Now().Add(5 * time.Second)
	for {
		h.m.mu.Lock()
		_, alive := h.m.sessions[a.id]
		h.m.mu.Unlock()
		if !alive {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("detached shell outlived its timeout")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestFullManagerEvictsLongestDetached(t *testing.T) {
	h := newHarness(t, Config{MaxSessions: 2})
	a := h.dial(t, "", 0)
	a.c.Close(websocket.StatusNormalClosure, "")
	b := h.dial(t, "", 0) // attached
	time.Sleep(50 * time.Millisecond)

	c := h.dial(t, "", 0) // needs room: a goes, b stays
	h.m.mu.Lock()
	_, aAlive := h.m.sessions[a.id]
	_, bAlive := h.m.sessions[b.id]
	h.m.mu.Unlock()
	if aAlive || !bAlive {
		t.Fatalf("after eviction a alive=%v b alive=%v; want the detached one gone", aAlive, bAlive)
	}

	// Every remaining shell attached: no room, and nothing is killed for it.
	_, _, err := h.m.Open("", 80, 24)
	if !errors.Is(err, ErrTooMany) {
		t.Fatalf("Open with all shells attached: err = %v, want ErrTooMany", err)
	}
	c.input("echo alive-$((5+5))\n")
	c.waitFor("alive-10")
}

func TestPasswdShell(t *testing.T) {
	path := t.TempDir() + "/passwd"
	body := "root:x:0:0::/root:/bin/bash\njosh:x:1000:100::/home/josh:/run/current-system/sw/bin/zsh\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := passwdShell(path, 1000); got != "/run/current-system/sw/bin/zsh" {
		t.Fatalf("passwdShell = %q", got)
	}
	if got := passwdShell(path, 1); got != "" {
		t.Fatalf("unknown uid gave %q", got)
	}
}

func TestShellEnvDropsServicePlumbing(t *testing.T) {
	env := ShellEnv([]string{
		"HOME=/home/u", "PATH=/bin", "TAM_SESSION_KEY_FILE=/run/k", "JOURNAL_STREAM=8:1",
		"TMUX=/tmp/tmux-1/default,1,0", "TERM=dumb",
	})
	got := strings.Join(env, " ")
	for _, gone := range []string{"TAM_SESSION_KEY_FILE", "JOURNAL_STREAM", "TMUX=", "TERM=dumb"} {
		if strings.Contains(got, gone) {
			t.Errorf("env kept %s: %s", gone, got)
		}
	}
	for _, kept := range []string{"HOME=/home/u", "PATH=/bin", "TERM=xterm-256color"} {
		if !strings.Contains(got, kept) {
			t.Errorf("env lost %s: %s", kept, got)
		}
	}
}
