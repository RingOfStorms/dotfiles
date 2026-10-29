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

	mu   sync.Mutex
	at   time.Time
	rows []Row
}

// New returns a provider. bin is the tmux-agents executable; when it is empty or
// missing, rows are synthesised from list-panes (no repo/branch grouping).
func New(bin string, fallback *tmux.Client) *Provider {
	return &Provider{Bin: bin, Fallback: fallback, TTL: time.Second}
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
			p.Log.Warn("tmux-agents rows failed; using title detection only", "bin", p.Bin, "err", err)
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
func (p *Provider) synthesise(ctx context.Context) ([]Row, error) {
	if p.Fallback == nil {
		return nil, errors.New("no agents source")
	}
	panes, err := p.Fallback.ListPanes(ctx)
	if err != nil {
		return nil, err
	}
	rows := make([]Row, 0, len(panes))
	for _, pn := range panes {
		kind, label := Detect(pn.Title, pn.Command)
		if kind == "" {
			continue
		}
		rows = append(rows, Row{
			ID:         "p:" + pn.ID,
			Kind:       "pane",
			Session:    pn.Session,
			Pane:       pn.ID,
			Label:      label,
			Agent:      kind,
			State:      pn.AgentState,
			Unseen:     flexBool(pn.AgentUnseen),
			Path:       pn.Path,
			Window:     fmt.Sprint(pn.WindowIndex),
			WindowName: pn.WindowName,
		})
	}
	return rows, nil
}

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
