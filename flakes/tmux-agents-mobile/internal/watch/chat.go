package watch

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

// ChatPage is how many items a viewer gets at first, and per "earlier" page.
const ChatPage = 60

// RenderedItem is one transcript item as the browser receives it.
type RenderedItem struct {
	ID    string `json:"id"`
	Index int    `json:"i"`
	HTML  string `json:"html"`
}

// ChatInit replaces whatever the viewer shows.
type ChatInit struct {
	Start int            `json:"start"`
	Total int            `json:"total"`
	Items []RenderedItem `json:"items"`
}

// ChatItems are new or changed items, in order.
type ChatItems struct {
	Items []RenderedItem `json:"items"`
}

// ChatState is the pane's agent state, for the header glyph and the
// "working" row.
type ChatState struct {
	State  string `json:"state"`
	Unseen bool   `json:"unseen"`
}

// ErrNoWatcher means nobody is watching that pane's transcript any more.
var ErrNoWatcher = errors.New("transcript is not being watched")

// ChatHub is the transcript counterpart of Hub: one session reader per pane
// while somebody is looking, fanned out to every viewer. Items are rendered
// by Render (the web layer owns markup) and cached per revision.
type ChatHub struct {
	tmux    *tmux.Client
	locator *transcript.Locator
	log     *slog.Logger
	render  func(transcript.Item) string

	interval time.Duration
	relocate time.Duration
	idle     time.Duration

	mu sync.Mutex
	w  map[string]*chatWatcher
}

// NewChatHub returns a hub that polls session logs every 400ms and checks the
// pane (still there, same session, agent state) every 2s.
func NewChatHub(t *tmux.Client, l *transcript.Locator, render func(transcript.Item) string, log *slog.Logger) *ChatHub {
	return &ChatHub{
		tmux:     t,
		locator:  l,
		log:      log,
		render:   render,
		interval: 400 * time.Millisecond,
		relocate: 2 * time.Second,
		idle:     30 * time.Second,
		w:        map[string]*chatWatcher{},
	}
}

// Locate returns the agent kind and session log of the agent in a pane.
func (h *ChatHub) Locate(ctx context.Context, p tmux.Pane) (kind, path string, err error) {
	return h.locator.Find(ctx, p.PID)
}

type chatWatcher struct {
	hub  *ChatHub
	pane string
	add  chan *stream
	rm   chan *stream
	done chan struct{}

	// mu guards sess and cache: Earlier reads them from request goroutines.
	mu    sync.Mutex
	sess  *transcript.Session
	cache map[string]cached
}

type cached struct {
	rev  int
	html string
}

// Subscribe streams transcript events for a pane: "init", "items", "state",
// "fallback" (no readable session: show the terminal) and "gone".
func (h *ChatHub) Subscribe(pane string) (<-chan Event, func()) {
	h.mu.Lock()
	w, ok := h.w[pane]
	if !ok {
		w = &chatWatcher{
			hub:   h,
			pane:  pane,
			add:   make(chan *stream),
			rm:    make(chan *stream),
			done:  make(chan struct{}),
			cache: map[string]cached{},
		}
		h.w[pane] = w
		go w.run()
	}
	h.mu.Unlock()

	s := &stream{ch: make(chan Event, 32)}
	select {
	case w.add <- s:
	case <-w.done:
		return h.Subscribe(pane)
	}
	var once sync.Once
	return s.ch, func() {
		once.Do(func() {
			select {
			case w.rm <- s:
			case <-w.done:
			}
		})
	}
}

// Earlier renders up to n items before index, for "show earlier".
func (h *ChatHub) Earlier(pane string, before, n int) (ChatInit, error) {
	h.mu.Lock()
	w := h.w[pane]
	h.mu.Unlock()
	if w == nil {
		return ChatInit{}, ErrNoWatcher
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.sess == nil {
		return ChatInit{}, ErrNoWatcher
	}
	before = min(before, w.sess.Len())
	from := max(0, before-n)
	return ChatInit{Start: from, Total: w.sess.Len(), Items: w.renderLocked(w.sess.Range(from, before))}, nil
}

func (h *ChatHub) forget(w *chatWatcher) {
	h.mu.Lock()
	if h.w[w.pane] == w {
		delete(h.w, w.pane)
	}
	h.mu.Unlock()
}

func (w *chatWatcher) renderLocked(items []transcript.Item) []RenderedItem {
	out := make([]RenderedItem, 0, len(items))
	for _, it := range items {
		c, ok := w.cache[it.ID]
		if !ok || c.rev != it.Rev || it.ID == "" {
			c = cached{rev: it.Rev, html: w.hub.render(it)}
			if it.ID != "" {
				w.cache[it.ID] = c
			}
		}
		out = append(out, RenderedItem{ID: it.ID, Index: it.Index, HTML: c.html})
	}
	return out
}

func (w *chatWatcher) initLocked() ChatInit {
	total := w.sess.Len()
	from := max(0, total-ChatPage)
	return ChatInit{Start: from, Total: total, Items: w.renderLocked(w.sess.Range(from, total))}
}

func (w *chatWatcher) run() {
	defer close(w.done)
	ctx := context.Background()
	subs := map[*stream]struct{}{}
	var (
		path      string
		state     ChatState
		haveState bool
		idleSince time.Time
		nextMark  time.Time
		nextCheck time.Time
	)

	push := func(s *stream, ev Event) {
		select {
		case s.ch <- ev:
		default:
			s.stale = true
		}
	}
	event := func(name string, payload any) (Event, bool) {
		data, err := json.Marshal(payload)
		if err != nil {
			return Event{}, false
		}
		return Event{Name: name, Data: data}, true
	}
	// A viewer that fell behind gets a fresh init instead of the deltas it
	// could not take.
	broadcast := func(name string, payload any) {
		ev, ok := event(name, payload)
		if !ok {
			return
		}
		for s := range subs {
			if s.stale && w.sess != nil {
				w.mu.Lock()
				full, ok := event("init", w.initLocked())
				w.mu.Unlock()
				if ok {
					push(s, full)
					s.stale = false
				}
				continue
			}
			push(s, ev)
		}
	}
	shutdown := func() {
		for s := range subs {
			close(s.ch)
			delete(subs, s)
		}
		_ = w.hub.tmux.UnsetPaneOption(ctx, w.pane, "@agent_watch_until")
		w.hub.forget(w)
	}
	touch := func() {
		if time.Now().Before(nextMark) {
			return
		}
		want := time.Now().Add(120 * time.Second).Unix()
		if err := w.hub.tmux.SetPaneOption(ctx, w.pane, "@agent_watch_until", itoa(want)); err != nil {
			w.hub.log.Debug("watch marker failed", "pane", w.pane, "err", err)
		}
		nextMark = time.Now().Add(5 * time.Second)
	}

	// check confirms the pane still runs the same session and publishes the
	// agent state. It returns false when the stream is over.
	check := func() bool {
		nextCheck = time.Now().Add(w.hub.relocate)
		p, err := w.hub.tmux.GetPane(ctx, w.pane)
		if err != nil {
			broadcast("gone", payload{Message: err.Error()})
			return false
		}
		next := ChatState{State: p.AgentState, Unseen: p.AgentUnseen}
		if !haveState || next != state {
			state, haveState = next, true
			broadcast("state", state)
		}
		_, found, err := w.hub.locator.Find(ctx, p.PID)
		switch {
		case err != nil && w.sess == nil:
			broadcast("fallback", payload{Message: err.Error()})
			return false
		case err != nil:
			// The agent exited or is between sessions; keep showing what we
			// have until the pane says otherwise.
			return true
		case found == path:
			return true
		}
		sess, err := transcript.Open(found)
		if err != nil {
			broadcast("fallback", payload{Message: err.Error()})
			return false
		}
		w.mu.Lock()
		w.sess, w.cache, path = sess, map[string]cached{}, found
		init := w.initLocked()
		w.mu.Unlock()
		broadcast("init", init)
		return true
	}

	poll := func() {
		if w.sess == nil {
			return
		}
		w.mu.Lock()
		changed, err := w.sess.Poll()
		var (
			name string
			out  any
		)
		switch {
		case errors.Is(err, transcript.ErrReset):
			w.cache = map[string]cached{}
			name, out = "init", w.initLocked()
		case err != nil:
			w.hub.log.Debug("transcript poll", "pane", w.pane, "err", err)
		case len(changed) > 0:
			items := make([]transcript.Item, 0, len(changed))
			for _, i := range changed {
				items = append(items, w.sess.Range(i, i+1)...)
			}
			name, out = "items", ChatItems{Items: w.renderLocked(items)}
		}
		w.mu.Unlock()
		if name != "" {
			broadcast(name, out)
		}
	}

	ticker := time.NewTicker(w.hub.interval)
	defer ticker.Stop()
	for {
		select {
		case s := <-w.add:
			subs[s] = struct{}{}
			idleSince = time.Time{}
			touch()
			if w.sess == nil {
				if !check() {
					shutdown()
					return
				}
				continue
			}
			w.mu.Lock()
			ev, ok := event("init", w.initLocked())
			w.mu.Unlock()
			if ok {
				push(s, ev)
			}
			if haveState {
				if ev, ok := event("state", state); ok {
					push(s, ev)
				}
			}
		case s := <-w.rm:
			if _, ok := subs[s]; ok {
				delete(subs, s)
				close(s.ch)
			}
			if len(subs) == 0 {
				idleSince = time.Now()
			}
		case <-ticker.C:
			if len(subs) == 0 {
				if !idleSince.IsZero() && time.Since(idleSince) > w.hub.idle {
					shutdown()
					return
				}
				continue
			}
			touch()
			if time.Now().After(nextCheck) && !check() {
				shutdown()
				return
			}
			poll()
		}
	}
}
