package transcript

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ErrNoSession means no agent with a readable session runs in the pane.
var ErrNoSession = errors.New("no agent session found for this pane")

// Locator finds the session of the agent running under a pane. It mirrors
// session_for_pane in tmux-agents' resume.sh, but needs nothing from the
// plugin, so it works with older plugin versions too.
type Locator struct {
	// OmpDir is omp's agent directory (PI_CODING_AGENT_DIR, else ~/.omp/agent).
	OmpDir string
	// OpenCode is opencode's database; nil disables opencode.
	OpenCode *OpenCodeDB
	// Ps is the ps binary; defaults to "ps" on PATH.
	Ps string
}

// NewLocator returns a locator using omp's and opencode's own directory
// resolution.
func NewLocator() *Locator {
	dir := os.Getenv("PI_CODING_AGENT_DIR")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".omp", "agent")
	}
	return &Locator{OmpDir: dir, OpenCode: NewOpenCodeDB(DefaultOpenCodeDBPath())}
}

// Agent kinds a Target can name.
const (
	AgentOmp      = "omp"
	AgentOpenCode = "opencode"
)

// Target is the session an agent pane shows. Ref is the session log path for
// omp and the session id for opencode.
type Target struct {
	Kind string
	Ref  string
}

// PaneRef is what the locator needs to know about a pane.
type PaneRef struct {
	PID int
	// Title is the terminal title; opencode names its session there.
	Title string
	// Path is the pane's current directory, used when the agent's own cwd
	// cannot be read.
	Path string
}

// Open starts reading the target's conversation.
func (l *Locator) Open(t Target) (Reader, error) {
	switch t.Kind {
	case AgentOmp:
		return Open(t.Ref)
	case AgentOpenCode:
		if l.OpenCode == nil {
			return nil, ErrNoSession
		}
		return l.OpenCode.Open(t.Ref)
	}
	return nil, ErrNoSession
}

type proc struct {
	pid, ppid int
	tty, comm string
	args      string
}

// Find returns the session of the agent in the process tree rooted at the
// pane's process.
func (l *Locator) Find(ctx context.Context, pane PaneRef) (Target, error) {
	if pane.PID <= 0 {
		return Target{}, ErrNoSession
	}
	procs, err := l.ps(ctx)
	if err != nil {
		return Target{}, err
	}
	children := map[int][]int{}
	byPID := map[int]proc{}
	for _, p := range procs {
		children[p.ppid] = append(children[p.ppid], p.pid)
		byPID[p.pid] = p
	}
	// Breadth-first: the shallowest agent process is the agent; deeper ones
	// are omp's workers or opencode's `serve` child (same comm). Sandbox
	// wrappers (nono) run the agent as their child.
	queue := []int{pane.PID}
	seen := map[int]bool{}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		p := byPID[pid]
		switch filepath.Base(p.comm) {
		case "omp":
			path, ok := l.ompSession(p)
			if !ok {
				return Target{Kind: AgentOmp}, ErrNoSession
			}
			return Target{Kind: AgentOmp, Ref: path}, nil
		// The nix wrapper's name, cut to 15 characters by ps.
		case "opencode", ".opencode-wrapp", ".opencode-wrapped":
			id, ok := l.openCodeSession(ctx, p, pane)
			if !ok {
				return Target{Kind: AgentOpenCode}, ErrNoSession
			}
			return Target{Kind: AgentOpenCode, Ref: id}, nil
		}
		queue = append(queue, children[pid]...)
	}
	return Target{}, ErrNoSession
}

func (l *Locator) openCodeSession(ctx context.Context, p proc, pane PaneRef) (string, bool) {
	if l.OpenCode == nil {
		return "", false
	}
	argv := strings.Fields(p.args)
	if raw, err := os.ReadFile("/proc/" + strconv.Itoa(p.pid) + "/cmdline"); err == nil {
		argv = strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
	}
	cwd, err := os.Readlink("/proc/" + strconv.Itoa(p.pid) + "/cwd")
	if err != nil {
		cwd = pane.Path
	}
	return l.OpenCode.FindSession(ctx, argv, cwd, pane.Title)
}

func (l *Locator) ps(ctx context.Context) ([]proc, error) {
	bin := l.Ps
	if bin == "" {
		bin = "ps"
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	// args last: it is the only column that can contain spaces.
	out, err := exec.CommandContext(ctx, bin, "-e", "-o", "pid=,ppid=,tty=,comm=,args=").Output()
	if err != nil {
		return nil, err
	}
	var procs []proc
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		p := proc{pid: pid, ppid: ppid, tty: f[2], comm: f[3]}
		if len(f) > 4 {
			p.args = strings.Join(f[4:], " ")
		}
		procs = append(procs, p)
	}
	return procs, nil
}

// ompSession prefers a session file the process holds open, then omp's
// per-terminal breadcrumb for the agent's own tty (nono gives the agent its
// own pty, so the pane's tty can point at an unrelated session), then the
// --resume argument it was started with.
func (l *Locator) ompSession(p proc) (string, bool) {
	sessions := filepath.Join(l.OmpDir, "sessions") + string(os.PathSeparator)
	if entries, err := os.ReadDir("/proc/" + strconv.Itoa(p.pid) + "/fd"); err == nil {
		for _, e := range entries {
			link, err := os.Readlink("/proc/" + strconv.Itoa(p.pid) + "/fd/" + e.Name())
			if err != nil {
				continue
			}
			rel, ok := strings.CutPrefix(link, sessions)
			// sessions/<dir>/<session>.jsonl; deeper files are subagent logs.
			if ok && strings.HasSuffix(rel, ".jsonl") && strings.Count(rel, "/") == 1 {
				return link, true
			}
		}
	}
	if path, ok := l.crumb(p.tty); ok {
		return path, true
	}
	for _, arg := range strings.Fields(p.args) {
		if path, ok := strings.CutPrefix(arg, "--resume="); ok && strings.HasSuffix(path, ".jsonl") {
			if _, err := os.Stat(path); err == nil {
				return path, true
			}
		}
	}
	return "", false
}

// crumb reads terminal-sessions/<tty>: line 1 is the cwd, line 2 the session
// file (absolute, or relative to the cwd).
func (l *Locator) crumb(tty string) (string, bool) {
	tty = strings.TrimPrefix(tty, "/dev/")
	if tty == "" || tty == "?" || tty == "??" {
		return "", false
	}
	raw, err := os.ReadFile(filepath.Join(l.OmpDir, "terminal-sessions", strings.ReplaceAll(tty, "/", "-")))
	if err != nil {
		return "", false
	}
	lines := strings.SplitN(string(raw), "\n", 3)
	if len(lines) < 2 || lines[1] == "" {
		return "", false
	}
	path := lines[1]
	if !filepath.IsAbs(path) {
		path = filepath.Join(lines[0], path)
	}
	if _, err := os.Stat(path); err != nil {
		return "", false
	}
	return path, true
}
