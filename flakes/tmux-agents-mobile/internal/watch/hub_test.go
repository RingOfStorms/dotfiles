package watch

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/frame"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
)

func TestHubStreamsInitThenPatch(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socket := fmt.Sprintf("tamhub-%d", os.Getpid())
	c := tmux.New("tmux", socket)
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })

	ctx := context.Background()
	id, err := c.NewSession(ctx, "h1", t.TempDir(), "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := New(c, log)
	events, cancel := hub.Subscribe(id, false)
	defer cancel()

	first := nextEvent(t, events, 5*time.Second)
	if first.Name != "init" {
		t.Fatalf("first event = %q", first.Name)
	}
	var f frame.Frame
	if err := json.Unmarshal(first.Data, &f); err != nil {
		t.Fatalf("init payload: %v", err)
	}
	if f.Cols == 0 || len(f.Lines) == 0 {
		t.Fatalf("empty frame: %+v", f)
	}

	// The watch marker is what tells the tmux-agents tick to stay quiet.
	pane, err := c.GetPane(ctx, id)
	if err != nil {
		t.Fatalf("get pane: %v", err)
	}
	if pane.AgentWatchUnix <= time.Now().Unix() {
		t.Fatalf("@agent_watch_until = %d", pane.AgentWatchUnix)
	}

	if err := c.SendText(ctx, id, "printf 'watch-me\\n'"); err != nil {
		t.Fatalf("send: %v", err)
	}
	if err := c.SendKeys(ctx, id, "Enter"); err != nil {
		t.Fatalf("enter: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	sawContent := false
	for time.Now().Before(deadline) && !sawContent {
		ev := nextEvent(t, events, 5*time.Second)
		switch ev.Name {
		case "full":
			var nf frame.Frame
			if err := json.Unmarshal(ev.Data, &nf); err == nil {
				for _, ln := range nf.Lines {
					if strings.Contains(ln.HTML, "watch-me") {
						sawContent = true
					}
				}
			}
		case "patch":
			var p frame.Change
			if err := json.Unmarshal(ev.Data, &p); err == nil {
				for _, ln := range p.Lines {
					if strings.Contains(ln.HTML, "watch-me") {
						sawContent = true
					}
				}
			}
		case "gone":
			t.Fatal("pane reported gone")
		}
	}
	if !sawContent {
		t.Fatal("never saw the pane output in a frame event")
	}

	// Unsubscribing lets the watcher idle out; the marker is cleared when it
	// stops, which is checked by the tmux tests' contract rather than waiting
	// 30s here.
	cancel()
}

func nextEvent(t *testing.T, ch <-chan Event, d time.Duration) Event {
	t.Helper()
	select {
	case ev, ok := <-ch:
		if !ok {
			t.Fatal("event channel closed")
		}
		return ev
	case <-time.After(d):
		t.Fatal("timed out waiting for an event")
	}
	return Event{}
}
