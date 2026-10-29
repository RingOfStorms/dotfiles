package tmux

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// newTestServer starts an isolated tmux server so the tests never touch the
// developer's own sessions. Each test gets its own socket.
func newTestServer(t *testing.T) *Client {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socket := fmt.Sprintf("tamtest-%d-%d", os.Getpid(), time.Now().UnixNano()%1000)
	c := New("tmux", socket)
	t.Cleanup(func() {
		_ = exec.Command("tmux", "-L", socket, "kill-server").Run()
	})
	return c
}

func waitFor(t *testing.T, what string, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestSessionCaptureAndKeys(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	dir := t.TempDir()
	id, err := c.NewSession(ctx, "t1", dir, "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if !strings.HasPrefix(id, "%") {
		t.Fatalf("pane id = %q", id)
	}

	pane, err := c.GetPane(ctx, id)
	if err != nil {
		t.Fatalf("get pane: %v", err)
	}
	if pane.Session != "t1" || pane.Width == 0 {
		t.Fatalf("unexpected pane: %+v", pane)
	}

	if err := c.SendText(ctx, id, "printf 'hello-there\\n'"); err != nil {
		t.Fatalf("send text: %v", err)
	}
	if err := c.SendKeys(ctx, id, "Enter"); err != nil {
		t.Fatalf("send enter: %v", err)
	}

	var captured string
	waitFor(t, "pane output", func() bool {
		out, err := c.Capture(ctx, id, CaptureOpts{Escapes: true, Join: true})
		if err != nil {
			return false
		}
		captured = out
		return strings.Contains(out, "hello-there")
	})

	lines := RenderLines(captured)
	if len(lines) == 0 {
		t.Fatal("no lines rendered")
	}

	meta, err := c.Meta(ctx, id)
	if err != nil {
		t.Fatalf("meta: %v", err)
	}
	if meta.Cols != pane.Width || meta.Rows != pane.Height {
		t.Fatalf("meta %dx%d != pane %dx%d", meta.Cols, meta.Rows, pane.Width, pane.Height)
	}
}

// RenderLines is a tiny helper so the test asserts on real output without
// importing the frame package into every assertion.
func RenderLines(raw string) []string {
	var out []string
	for _, line := range strings.Split(raw, "\n") {
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

func TestPaneOptionsAndKill(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	id, err := c.NewSession(ctx, "t2", t.TempDir(), "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if err := c.SetPaneOption(ctx, id, "@agent_state", "input"); err != nil {
		t.Fatalf("set option: %v", err)
	}
	pane, err := c.GetPane(ctx, id)
	if err != nil {
		t.Fatalf("get pane: %v", err)
	}
	if pane.AgentState != "input" {
		t.Fatalf("agent state = %q", pane.AgentState)
	}
	if err := c.UnsetPaneOption(ctx, id, "@agent_state"); err != nil {
		t.Fatalf("unset option: %v", err)
	}
	pane, _ = c.GetPane(ctx, id)
	if pane.AgentState != "" {
		t.Fatalf("agent state after unset = %q", pane.AgentState)
	}
	if err := c.KillPane(ctx, id); err != nil {
		t.Fatalf("kill pane: %v", err)
	}
	if _, err := c.GetPane(ctx, id); err == nil {
		t.Fatal("pane still exists after kill")
	}
}

func TestPasteMultiLine(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	id, err := c.NewSession(ctx, "t3", t.TempDir(), "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}
	// bash's readline enables bracketed paste, so the paste mode must deliver
	// both lines without the first newline submitting the command; Enter then
	// runs them as the two (failing) commands "alpha" and "beta", which echo.
	if err := c.Paste(ctx, id, "alpha\nbeta"); err != nil {
		t.Fatalf("paste: %v", err)
	}
	if err := c.SendKeys(ctx, id, "Enter"); err != nil {
		t.Fatalf("enter: %v", err)
	}
	waitFor(t, "pasted text", func() bool {
		out, err := c.Capture(ctx, id, CaptureOpts{})
		return err == nil && strings.Contains(out, "alpha") && strings.Contains(out, "beta")
	})
}

func TestEmptyServer(t *testing.T) {
	c := newTestServer(t)
	if _, err := c.ListPanes(context.Background()); err == nil {
		t.Fatal("expected an error when no server is running")
	}
}
