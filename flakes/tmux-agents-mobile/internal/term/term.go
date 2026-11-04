// Package term runs the terminal tab: the service user's login shell on a PTY,
// streamed to xterm.js over a WebSocket.
//
// Unlike the pane views this is a real terminal, not a tmux client: it never
// touches the tmux server. A shell outlives its WebSocket for a while (phones
// drop sockets whenever the app is backgrounded), and every byte of output is
// numbered, so a browser that reconnects asks for "everything after byte N"
// and its screen continues exactly where it stopped. A browser that has lost
// its screen (reload, new tab) gets the replay buffer instead.
package term

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// Config is the shell every session starts and how long it lives unattached.
type Config struct {
	Shell string   // absolute path; started as a login shell ("-zsh")
	Dir   string   // starting directory
	Env   []string // full environment of the shell

	// Detach is how long a shell with no browser attached is kept before it is
	// hung up. Zero uses the default.
	Detach time.Duration
	// Scrollback is how many bytes of output are kept for a browser that
	// reconnects without its screen. Zero uses the default.
	Scrollback int
	// MaxSessions bounds the number of shells. When it is reached the
	// longest-detached shell is ended to make room; a new one is refused only
	// when every shell has a browser attached. Zero uses the default.
	MaxSessions int

	Log *slog.Logger
}

// ErrTooMany is returned when every allowed shell is in use.
var ErrTooMany = errors.New("every terminal session is attached; close one first")

const (
	defaultDetach      = time.Hour
	defaultScrollback  = 512 << 10
	defaultMaxSessions = 8
	// killGrace is how long a hung-up shell gets before SIGKILL.
	killGrace = 3 * time.Second
)

// Manager owns the running shells.
type Manager struct {
	cfg Config

	mu       sync.Mutex
	sessions map[string]*Session
	closed   bool
}

// NewManager applies defaults; no shell is started until a browser asks.
func NewManager(cfg Config) *Manager {
	if cfg.Detach <= 0 {
		cfg.Detach = defaultDetach
	}
	if cfg.Scrollback <= 0 {
		cfg.Scrollback = defaultScrollback
	}
	if cfg.MaxSessions <= 0 {
		cfg.MaxSessions = defaultMaxSessions
	}
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.DiscardHandler)
	}
	return &Manager{cfg: cfg, sessions: map[string]*Session{}}
}

// Open returns the live session with this id, or starts a new shell sized
// cols x rows when the id is empty, unknown, or its shell has ended. created
// tells the caller which happened: a new shell has nothing to replay.
func (m *Manager) Open(id string, cols, rows int) (s *Session, created bool, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, false, errors.New("terminal manager is shut down")
	}
	if s, ok := m.sessions[id]; ok && !s.ended() {
		return s, false, nil
	}
	if len(m.sessions) >= m.cfg.MaxSessions {
		victim := m.longestDetachedLocked()
		if victim == nil {
			return nil, false, ErrTooMany
		}
		m.cfg.Log.Info("terminal: ending the longest-detached shell to make room", "id", victim.ID)
		delete(m.sessions, victim.ID)
		victim.Kill()
	}
	s, err = m.start(cols, rows)
	if err != nil {
		return nil, false, err
	}
	m.sessions[s.ID] = s
	return s, true, nil
}

// Close hangs up every shell. Used on shutdown.
func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	all := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		all = append(all, s)
	}
	m.mu.Unlock()
	for _, s := range all {
		s.Kill()
	}
}

func (m *Manager) longestDetachedLocked() *Session {
	var victim *Session
	var since time.Time
	for _, s := range m.sessions {
		at, detached := s.detachedSince()
		if detached && (victim == nil || at.Before(since)) {
			victim, since = s, at
		}
	}
	return victim
}

func (m *Manager) remove(s *Session) {
	m.mu.Lock()
	if m.sessions[s.ID] == s {
		delete(m.sessions, s.ID)
	}
	m.mu.Unlock()
}

func (m *Manager) start(cols, rows int) (*Session, error) {
	id, err := newID()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(m.cfg.Shell)
	// A leading dash in argv[0] is how login(1) asks for a login shell, and it
	// works for every shell: /etc/profile runs, so the PATH and environment
	// are the user's, not the service's.
	cmd.Args = []string{"-" + filepath.Base(m.cfg.Shell)}
	cmd.Dir = m.cfg.Dir
	cmd.Env = m.cfg.Env
	ptmx, err := pty.StartWithSize(cmd, winsize(cols, rows))
	if err != nil {
		return nil, err
	}
	s := &Session{
		ID:     id,
		m:      m,
		cmd:    cmd,
		pty:    ptmx,
		notify: make(chan struct{}),
		limit:  m.cfg.Scrollback,
	}
	m.cfg.Log.Info("terminal: shell started", "id", id, "pid", cmd.Process.Pid, "shell", m.cfg.Shell)
	// Nothing is attached yet: if the browser never completes the WebSocket
	// handshake the shell is reaped like any other detached one.
	s.mu.Lock()
	s.detachLocked()
	s.mu.Unlock()
	go s.pump()
	return s, nil
}

// Session is one shell on one PTY.
type Session struct {
	ID string

	m     *Manager
	cmd   *exec.Cmd
	pty   *os.File
	limit int

	mu sync.Mutex
	// buf holds the newest output; it covers byte offsets [end-len(buf), end).
	// It is allowed to grow to twice the limit before it is cut back, so the
	// copy is amortised instead of happening on every read.
	buf    []byte
	end    int64
	notify chan struct{} // closed and replaced whenever output or state changes
	exited bool
	code   int

	gen        uint64        // attach generation; a newer attach kicks the older one
	kick       chan struct{} // closed when the current attachment is taken over
	attached   bool
	detachedAt time.Time
	reap       *time.Timer
	killOnce   sync.Once

	// out serializes attach with the current attachment's output writes, so
	// delivered is exact when attach reads it: a write either finished and
	// was counted before the switch, or starts after it, sees the kick and
	// is not made. Held over a network write (bounded by writeTimeout), so
	// never while holding mu; taken before mu.
	out sync.Mutex
	// delivered is how far output has been written to the sockets of the
	// attachments: sent to a browser, not necessarily shown by it. It only
	// grows.
	delivered int64
	// history is the newest replay boundary: output before it was redrawn
	// as history or delivered to an attachment other than the current one.
	// It only grows, so a screen that reconnects before it has parsed up to
	// its boundary is given the rest as history again.
	history int64
}

func (s *Session) pump() {
	b := make([]byte, 32<<10)
	for {
		n, err := s.pty.Read(b)
		if n > 0 {
			s.mu.Lock()
			s.buf = append(s.buf, b[:n]...)
			s.end += int64(n)
			if len(s.buf) > 2*s.limit {
				s.buf = s.buf[:copy(s.buf, s.buf[len(s.buf)-s.limit:])]
			}
			s.broadcastLocked()
			s.mu.Unlock()
		}
		if err != nil {
			// EIO once the last process holding the PTY's slave side exits;
			// ErrClosed after Kill.
			break
		}
	}
	code := 0
	if err := s.cmd.Wait(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		} else {
			code = -1
		}
	}
	_ = s.pty.Close()
	s.mu.Lock()
	s.exited = true
	s.code = code
	if s.reap != nil {
		s.reap.Stop()
	}
	s.broadcastLocked()
	s.mu.Unlock()
	s.m.remove(s)
	s.m.cfg.Log.Info("terminal: shell ended", "id", s.ID, "code", code)
}

func (s *Session) broadcastLocked() {
	close(s.notify)
	s.notify = make(chan struct{})
}

// chunk is a slice of output starting at byte offset At.
type chunk struct {
	Data  []byte
	At    int64
	Next  int64 // offset after Data
	End   int64 // all output written so far, read under the same lock
	Reset bool  // the requested offset is gone: clear the screen, Data starts at At
	More  bool  // output beyond Next is already buffered
}

// since returns up to max bytes of output from offset from, together with the
// session state read under the same lock: when exited is true and More is
// false, the caller has seen every byte the shell wrote.
func (s *Session) since(from int64, max int) (c chunk, exited bool, code int, wait <-chan struct{}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	start := s.end - int64(len(s.buf))
	at := from
	if from < start || from > s.end {
		c.Reset = true
		at = start
		// The buffer was cut at an arbitrary byte, possibly inside an escape
		// sequence or a UTF-8 rune. Start the replay at the next line instead.
		if start > 0 {
			if i := bytes.IndexByte(s.buf[:min(len(s.buf), 4096)], '\n'); i >= 0 {
				at = start + int64(i) + 1
			}
		}
	}
	stop := min(s.end, at+int64(max))
	c.At = at
	c.Next = stop
	c.End = s.end
	c.More = stop < s.end
	if stop > at {
		c.Data = append([]byte(nil), s.buf[at-start:stop-start]...)
	}
	return c, s.exited, s.code, s.notify
}

// Write sends input to the shell.
func (s *Session) Write(p []byte) error {
	_, err := s.pty.Write(p)
	return err
}

// Resize sets the PTY size; the shell gets SIGWINCH.
func (s *Session) Resize(cols, rows int) error {
	return pty.Setsize(s.pty, winsize(cols, rows))
}

// Kill hangs up the shell's process group, then kills it if it lingers.
func (s *Session) Kill() {
	s.killOnce.Do(func() {
		if s.ended() {
			// Reaped already: the pid may belong to someone else by now.
			return
		}
		pid := s.cmd.Process.Pid
		// The shell is a session leader (pty.Start sets Setsid), so its pid is
		// also its process group: HUP reaches the shell and its foreground job.
		_ = syscall.Kill(-pid, syscall.SIGHUP)
		time.AfterFunc(killGrace, func() {
			if !s.ended() {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
				_ = s.pty.Close()
			}
		})
	})
}

func (s *Session) ended() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exited
}

// attach makes the caller the session's only browser. A previous attachment
// is told to go away through its kick channel. last is the generation that
// last drew the browser's screen; when it is not the attachment being
// replaced, another browser has had the shell since, and the output it was
// sent is history to this screen. history is the session's replay boundary,
// read in the same critical section that makes gen current. attach waits for
// an output write in flight to finish (see out).
func (s *Session) attach(last uint64) (gen uint64, history int64, kicked <-chan struct{}) {
	s.out.Lock()
	defer s.out.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.kick != nil {
		close(s.kick)
	}
	if last != s.gen {
		s.history = max(s.history, s.delivered)
	}
	s.gen++
	s.kick = make(chan struct{})
	s.attached = true
	if s.reap != nil {
		s.reap.Stop()
		s.reap = nil
	}
	return s.gen, s.history, s.kick
}

// replayed records that attachment gen marked output before until as history.
func (s *Session) replayed(gen uint64, until int64) {
	s.mu.Lock()
	if gen == s.gen && until > s.history {
		s.history = until
	}
	s.mu.Unlock()
}

// detach ends an attachment. Only the current one counts: a browser that was
// kicked by a newer one must not start the reap timer under it.
func (s *Session) detach(gen uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if gen != s.gen || s.exited {
		return
	}
	s.kick = nil
	s.detachLocked()
}

func (s *Session) detachLocked() {
	s.attached = false
	s.detachedAt = time.Now()
	gen := s.gen
	s.reap = time.AfterFunc(s.m.cfg.Detach, func() {
		s.mu.Lock()
		stale := !s.attached && s.gen == gen
		s.mu.Unlock()
		if stale {
			s.m.cfg.Log.Info("terminal: detached too long, hanging up", "id", s.ID)
			s.Kill()
		}
	})
}

func (s *Session) detachedSince() (time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.detachedAt, !s.attached && !s.exited
}

func winsize(cols, rows int) *pty.Winsize {
	clamp := func(v, def int) uint16 {
		switch {
		case v <= 0:
			return uint16(def)
		case v > 1000:
			return 1000
		}
		return uint16(v)
	}
	return &pty.Winsize{Cols: clamp(cols, 80), Rows: clamp(rows, 24)}
}

func newID() (string, error) {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// LoginShell is the shell to run for the current user: $SHELL when it is an
// absolute path to an executable, else the user's /etc/passwd entry, else
// /bin/sh. launchd agents get no $SHELL, and a minimal systemd environment
// might not either, so the passwd entry is the real source of truth.
func LoginShell() string {
	if sh := os.Getenv("SHELL"); filepath.IsAbs(sh) && executable(sh) {
		return sh
	}
	if sh := passwdShell("/etc/passwd", os.Getuid()); sh != "" && executable(sh) {
		return sh
	}
	return "/bin/sh"
}

func passwdShell(path string, uid int) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	want := strconv.Itoa(uid)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		// name:password:uid:gid:gecos:home:shell
		fields := strings.Split(sc.Text(), ":")
		if len(fields) == 7 && fields[2] == want {
			return fields[6]
		}
	}
	return ""
}

func executable(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

// ShellEnv is the environment a shell starts with: the service's own minus
// what belongs to the service (its configuration and systemd's per-unit
// plumbing), plus the terminal type xterm.js implements.
func ShellEnv(base []string) []string {
	env := make([]string, 0, len(base)+2)
	for _, kv := range base {
		name, _, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(name, "TAM_"),
			// systemd: the shell is not the unit's main process, and anything
			// that logs to JOURNAL_STREAM or notifies NOTIFY_SOCKET would be
			// talking on the service's behalf.
			name == "JOURNAL_STREAM", name == "NOTIFY_SOCKET", name == "INVOCATION_ID",
			name == "MANAGERPID", name == "SYSTEMD_EXEC_PID", name == "WATCHDOG_PID", name == "WATCHDOG_USEC",
			strings.HasPrefix(name, "LISTEN_"),
			name == "TERM", name == "COLORTERM",
			// Not inside tmux, whatever the service's environment says.
			name == "TMUX", name == "TMUX_PANE":
			continue
		}
		env = append(env, kv)
	}
	return append(env, "TERM=xterm-256color", "COLORTERM=truecolor")
}
