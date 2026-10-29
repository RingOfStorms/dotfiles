// Package agents reads the repo/worktree/agent tree from the tmux-agents
// plugin. The grouping logic (which session belongs to which worktree, how an
// agent labels itself) lives there, in one place, so the phone shows the same
// tree as `prefix + w` on the desktop.
package agents

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
)

// Row is one entry of the navigator tree.
type Row struct {
	ID         string   `json:"id"`
	Kind       string   `json:"kind"` // repo | session | pane
	Repo       string   `json:"repo"`
	Branch     string   `json:"branch"`
	Worktree   flexBool `json:"worktree"`
	Session    string   `json:"session"`
	Pane       string   `json:"pane"`
	Label      string   `json:"label"`
	Agent      string   `json:"agent"`
	State      string   `json:"state"` // working | idle | input | ""
	Unseen     flexBool `json:"unseen"`
	Path       string   `json:"path"`
	Window     string   `json:"window"`
	WindowName string   `json:"window_name"`
	Panes      int      `json:"panes"`
}

// Provider caches `tmux-agents rows --json` for a second: the navigator refresh
// cadence, and enough to keep a phone page load from re-running git per pane.
type Provider struct {
	Bin      string
	Fallback *tmux.Client
	TTL      time.Duration
	Log      *slog.Logger
	// Git fills repo/branch in the no-plugin fallback; nil disables it.
	Git *diff.Git

	repoCache map[string]repoInfo

	mu   sync.Mutex
	at   time.Time
	rows []Row
}

// New returns a provider. bin is the tmux-agents executable; when it is empty or
// missing, rows are synthesised from list-panes (no repo/branch grouping).
func New(bin string, fallback *tmux.Client) *Provider {
	return &Provider{Bin: bin, Fallback: fallback, TTL: time.Second, repoCache: map[string]repoInfo{}}
}

// Rows returns the tree, cached.
func (p *Provider) Rows(ctx context.Context) []Row {
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Since(p.at) < p.TTL && p.rows != nil {
		return p.rows
	}
	rows, err := p.fetch(ctx)
	if err != nil {
		if p.rows == nil {
			p.rows = []Row{}
		}
		return p.rows
	}
	p.rows, p.at = rows, time.Now()
	return p.rows
}

func (p *Provider) fetch(ctx context.Context) ([]Row, error) {
	if p.Bin != "" {
		rows, err := p.plugin(ctx)
		if err == nil {
			return rows, nil
		}
		// A broken plugin must not take the whole UI down - the pane view
		// still works - but it must not be silent either: the fallback has no
		// repo grouping, and that is a visibly different inbox.
		if p.Log != nil {
			p.Log.Warn("tmux-agents rows --json unavailable; falling back to title detection (no worktree ordering)", "bin", p.Bin, "err", err)
		}
	}
	return p.synthesise(ctx)
}

func (p *Provider) plugin(ctx context.Context) ([]Row, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, p.Bin, "rows", "--json").Output()
	if err != nil {
		return nil, err
	}
	var rows []Row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

// synthesise is the no-plugin fallback: agent panes only, flat, no repo info.
// synthesise is the no-plugin fallback: it builds the same session → agent pane
// shape from plain tmux data, with repo/branch looked up through git when a
// runner is available. Sessions without agent panes still appear, so an older
// tmux-agents (one without `rows --json`) degrades to "no worktree ordering"
// rather than "shell-only sessions vanish".
func (p *Provider) synthesise(ctx context.Context) ([]Row, error) {
	if p.Fallback == nil {
		return nil, errors.New("no agents source")
	}
	panes, err := p.Fallback.ListPanes(ctx)
	if err != nil {
		return nil, err
	}

	type group struct {
		name   string
		active string
		path   string
		label  string
		panes  []tmux.Pane
	}
	var order []*group
	byName := map[string]*group{}
	for _, pn := range panes {
		g := byName[pn.Session]
		if g == nil {
			g = &group{name: pn.Session, active: pn.ID, path: pn.Path, label: pn.SessionLabel}
			byName[pn.Session] = g
			order = append(order, g)
		}
		g.panes = append(g.panes, pn)
		if pn.Active && pn.WindowActive {
			g.active, g.path = pn.ID, pn.Path
		}
	}

	rows := make([]Row, 0, len(panes)+len(order))
	for _, g := range order {
		repo, branch := p.repoInfo(ctx, g.path)
		rows = append(rows, Row{
			ID:      "s:" + g.name,
			Kind:    "session",
			Session: g.name,
			Pane:    g.active,
			Label:   g.label,
			Repo:    repo,
			Branch:  branch,
			Path:    g.path,
			Panes:   len(g.panes),
		})
		for _, pn := range g.panes {
			kind, label := Detect(pn.Title, pn.Command)
			if kind == "" {
				continue
			}
			rows = append(rows, Row{
				ID:         "p:" + pn.ID,
				Kind:       "pane",
				Session:    g.name,
				Pane:       pn.ID,
				Label:      label,
				Agent:      kind,
				State:      pn.AgentState,
				Unseen:     flexBool(pn.AgentUnseen),
				Repo:       repo,
				Branch:     branch,
				Path:       pn.Path,
				Window:     fmt.Sprint(pn.WindowIndex),
				WindowName: pn.WindowName,
			})
		}
	}
	return rows, nil
}

// repoInfo resolves a directory to its worktree root and branch, cached per
// path. Anything that is not a git checkout yields empty strings.
func (p *Provider) repoInfo(ctx context.Context, path string) (string, string) {
	if p.Git == nil || path == "" {
		return "", ""
	}
	if v, ok := p.repoCache[path]; ok {
		return v.repo, v.branch
	}
	found, err := p.Git.Find(ctx, path)
	if err != nil {
		p.repoCache[path] = repoInfo{}
		return "", ""
	}
	v := repoInfo{repo: found.Root, branch: found.Branch}
	p.repoCache[path] = v
	return v.repo, v.branch
}

type repoInfo struct{ repo, branch string }

// Detect mirrors agent_kind/agent_label in tmux-agents.sh: omp announces itself
// through the terminal title, opencode through its title plus the running
// command. It is only used when the plugin is not installed.
func Detect(title, command string) (kind, label string) {
	switch {
	case title == "π" || strings.HasPrefix(title, "π:") || strings.HasPrefix(title, "π "):
		kind = "omp"
		rest := []rune(strings.TrimPrefix(title, "π"))
		if len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
		if len(rest) > 0 {
			rest = rest[1:] // state glyph or '>'/'!'
		}
		if len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
		label = string(rest)
	case title == "OpenCode" || strings.HasPrefix(title, "OC | "):
		if command == "opencode" || command == "nono" {
			kind = "opencode"
			label = strings.TrimPrefix(title, "OC | ")
			if label == "OpenCode" {
				label = "opencode"
			}
		}
	}
	return kind, label
}

// StateFromTitle guesses an omp pane's state from its title alone. It is only
// used when the tmux-agents tick has not published @agent_state (plugin not
// installed); the tick remains the source of truth.
func StateFromTitle(title string) string {
	if !strings.HasPrefix(title, "π") {
		return "idle"
	}
	rest := strings.TrimSpace(strings.TrimPrefix(title, "π"))
	switch {
	case rest == "", strings.HasPrefix(rest, ">"), strings.HasPrefix(rest, ":"):
		return "idle"
	case strings.HasPrefix(rest, "!"):
		return "input"
	}
	return "working"
}

// flexBool accepts JSON booleans and the 0/1 numbers the plugin used to emit for
// worktree/unseen. A type mismatch here is not a small bug: the whole rows
// payload fails to decode and the inbox silently degrades to title detection.
type flexBool bool

func (b *flexBool) UnmarshalJSON(data []byte) error {
	switch string(data) {
	case "true", "1":
		*b = true
	case "false", "0", "null", `""`:
		*b = false
	default:
		return fmt.Errorf("flexBool: unexpected %s", data)
	}
	return nil
}

// Bool reports the decoded value.
func (b flexBool) Bool() bool { return bool(b) }
