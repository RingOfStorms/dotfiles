// Package tmux is a thin wrapper over the tmux binary: just enough to list
// panes, read a pane's rendered screen and write keys back. It never attaches a
// client, so nothing it does can resize, zoom or select anything on a desktop.
package tmux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// sep is the field delimiter used for every -F format. A tab is safe here
// because Go splits on it without collapsing empty fields (unlike shell
// `read`), and with -u tmux passes it through untouched.
const sep = "\t"

// ErrNoServer is returned when the tmux server is not running.
var ErrNoServer = errors.New("no tmux server running")

// Client runs tmux commands against one server socket.
type Client struct {
	Bin     string        // tmux binary; defaults to "tmux" on PATH
	Socket  string        // -L name; empty uses the default socket
	Timeout time.Duration // per-command timeout; defaults to 3s
}

// New returns a client for the given binary and socket (both optional).
func New(bin, socket string) *Client {
	if bin == "" {
		bin = "tmux"
	}
	return &Client{Bin: bin, Socket: socket, Timeout: 3 * time.Second}
}

func (c *Client) timeout() time.Duration {
	if c.Timeout <= 0 {
		return 3 * time.Second
	}
	return c.Timeout
}

func (c *Client) prefixed(args []string) []string {
	// -u forces UTF-8 regardless of the locale this process inherited. Without
	// it tmux sanitises every non-ASCII byte (and control characters) in -F
	// output to "_", which silently breaks agent titles that carry emoji, e.g.
	// under systemd where LANG may be unset.
	out := make([]string, 0, len(args)+4)
	out = append(out, "-u")
	if c.Socket != "" {
		out = append(out, "-L", c.Socket)
	}
	return append(out, args...)
}

func (c *Client) run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout())
	defer cancel()

	cmd := exec.CommandContext(ctx, c.Bin, c.prefixed(args)...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		switch {
		case ctx.Err() != nil:
			return nil, fmt.Errorf("tmux %s: %w", command(args), ctx.Err())
		case strings.Contains(msg, "no server running"), strings.Contains(msg, "error connecting"):
			return nil, fmt.Errorf("tmux %s: %w: %s", command(args), ErrNoServer, msg)
		case msg == "":
			return nil, fmt.Errorf("tmux %s: %w", command(args), err)
		default:
			return nil, fmt.Errorf("tmux %s: %s", command(args), msg)
		}
	}
	return stdout.Bytes(), nil
}

func command(args []string) string {
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			return a
		}
	}
	return "?"
}

// Pane is one row of `list-panes -a`.
type Pane struct {
	ID             string
	Session        string
	SessionLabel   string
	WindowIndex    int
	WindowName     string
	WindowActive   bool
	Active         bool
	Command        string
	Path           string
	Title          string
	Width          int
	Height         int
	HistorySize    int
	CursorX        int
	CursorY        int
	InMode         bool
	Dead           bool
	Attached       bool
	AgentState     string
	AgentUnseen    bool
	AgentWatchUnix int64
	PaneName       string
}

var listFields = []string{
	"session_name", "window_index", "window_name", "pane_id", "pane_active",
	"window_active", "pane_current_command", "pane_current_path", "pane_title",
	"pane_width", "pane_height", "history_size", "cursor_x", "cursor_y",
	"pane_in_mode", "pane_dead", "session_attached",
	"@agent_state", "@agent_unseen", "@agent_watch_until", "@pane_name",
	"@session_ai_name",
}

// metaFields are the bits of pane state that the frame renderer needs.
var metaFields = []string{
	"pane_width", "pane_height", "cursor_x", "cursor_y", "pane_in_mode",
	"pane_dead", "history_size",
}

func format(fields []string) string {
	parts := make([]string, 0, len(fields))
	for _, f := range fields {
		parts = append(parts, "#{"+f+"}")
	}
	return strings.Join(parts, sep)
}

// ListPanes returns every pane in every session of the server.
func (c *Client) ListPanes(ctx context.Context) ([]Pane, error) {
	out, err := c.run(ctx, nil, "list-panes", "-a", "-F", format(listFields))
	if err != nil {
		return nil, err
	}
	return parsePanes(string(out)), nil
}

// GetPane returns a single pane, or an error when it no longer exists.
func (c *Client) GetPane(ctx context.Context, id string) (Pane, error) {
	out, err := c.run(ctx, nil, "list-panes", "-a", "-F", format(listFields), "-f", "#{==:#{pane_id},"+id+"}")
	if err != nil {
		return Pane{}, err
	}
	panes := parsePanes(string(out))
	if len(panes) == 0 {
		return Pane{}, fmt.Errorf("pane %s: %w", id, ErrNoServer)
	}
	return panes[0], nil
}

func parsePanes(raw string) []Pane {
	var panes []Pane
	for _, line := range strings.Split(strings.TrimRight(raw, "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, sep)
		if len(f) < len(listFields) {
			continue
		}
		panes = append(panes, Pane{
			Session:        f[0],
			WindowIndex:    atoi(f[1]),
			WindowName:     f[2],
			ID:             f[3],
			Active:         f[4] == "1",
			WindowActive:   f[5] == "1",
			Command:        f[6],
			Path:           f[7],
			Title:          f[8],
			Width:          atoi(f[9]),
			Height:         atoi(f[10]),
			HistorySize:    atoi(f[11]),
			CursorX:        atoi(f[12]),
			CursorY:        atoi(f[13]),
			InMode:         f[14] == "1",
			Dead:           f[15] == "1",
			Attached:       f[16] == "1",
			AgentState:     f[17],
			AgentUnseen:    f[18] != "",
			AgentWatchUnix: atoi64(f[19]),
			PaneName:       f[20],
			SessionLabel:   f[21],
		})
	}
	return panes
}

// Meta is the per-tick pane geometry handed to the frame renderer.
type Meta struct {
	Cols        int
	Rows        int
	CursorX     int
	CursorY     int
	InMode      bool
	Dead        bool
	HistorySize int
}

// Meta reads the pane geometry without capturing the screen contents.
func (c *Client) Meta(ctx context.Context, id string) (Meta, error) {
	out, err := c.run(ctx, nil, "display-message", "-p", "-t", id, "-F", format(metaFields))
	if err != nil {
		return Meta{}, err
	}
	f := strings.Split(strings.TrimRight(string(out), "\n"), sep)
	if len(f) < len(metaFields) {
		return Meta{}, fmt.Errorf("tmux display-message: short reply for %s", id)
	}
	return Meta{
		Cols:        atoi(f[0]),
		Rows:        atoi(f[1]),
		CursorX:     atoi(f[2]),
		CursorY:     atoi(f[3]),
		InMode:      f[4] == "1",
		Dead:        f[5] == "1",
		HistorySize: atoi(f[6]),
	}, nil
}

// CaptureOpts selects how much of a pane's screen capture-pane returns.
type CaptureOpts struct {
	Escapes          bool // -e: keep SGR sequences
	Join             bool // -J: join lines wrapped by the terminal (reflow-friendly)
	PreserveTrailing bool // -N: keep trailing blanks (fixed-width grids)
	Start            int  // -S: 0 = first visible line, negative = history
	End              int  // -E: 0 = last visible line, negative = history
	StartSet         bool
	EndSet           bool
}

// Capture returns the pane's rendered screen as text.
func (c *Client) Capture(ctx context.Context, id string, o CaptureOpts) (string, error) {
	args := []string{"capture-pane", "-p", "-t", id}
	if o.Escapes {
		args = append(args, "-e")
	}
	if o.Join {
		args = append(args, "-J")
	} else if o.PreserveTrailing {
		args = append(args, "-N")
	}
	if o.StartSet {
		args = append(args, "-S", strconv.Itoa(o.Start))
	}
	if o.EndSet {
		args = append(args, "-E", strconv.Itoa(o.End))
	}
	out, err := c.run(ctx, nil, args...)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// SendKeys sends tmux key names ("Enter", "C-c", "Up", …) to a pane.
func (c *Client) SendKeys(ctx context.Context, id string, keys ...string) error {
	if len(keys) == 0 {
		return nil
	}
	args := append([]string{"send-keys", "-t", id}, keys...)
	_, err := c.run(ctx, nil, args...)
	return err
}

// SendText types literal text into a pane (no key-name interpretation).
// A leading "-" is not special: tmux stops option parsing at "--".
func (c *Client) SendText(ctx context.Context, id, text string) error {
	_, err := c.run(ctx, nil, "send-keys", "-l", "-t", id, "--", text)
	return err
}

var bufferSeq atomic.Uint64

// Paste delivers text through a tmux paste buffer using bracketed paste when
// the pane's application asked for it. This is the path for multi-line text:
// send-keys would make the application see one Enter per line.
func (c *Client) Paste(ctx context.Context, id, text string) error {
	name := fmt.Sprintf("tam-%d-%d", os.Getpid(), bufferSeq.Add(1))
	if _, err := c.run(ctx, []byte(text), "load-buffer", "-b", name, "-"); err != nil {
		return err
	}
	_, err := c.run(ctx, nil, "paste-buffer", "-p", "-d", "-b", name, "-t", id)
	return err
}

// NewSession creates a detached session in dir and returns its first pane ID.
func (c *Client) NewSession(ctx context.Context, name, dir, program string) (string, error) {
	args := []string{"new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name}
	if dir != "" {
		args = append(args, "-c", dir)
	}
	if program != "" {
		args = append(args, program)
	}
	out, err := c.run(ctx, nil, args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// NewWindow creates a detached window in session and returns its pane ID.
func (c *Client) NewWindow(ctx context.Context, session, dir, program string) (string, error) {
	args := []string{"new-window", "-d", "-P", "-F", "#{pane_id}", "-t", session + ":"}
	if dir != "" {
		args = append(args, "-c", dir)
	}
	if program != "" {
		args = append(args, program)
	}
	out, err := c.run(ctx, nil, args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// HasSession reports whether a session with exactly this name exists.
func (c *Client) HasSession(ctx context.Context, name string) bool {
	_, err := c.run(ctx, nil, "has-session", "-t", "="+name)
	return err == nil
}

// KillPane and KillSession are the destructive actions the web layer wraps in
// a confirmation.
func (c *Client) KillPane(ctx context.Context, id string) error {
	_, err := c.run(ctx, nil, "kill-pane", "-t", id)
	return err
}

func (c *Client) KillSession(ctx context.Context, name string) error {
	_, err := c.run(ctx, nil, "kill-session", "-t", "="+name)
	return err
}

// AttachedClient is one attached tmux client (a terminal, never the phone: the
// web service does not attach).
type AttachedClient struct {
	Name    string
	TTY     string
	Width   int
	Height  int
	Session string
}

// Clients lists attached clients.
func (c *Client) Clients(ctx context.Context) ([]AttachedClient, error) {
	fields := []string{"client_name", "client_tty", "client_width", "client_height", "client_session"}
	out, err := c.run(ctx, nil, "list-clients", "-F", format(fields))
	if err != nil {
		if errors.Is(err, ErrNoServer) {
			return nil, nil
		}
		return nil, err
	}
	var clients []AttachedClient
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, sep)
		if len(f) < len(fields) {
			continue
		}
		clients = append(clients, AttachedClient{
			Name:    f[0],
			TTY:     f[1],
			Width:   atoi(f[2]),
			Height:  atoi(f[3]),
			Session: f[4],
		})
	}
	return clients, nil
}

// FocusOnDesktop switches the largest attached client to the pane's window and
// makes that pane active. It is the only call in this package that changes what
// a desktop shows, and it only runs when the user asks for it.
func (c *Client) FocusOnDesktop(ctx context.Context, pane string) error {
	clients, err := c.Clients(ctx)
	if err != nil {
		return err
	}
	if len(clients) == 0 {
		return errors.New("no attached tmux client to focus")
	}
	best := clients[0]
	for _, cl := range clients[1:] {
		if cl.Width*cl.Height > best.Width*best.Height {
			best = cl
		}
	}
	_, err = c.run(ctx, nil, "switch-client", "-c", best.Name, "-t", pane)
	return err
}

// SetPaneOption sets a pane option; UnsetPaneOption removes it.
func (c *Client) SetPaneOption(ctx context.Context, pane, name, value string) error {
	_, err := c.run(ctx, nil, "set-option", "-p", "-t", pane, name, value)
	return err
}

func (c *Client) UnsetPaneOption(ctx context.Context, pane, name string) error {
	_, err := c.run(ctx, nil, "set-option", "-p", "-u", "-t", pane, name)
	return err
}

// Display evaluates a format for a target pane.
func (c *Client) Display(ctx context.Context, target, f string) (string, error) {
	out, err := c.run(ctx, nil, "display-message", "-p", "-t", target, f)
	if err != nil {
		return "", err
	}
	return strings.TrimRight(string(out), "\n"), nil
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}
