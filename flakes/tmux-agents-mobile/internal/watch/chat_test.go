package watch

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

// TestChatHubTailsSession runs a stand-in "omp" (a script, whose process name
// is its file name, started with --resume=<log>) in an isolated tmux server
// and checks the hub finds its log, sends the conversation, then streams what
// is appended.
func TestChatHubTailsSession(t *testing.T) {
	for _, bin := range []string{"tmux", "ps", "sh", "sleep"} {
		if _, err := exec.LookPath(bin); err != nil {
			t.Skip(bin + " not installed")
		}
	}
	dir := t.TempDir()
	sh, _ := exec.LookPath("sh")
	sleep, _ := exec.LookPath("sleep")
	omp := filepath.Join(dir, "omp")
	if err := os.WriteFile(omp, []byte("#!"+sh+"\n"+sleep+" 600\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(dir, "s.jsonl")
	if err := os.WriteFile(log, []byte(`{"type":"session","version":3,"id":"s1"}
{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello there"}}
`), 0o600); err != nil {
		t.Fatal(err)
	}

	socket := fmt.Sprintf("tamchat-%d", os.Getpid())
	c := tmux.New("tmux", socket)
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	ctx := context.Background()
	id, err := c.NewSession(ctx, "c1", dir, "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if err := c.SendText(ctx, id, fmt.Sprintf("%s --resume=%s", omp, log)); err != nil {
		t.Fatal(err)
	}
	if err := c.SendKeys(ctx, id, "Enter"); err != nil {
		t.Fatal(err)
	}

	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := NewChatHub(c, &transcript.Locator{OmpDir: filepath.Join(dir, "omp-home")}, func(it transcript.Item) string {
		return string(it.Kind) + ":" + it.Text + strings.Repeat("+", len(it.Parts))
	}, quiet)
	hub.interval = 50 * time.Millisecond
	hub.relocate = 200 * time.Millisecond

	// Wait for the stand-in to be running before subscribing.
	deadline := time.Now().Add(5 * time.Second)
	for {
		p, err := c.GetPane(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if _, path, err := hub.Locate(ctx, p); err == nil && path == log {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("stand-in omp never located")
		}
		time.Sleep(100 * time.Millisecond)
	}

	events, cancel := hub.Subscribe(id)
	defer cancel()
	init := waitFor(t, events, "init")
	var ci ChatInit
	if err := json.Unmarshal(init.Data, &ci); err != nil {
		t.Fatal(err)
	}
	if ci.Total != 1 || len(ci.Items) != 1 || ci.Items[0].HTML != "user:hello there" {
		t.Fatalf("init = %+v", ci)
	}

	f, err := os.OpenFile(log, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(`{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"hi"}]}}` + "\n")
	_ = f.Close()

	ev := waitFor(t, events, "items")
	var items ChatItems
	if err := json.Unmarshal(ev.Data, &items); err != nil {
		t.Fatal(err)
	}
	if len(items.Items) != 1 || items.Items[0].Index != 1 || items.Items[0].HTML != "assistant:+" {
		t.Fatalf("items = %+v", items)
	}
}

func waitFor(t *testing.T, ch <-chan Event, name string) Event {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ev := nextEvent(t, ch, time.Until(deadline))
		if ev.Name == name {
			return ev
		}
		if ev.Name == "fallback" || ev.Name == "gone" {
			t.Fatalf("got %s while waiting for %s: %s", ev.Name, name, ev.Data)
		}
	}
	t.Fatalf("no %s event", name)
	return Event{}
}
