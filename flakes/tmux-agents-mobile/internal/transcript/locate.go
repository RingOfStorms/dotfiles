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

// Locator finds the session log of the agent running under a pane. It mirrors
// session_for_pane/omp_session in tmux-agents' resume.sh, but needs nothing
// from the plugin, so it works with older plugin versions too.
type Locator struct {
	// OmpDir is omp's agent directory (PI_CODING_AGENT_DIR, else ~/.omp/agent).
	OmpDir string
	// Ps is the ps binary; defaults to "ps" on PATH.
	Ps string
}

// NewLocator returns a locator using omp's own directory resolution.
func NewLocator() *Locator {
	dir := os.Getenv("PI_CODING_AGENT_DIR")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".omp", "agent")
	}
	return &Locator{OmpDir: dir}
}

type proc struct {
	pid, ppid int
	tty, comm string
	args      string
}

// Find returns the agent kind and session log path for the process tree
// rooted at panePID.
func (l *Locator) Find(ctx context.Context, panePID int) (kind, path string, err error) {
	if panePID <= 0 {
		return "", "", ErrNoSession
	}
	procs, err := l.ps(ctx)
	if err != nil {
		return "", "", err
	}
	children := map[int][]int{}
	byPID := map[int]proc{}
	for _, p := range procs {
		children[p.ppid] = append(children[p.ppid], p.pid)
		byPID[p.pid] = p
	}
	// Breadth-first: the shallowest omp is the agent; deeper ones are its
	// workers. Sandbox wrappers (nono) run the agent as their child.
	queue := []int{panePID}
	seen := map[int]bool{}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		p := byPID[pid]
		if filepath.Base(p.comm) == "omp" {
			path, ok := l.ompSession(p)
			if !ok {
				return "omp", "", ErrNoSession
			}
			return "omp", path, nil
		}
		queue = append(queue, children[pid]...)
	}
	return "", "", ErrNoSession
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
