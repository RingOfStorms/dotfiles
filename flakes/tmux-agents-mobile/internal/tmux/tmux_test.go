package tmux

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

// TestNewPaneResetsLoginMarkers reproduces the web service creating a pane on
// a tmux server that a login shell started: the server and session
// environments carry the Nix/Home Manager run-once markers, while the new pane
// gets the client's short PATH. A stand-in login shell restores the profile
// PATH only when every marker is unset or empty, as /etc/profile and
// hm-session-vars.sh do, so the profile-only command must be found in every
// pane NewSession and NewWindow create, with or without a program.
func TestNewPaneResetsLoginMarkers(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()
	markers := []string{
		"__NIXOS_SET_ENVIRONMENT_DONE",
		"__ETC_PROFILE_DONE",
		"__NIX_DARWIN_SET_ENVIRONMENT_DONE",
		"__ETC_PROFILE_NIX_SOURCED",
		"__HM_SESS_VARS_SOURCED",
		"__HM_ZSH_SESS_VARS_SOURCED",
	}

	bin, err := exec.LookPath(c.Bin)
	if err != nil {
		t.Fatalf("look up tmux: %v", err)
	}
	c.Bin = bin

	fixture := t.TempDir()
	profileBin := filepath.Join(fixture, "profile-bin")
	if err := os.Mkdir(profileBin, 0o755); err != nil {
		t.Fatal(err)
	}
	writeExec := func(path, body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeExec(filepath.Join(profileBin, "tam-profile-tool"), "#!/bin/sh\necho profile-tool-ok\n")
	shell := filepath.Join(fixture, "tam-login-shell")
	writeExec(shell, fmt.Sprintf(`#!/bin/sh
fresh=1
for v in %[1]s; do
	eval "val=\${$v-}"
	if [ -n "$val" ]; then fresh=; fi
done
if [ -n "$fresh" ]; then
	PATH='%[2]s':"$PATH"
	export PATH
	for v in %[1]s; do export "$v=1"; done
fi
if [ "$1" = -c ]; then
	eval "$2"
	exit
fi
if command -v tam-profile-tool >/dev/null 2>&1; then tam-profile-tool; else echo profile-tool-missing; fi
read -r line
`, strings.Join(markers, " "), profileBin))
	conf := filepath.Join(fixture, "tmux.conf")
	if err := os.WriteFile(conf, []byte(fmt.Sprintf("set-option -g default-shell '%s'\n", shell)), 0o644); err != nil {
		t.Fatal(err)
	}

	// The server starts from a login environment that already ran the
	// profiles, and its base session carries the markers too.
	start := exec.Command(c.Bin, "-u", "-L", c.Socket, "-f", conf, "new-session", "-d", "-s", "base")
	start.Env = os.Environ()
	for _, m := range markers {
		start.Env = append(start.Env, m+"=1")
	}
	if out, err := start.CombinedOutput(); err != nil {
		t.Fatalf("start server: %v: %s", err, out)
	}
	for _, m := range markers {
		if _, err := c.run(ctx, nil, "set-environment", "-g", m, "1"); err != nil {
			t.Fatalf("set global %s: %v", m, err)
		}
		if _, err := c.run(ctx, nil, "set-environment", "-t", "base", m, "1"); err != nil {
			t.Fatalf("set session %s: %v", m, err)
		}
	}

	// The service's own PATH has no profile directories.
	t.Setenv("PATH", t.TempDir())

	profileTool := func(pane string) string {
		t.Helper()
		var got string
		waitFor(t, "profile tool result in "+pane, func() bool {
			out, err := c.Capture(ctx, pane, CaptureOpts{})
			if err != nil {
				return false
			}
			for _, r := range []string{"profile-tool-ok", "profile-tool-missing"} {
				if strings.Contains(out, r) {
					got = r
					return true
				}
			}
			return false
		})
		return got
	}

	// Control: a plain new-window inherits the markers, so the stand-in
	// profile skips its PATH and the command is missing.
	out, err := c.run(ctx, nil, "new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "base:")
	if err != nil {
		t.Fatalf("control new-window: %v", err)
	}
	if got := profileTool(strings.TrimSpace(string(out))); got != "profile-tool-missing" {
		t.Fatalf("control pane: %s, want profile-tool-missing", got)
	}

	dir := t.TempDir()
	program := "tam-profile-tool || echo profile-tool-missing; read -r line"
	for _, tc := range []struct {
		name   string
		create func() (string, error)
	}{
		{"NewSession", func() (string, error) { return c.NewSession(ctx, "fresh", dir, "") }},
		{"NewSession program", func() (string, error) { return c.NewSession(ctx, "fresh-program", dir, program) }},
		{"NewWindow", func() (string, error) { return c.NewWindow(ctx, "base", dir, "") }},
		{"NewWindow program", func() (string, error) { return c.NewWindow(ctx, "base", dir, program) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pane, err := tc.create()
			if err != nil {
				t.Fatalf("create: %v", err)
			}
			if got := profileTool(pane); got != "profile-tool-ok" {
				t.Fatalf("pane %s: %s, want profile-tool-ok", pane, got)
			}
		})
	}

	// The reset only applies to the new shells: the server and base session
	// environments keep their markers.
	for _, scope := range [][]string{{"-g"}, {"-t", "base"}} {
		for _, m := range markers {
			args := append([]string{"show-environment"}, scope...)
			out, err := c.run(ctx, nil, append(args, m)...)
			if err != nil {
				t.Fatalf("show-environment %v %s: %v", scope, m, err)
			}
			if got := strings.TrimSpace(string(out)); got != m+"=1" {
				t.Fatalf("show-environment %v %s = %q, want %s=1", scope, m, got, m)
			}
		}
	}
}

func TestWindowsSessionsAndSplit(t *testing.T) {
	c := newTestServer(t)
	ctx := context.Background()

	dir := t.TempDir()
	first, err := c.NewSession(ctx, "nav", dir, "")
	if err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if _, err := c.NewSession(ctx, "other", t.TempDir(), ""); err != nil {
		t.Fatalf("second session: %v", err)
	}
	second, err := c.NewWindow(ctx, "nav", t.TempDir(), "")
	if err != nil {
		t.Fatalf("new-window: %v", err)
	}
	split, err := c.SplitWindow(ctx, first, "")
	if err != nil {
		t.Fatalf("split-window: %v", err)
	}
	if !strings.HasPrefix(split, "%") || split == first {
		t.Fatalf("split pane id = %q", split)
	}

	wins, err := c.ListWindows(ctx, "nav")
	if err != nil {
		t.Fatalf("list windows: %v", err)
	}
	if len(wins) != 2 {
		t.Fatalf("windows = %+v", wins)
	}
	if len(wins[0].Panes) != 2 || wins[0].Panes[0].ID != first || wins[0].Panes[1].ID != split {
		t.Fatalf("first window panes = %+v", wins[0].Panes)
	}
	if len(wins[1].Panes) != 1 || wins[1].Panes[0].ID != second {
		t.Fatalf("second window panes = %+v", wins[1].Panes)
	}
	// -d on both: the session's current window and active pane are unchanged.
	if !wins[0].Active || wins[1].Active || !wins[0].Panes[0].Active {
		t.Fatalf("active flags moved: %+v", wins)
	}
	// The split starts in the target pane's directory.
	waitFor(t, "split pane cwd", func() bool {
		p, err := c.GetPane(ctx, split)
		real, _ := filepath.EvalSymlinks(dir)
		return err == nil && (p.Path == dir || p.Path == real)
	})

	sessions, err := c.ListSessions(ctx)
	if err != nil {
		t.Fatalf("list sessions: %v", err)
	}
	if len(sessions) != 2 || sessions[0].Name != "nav" || sessions[0].Windows != 2 || sessions[0].Pane != first {
		t.Fatalf("sessions = %+v", sessions)
	}
	if sessions[1].Name != "other" || sessions[1].Attached {
		t.Fatalf("sessions = %+v", sessions)
	}
}

func TestGroupWindows(t *testing.T) {
	got := groupWindows([]Pane{
		{ID: "%1", Session: "a", WindowIndex: 1, WindowName: "x", WindowActive: true},
		{ID: "%2", Session: "a", WindowIndex: 1, WindowName: "x", WindowActive: true},
		{ID: "%3", Session: "a", WindowIndex: 3, WindowName: "y"},
	})
	if len(got) != 2 || len(got[0].Panes) != 2 || got[1].Index != 3 || got[1].Name != "y" || !got[0].Active || got[1].Active {
		t.Fatalf("groupWindows = %+v", got)
	}
}
