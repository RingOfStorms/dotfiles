package watch

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

// fakePs makes the locator see pid 4242 as omp resumed from session.
func fakePs(t *testing.T, session string) string {
	t.Helper()
	ps := filepath.Join(t.TempDir(), "ps")
	script := fmt.Sprintf("#!/bin/sh\necho '4242 1 pts/9 omp omp --resume=%s'\n", session)
	if err := os.WriteFile(ps, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return ps
}

// A session that is found but cannot be opened is not ready: otherwise the
// pane page renders the conversation, the stream falls back at once, and the
// two redirect into each other.
func TestReadyNeedsReadableSession(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads unreadable files")
	}
	dir := t.TempDir()
	session := filepath.Join(dir, "s.jsonl")
	if err := os.WriteFile(session, []byte(`{"type":"session","id":"x"}`+"\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	l := &transcript.Locator{OmpDir: t.TempDir(), Ps: fakePs(t, session)}
	h := &ChatHub{locator: l}
	p := tmux.Pane{PID: 4242}
	ctx := context.Background()

	if _, err := h.Locate(ctx, p); err != nil {
		t.Fatalf("locate: %v (the session should be found)", err)
	}
	if h.Ready(ctx, p) {
		t.Fatal("ready with an unreadable session")
	}
	if err := os.Chmod(session, 0o600); err != nil {
		t.Fatal(err)
	}
	if !h.Ready(ctx, p) {
		t.Fatal("not ready once the session is readable")
	}
}
