package agents

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"testing"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
)

func gitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.email=test@example.test", "-c", "user.name=test", "commit", "-q", "--allow-empty", "-m", "init"},
	} {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	return dir
}

// Without the plugin (an older tmux-agents, or none at all) the fallback must
// still list sessions that have no agent panes, otherwise shell-only worktrees
// disappear from the phone entirely.
func TestFallbackKeepsShellOnlySessions(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socket := fmt.Sprintf("tamagents-%d", os.Getpid())
	c := tmux.New("tmux", socket)
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })

	ctx := context.Background()
	dir := gitRepo(t)

	agentPane, err := c.NewSession(ctx, "withagent", dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.NewSession(ctx, "shellonly", dir, ""); err != nil {
		t.Fatal(err)
	}
	if err := c.SetPaneOption(ctx, agentPane, "@agent_state", "working"); err != nil {
		t.Fatal(err)
	}
	// omp announces itself through the pane title.
	if out, err := exec.Command("tmux", "-L", socket, "select-pane", "-t", agentPane, "-T", "π > demo agent").CombinedOutput(); err != nil {
		t.Fatalf("select-pane -T: %v: %s", err, out)
	}

	p := New("", c) // empty bin: force the fallback
	p.Git = diff.New("git")
	rows := p.Rows(ctx)

	var shellSession, agentSession, agentRow *Row
	for i := range rows {
		r := &rows[i]
		switch {
		case r.Kind == "session" && r.Session == "shellonly":
			shellSession = r
		case r.Kind == "session" && r.Session == "withagent":
			agentSession = r
		case r.Kind == "pane" && r.Session == "withagent":
			agentRow = r
		}
	}
	if shellSession == nil {
		t.Fatalf("shell-only session missing from %+v", rows)
	}
	if shellSession.Panes != 1 {
		t.Errorf("shell-only pane count = %d", shellSession.Panes)
	}
	if agentSession == nil || agentRow == nil {
		t.Fatalf("agent session/pane missing from %+v", rows)
	}
	if agentRow.Agent != "omp" || agentRow.Label != "demo agent" {
		t.Errorf("agent row = %+v", agentRow)
	}
	if agentRow.State != "working" {
		t.Errorf("agent state = %q", agentRow.State)
	}
	// git fills the repo/branch context the cards show.
	if agentRow.Repo != dir || agentRow.Branch == "" {
		t.Errorf("repo/branch = %q/%q, want %q and a branch", agentRow.Repo, agentRow.Branch, dir)
	}
}
