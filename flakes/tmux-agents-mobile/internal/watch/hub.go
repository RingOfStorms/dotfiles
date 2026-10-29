// Package watch owns one capture loop per watched pane and fans the result out
// to every browser currently looking at it.
package watch

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/frame"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
)

// Event is one server-sent event.
type Event struct {
	Name string
	Data []byte
}

type payload struct {
	Message string `json:"message,omitempty"`
}

// Hub keeps watchers alive only while somebody is watching: the last
// unsubscriber starts an idle timer, after which the watcher stops and clears
// the pane's watch marker.
type Hub struct {
	tmux     *tmux.Client
	log      *slog.Logger
	interval time.Duration
	idle     time.Duration

	mu sync.Mutex
	w  map[string]*watcher
}

// New returns a hub. interval is the capture cadence (200ms), idle how long a
// pane keeps being captured after the last viewer leaves (30s).
func New(t *tmux.Client, log *slog.Logger) *Hub {
	return &Hub{
		tmux:     t,
		log:      log,
		interval: 200 * time.Millisecond,
		idle:     30 * time.Second,
		w:        map[string]*watcher{},
	}
}

type stream struct {
	ch    chan Event
	stale bool
}

type watcher struct {
	key  string
	pane string
	fit  bool
	hub  *Hub

	add  chan *stream
	rm   chan *stream
	done chan struct{}
}

// Subscribe starts (or joins) the watcher for a pane. fit selects the capture
// mode: fixed-width rows for the "fit width" view, joined logical lines for the
// reflowing view. The returned channel is closed when the watcher stops.
func (h *Hub) Subscribe(pane string, fit bool) (<-chan Event, func()) {
	key := pane
	if fit {
		key += "|fit"
	}
	h.mu.Lock()
	w, ok := h.w[key]
	if !ok {
		w = &watcher{
			key:  key,
			pane: pane,
			fit:  fit,
			hub:  h,
			add:  make(chan *stream),
			rm:   make(chan *stream),
			done: make(chan struct{}),
		}
		h.w[key] = w
		go w.run()
	}
	h.mu.Unlock()

	s := &stream{ch: make(chan Event, 32)}
	select {
	case w.add <- s:
	case <-w.done:
		// the watcher raced its own shutdown; retry once
		return h.Subscribe(pane, fit)
	}

	var once sync.Once
	cancel := func() {
		once.Do(func() {
			select {
			case w.rm <- s:
			case <-w.done:
			}
		})
	}
	return s.ch, cancel
}

func (h *Hub) forget(w *watcher) {
	h.mu.Lock()
	if h.w[w.key] == w {
		delete(h.w, w.key)
	}
	h.mu.Unlock()
}

func (w *watcher) run() {
	defer close(w.done)

	subs := map[*stream]struct{}{}
	var (
		last      frame.Frame
		have      bool
		idleSince time.Time
		nextMark  time.Time
	)

	ticker := time.NewTicker(w.hub.interval)
	defer ticker.Stop()

	ctx := context.Background()
	shutdown := func() {
		for s := range subs {
			close(s.ch)
			delete(subs, s)
		}
		_ = w.hub.tmux.UnsetPaneOption(ctx, w.pane, "@agent_watch_until")
		w.hub.forget(w)
	}

	push := func(s *stream, ev Event) {
		select {
		case s.ch <- ev:
		default:
			s.stale = true
		}
	}

	broadcast := func(name string, payload any) {
		data, err := json.Marshal(payload)
		if err != nil {
			return
		}
		out := Event{Name: name, Data: data}
		for s := range subs {
			switch {
			case s.stale:
				full, err := json.Marshal(last)
				if err != nil {
					continue
				}
				push(s, Event{Name: "full", Data: full})
				s.stale = false
			default:
				push(s, out)
			}
		}
	}

	poll := func() bool {
		meta, err := w.hub.tmux.Meta(ctx, w.pane)
		if err != nil {
			broadcast("gone", payload{Message: err.Error()})
			return false
		}
		raw, err := w.hub.tmux.Capture(ctx, w.pane, tmux.CaptureOpts{
			Escapes:          true,
			Join:             !w.fit,
			PreserveTrailing: w.fit,
		})
		if err != nil {
			broadcast("gone", payload{Message: err.Error()})
			return false
		}
		next := frame.Frame{
			Cols:    meta.Cols,
			Rows:    meta.Rows,
			CursorX: meta.CursorX,
			CursorY: meta.CursorY,
			InMode:  meta.InMode,
			Dead:    meta.Dead,
			Lines:   frame.Render(raw, !w.fit),
		}
		switch {
		case !have:
			last, have = next, true
			broadcast("init", last)
		case sameFrame(last, next):
			// nothing to say; keepalives are the server's job
		default:
			ch := frame.Diff(last, next)
			last = next
			if ch.Full {
				broadcast("full", last)
			} else {
				broadcast("patch", ch)
			}
		}
		return true
	}

	// Mark the pane as watched so the tmux-agents tick can suppress desktop
	// notifications for it while the phone is looking.
	touch := func() {
		want := time.Now().Add(120 * time.Second).Unix()
		if time.Now().After(nextMark) {
			if err := w.hub.tmux.SetPaneOption(ctx, w.pane, "@agent_watch_until", itoa(want)); err != nil {
				w.hub.log.Debug("watch marker failed", "pane", w.pane, "err", err)
			}
			nextMark = time.Now().Add(5 * time.Second)
		}
	}

	for {
		select {
		case s := <-w.add:
			subs[s] = struct{}{}
			idleSince = time.Time{}
			touch()
			if have {
				if data, err := json.Marshal(last); err == nil {
					push(s, Event{Name: "init", Data: data})
				}
			} else if !poll() {
				return
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
			if !poll() {
				shutdown()
				return
			}
		}
	}
}

func sameFrame(a, b frame.Frame) bool {
	if a.Cols != b.Cols || a.Rows != b.Rows || a.CursorX != b.CursorX || a.CursorY != b.CursorY ||
		a.InMode != b.InMode || a.Dead != b.Dead || len(a.Lines) != len(b.Lines) {
		return false
	}
	for i := range a.Lines {
		if a.Lines[i].Hash != b.Lines[i].Hash {
			return false
		}
	}
	return true
}

func itoa(v int64) string {
	var buf [20]byte
	i := len(buf)
	if v == 0 {
		return "0"
	}
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
