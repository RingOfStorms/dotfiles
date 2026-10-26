// Package shareserve implements `fleet-share-serve` and `fleet-share-apply`,
// o002's handlers for the `share` ssh user (containers/FLOWS-AUDIT.md §(c),
// "Local temporary sharing via *.share.joshuabell.xyz"). It never touches
// h005 or the fleet-edge-overrides state.
//
// `share` is kept fully unprivileged: it never runs nginx, never writes
// nginx config text, and never reloads anything. sshd's Match block
// (hosts/_shared_assets/utilities/share-receiver.nix) forces every session
// as `share` into `fleet-share-serve`, which:
//
//  1. parses `<name> <boundport> [<forSeconds>]` from $SSH_ORIGINAL_COMMAND;
//  2. re-derives port ownership itself by reading /proc/net/tcp (world-
//     readable, no root/CAP_NET_ADMIN/ptrace needed) for a 127.0.0.1 LISTEN
//     row at that port whose uid is this process's own. Only a
//     `share`-owned sshd session's `-R` forward can hold such a socket, so a
//     client can never name a port held by some other uid's service (e.g.
//     headscale on 127.0.0.1:8080);
//  3. writes a small JSON *request* `{name, port}` -- never rendered nginx
//     text -- into Config.RequestsDir (share-writable, 0700, the ONLY
//     directory `share` can write to) and waits for a `.status` file
//     written back by `fleet-share-apply` into Config.StatusDir
//     (root-owned, world-readable).
//
// `fleet-share-apply` runs as root, triggered by a systemd `.path` unit
// watching Config.RequestsDir. Nothing root writes ever lives inside a
// share-writable directory: `share` owns RequestsDir alone and could
// otherwise rename it out from under root or plant a symlink in place of a
// request, so every request is opened with O_NOFOLLOW and then re-checked
// by fstat (regular file, owned by the share uid, capped in size) before a
// single byte of it is trusted; it is deleted only via unlinkat, never by
// following a path a second time. For every surviving `<name>.new` it
// re-validates the name/port *from scratch* (never trusting the file's text
// beyond those two parsed primitives) and renders the vhost itself into
// Config.ConfDir (root-owned; nginx's `include` only ever reads from
// there), then nginx -t's and reloads with the real, unmodified `-c`. On
// failure it removes the conf it just wrote and reloads again, then
// reports ok/error back via `.status`. `<name>.remove` markers (written by
// Serve on exit) are handled the same way, minus the status report. A
// timer (fleet-share-sweep) separately removes any ConfDir entry whose
// port isn't currently live, plus stale requests/statuses, in case a crash
// skipped a step.
package shareserve

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Config is the receiver's build-time configuration (JSON file on o002).
type Config struct {
	Domain string `json:"domain"` // "share.joshuabell.xyz"
	// RequestsDir is share-writable (0700 share:share) and the ONLY
	// directory `share` can write to. Nothing root writes may live here:
	// root only ever reads from it (openRequestFile) and deletes from it
	// (removeAt), both without following a path share could have swapped.
	RequestsDir string `json:"requestsDir"`
	// ConfDir is root-owned (0755): rendered vhosts nginx includes.
	ConfDir string `json:"confDir"`
	// StatusDir is root-owned (0755, world-readable): `.status` files
	// `share` polls and reads, never writes.
	StatusDir string `json:"statusDir"`
	CertDir   string `json:"certDir"` // holds fullchain.pem, key.pem for Domain
	// ShareUser is the unprivileged ssh user name ("share"). Apply (root)
	// looks up its uid itself -- it never trusts anything from the laptop
	// or from fleet-share-serve beyond the two JSON primitives.
	ShareUser string `json:"shareUser"`
	// NginxTest and NginxReload are shell commands (exit 0 = ok), run only
	// by fleet-share-apply (root), never by fleet-share-serve (share).
	NginxTest   string `json:"nginxTest"`
	NginxReload string `json:"nginxReload"`
	LimitZone   string `json:"limitZone"` // limit_req zone name defined in http{}
	MaxFor      int64  `json:"maxFor"`    // seconds; the --for cap, server-enforced
}

var nameRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// Request is one parsed, validated share (used both for ParseCommand's
// $SSH_ORIGINAL_COMMAND and for the JSON request read back by Apply).
type Request struct {
	Name string
	Port int
	For  time.Duration // 0 means Config.MaxFor; irrelevant to Apply
}

// ParseCommand parses "<name> <boundport> [<forSeconds>]".
func ParseCommand(cmd string) (Request, error) {
	fields := strings.Fields(cmd)
	if len(fields) < 2 || len(fields) > 3 {
		return Request{}, fmt.Errorf("want \"<name> <port> [<forSeconds>]\", got %q", cmd)
	}
	name := fields[0]
	port, err := strconv.Atoi(fields[1])
	if err != nil || port < 1 || port > 65535 {
		return Request{}, fmt.Errorf("port %q out of range", fields[1])
	}
	var d time.Duration
	if len(fields) == 3 {
		secs, err := strconv.ParseInt(fields[2], 10, 64)
		if err != nil || secs < 0 {
			return Request{}, fmt.Errorf("for %q invalid", fields[2])
		}
		d = time.Duration(secs) * time.Second
	}
	return Request{Name: name, Port: port, For: d}, nil
}

// Validate checks the name and duration against the config.
func (c *Config) Validate(r Request) error {
	if !nameRe.MatchString(r.Name) {
		return fmt.Errorf("name %q: want [a-z0-9-]{1,63}", r.Name)
	}
	if r.Port < 1 || r.Port > 65535 {
		return fmt.Errorf("port %d out of range", r.Port)
	}
	if r.For < 0 {
		return errors.New("for must be >= 0")
	}
	return nil
}

// forDuration returns the effective cap: r.For if set and within MaxFor,
// else MaxFor (0 means no configured cap: 24h hardcoded floor).
func (c *Config) forDuration(r Request) time.Duration {
	max := time.Duration(c.MaxFor) * time.Second
	if max <= 0 {
		max = 24 * time.Hour
	}
	if r.For <= 0 || r.For > max {
		return max
	}
	return r.For
}

// procNetTCP reads /proc/net/tcp (var for tests). It's world-readable (no
// root, no CAP_NET_ADMIN, no ptrace relationship needed -- unlike `ss`,
// which needs a privileged owner lookup, or reading a sibling/parent
// process's /proc/<pid>/fd, which Yama's default ptrace_scope=1 refuses
// unless the reader is an ancestor of the target).
var procNetTCP = func() ([]byte, error) {
	return os.ReadFile("/proc/net/tcp")
}

// procNetTCPLine matches one /proc/net/tcp row: local address:port (hex,
// little-endian), connection state (0A = TCP_LISTEN), and the socket's uid.
var procNetTCPLine = regexp.MustCompile(`^\s*\d+:\s+([0-9A-Fa-f]{8}):([0-9A-Fa-f]{4})\s+[0-9A-Fa-f]{8}:[0-9A-Fa-f]{4}\s+([0-9A-Fa-f]{2})\s+\S+\s+\S+\s+\S+\s+(\d+)`)

// loopbackListener is one 127.0.0.1 LISTEN row.
type loopbackListener struct {
	port int
	uid  int
}

// loopbackListeners parses /proc/net/tcp for 127.0.0.1 listeners.
func loopbackListeners(data []byte) []loopbackListener {
	var out []loopbackListener
	for _, line := range strings.Split(string(data), "\n") {
		m := procNetTCPLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if m[1] != "0100007F" || m[3] != "0A" {
			continue // not 127.0.0.1, or not LISTEN
		}
		port, err := strconv.ParseUint(m[2], 16, 32)
		if err != nil {
			continue
		}
		uid, err := strconv.Atoi(m[4])
		if err != nil {
			continue
		}
		out = append(out, loopbackListener{port: int(port), uid: uid})
	}
	return out
}

// Getuid is os.Getuid (var for tests).
var Getuid = os.Getuid

// VerifyPort reports whether port is a 127.0.0.1 listener bound by this
// process's own uid (the `share` user). Only a `share`-owned sshd session
// can hold such a socket (its `-R` forward), so this is what stops a
// client from naming a port it doesn't own -- in particular, it can never
// name a port held by a different-uid system service (e.g. headscale on
// 127.0.0.1:8080), no matter what the client claims.
func VerifyPort(port int) error {
	return verifyPortUID(port, Getuid())
}

// LookupUID resolves a username to a numeric uid (var for tests).
var LookupUID = func(username string) (int, error) {
	u, err := user.Lookup(username)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(u.Uid)
}

// VerifyPortForUser is Apply's (root's) own re-check: it never trusts that
// a port claimed by a request actually belongs to the share user -- it
// looks the uid up itself and re-reads /proc/net/tcp fresh, exactly like
// VerifyPort does for its own uid.
func VerifyPortForUser(port int, username string) error {
	uid, err := LookupUID(username)
	if err != nil {
		return fmt.Errorf("looking up user %q: %w", username, err)
	}
	return verifyPortUID(port, uid)
}

func verifyPortUID(port, uid int) error {
	data, err := procNetTCP()
	if err != nil {
		return fmt.Errorf("read /proc/net/tcp: %w", err)
	}
	for _, l := range loopbackListeners(data) {
		if l.port == port && l.uid == uid {
			return nil
		}
	}
	return fmt.Errorf("port %d is not a 127.0.0.1 listener owned by the share user", port)
}

func (c *Config) confPath(name string) string   { return filepath.Join(c.ConfDir, name+".conf") }
func (c *Config) statusPath(name string) string { return filepath.Join(c.StatusDir, name+".status") }
func newName(name string) string                { return name + ".new" }
func removeName(name string) string             { return name + ".remove" }

// Render returns the nginx file for a validated share.
func Render(c *Config, r Request) string {
	fqdn := r.Name + "." + c.Domain
	var b strings.Builder
	fmt.Fprintf(&b, "# fleet-share-apply: %s -> 127.0.0.1:%d; do not edit\n", fqdn, r.Port)
	fmt.Fprintf(&b, "server {\n  listen 80;\n  listen [::]:80;\n  server_name %s;\n  location / { return 301 https://$host$request_uri; }\n}\n", fqdn)
	fmt.Fprintf(&b, "server {\n  listen 443 ssl;\n  listen [::]:443 ssl;\n  server_name %s;\n", fqdn)
	fmt.Fprintf(&b, "  ssl_certificate %s/fullchain.pem;\n  ssl_certificate_key %s/key.pem;\n", c.CertDir, c.CertDir)
	if c.LimitZone != "" {
		fmt.Fprintf(&b, "  limit_req zone=%s burst=100 nodelay;\n", c.LimitZone)
	}
	b.WriteString("  add_header X-Robots-Tag noindex;\n")
	// Strip oauth2-proxy cookies before the backend (ROUTING-PLAN §4,
	// shared pattern with nginxSnippets.cookieStrip).
	b.WriteString("  set $fleet_cookie $http_cookie;\n")
	for range 4 {
		b.WriteString("  if ($fleet_cookie ~ \"^(.*?)(?:^|;\\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$\") {\n    set $fleet_cookie $1$2;\n  }\n")
	}
	b.WriteString("  if ($fleet_cookie ~ \"_oauth2_proxy\") {\n    set $fleet_cookie \"\";\n  }\n")
	b.WriteString("  if ($fleet_cookie ~ \"^;\\s*(.*)$\") {\n    set $fleet_cookie $1;\n  }\n")
	b.WriteString("  location / {\n")
	fmt.Fprintf(&b, "    proxy_pass http://127.0.0.1:%d;\n", r.Port)
	b.WriteString("    proxy_http_version 1.1;\n")
	b.WriteString("    proxy_set_header Host $host;\n")
	b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Proto $scheme;\n")
	b.WriteString("    proxy_set_header Upgrade $http_upgrade;\n")
	b.WriteString("    proxy_set_header Connection $connection_upgrade;\n")
	b.WriteString("    proxy_set_header Cookie $fleet_cookie;\n")
	b.WriteString("  }\n}\n")
	return b.String()
}

// Runner runs a shell command (var for tests).
var Runner = func(cmd string) error {
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Stdout, c.Stderr = os.Stderr, os.Stderr
	return c.Run()
}

// reload tests and reloads nginx. Only ever called from Apply (root).
func (c *Config) reload() error {
	if err := Runner(c.NginxTest); err != nil {
		return fmt.Errorf("nginx -t: %w", err)
	}
	return Runner(c.NginxReload)
}

// writeFileAtomic writes content as dir/name via os.CreateTemp *in dir*
// (O_EXCL, unpredictable random suffix -- never a guessable "<name>.tmp"
// path a share-writable sibling could symlink in place of), then fsyncs,
// chmods (CreateTemp's own mode is masked by umask) and renames into
// place. dir and the final name are always separate so no caller can ever
// be tricked into writing somewhere else: a concurrent reader (nginx, or
// the .path watcher) never observes a partial write either way.
func writeFileAtomic(dir, name string, content []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(dir, "."+name+".tmp-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, filepath.Join(dir, name)); err != nil {
		return err
	}
	ok = true
	return nil
}

// removeAt deletes dir/name via unlinkat on dir's own open file descriptor,
// never by re-resolving a path: dir is opened once (O_DIRECTORY refuses a
// symlink standing in for it), then name is removed relative to that fd,
// so nothing share could have swapped in between listing and deleting can
// redirect the unlink elsewhere.
func removeAt(dir, name string) error {
	dfd, err := syscall.Open(dir, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(dfd)
	return syscall.Unlinkat(dfd, name)
}

// maxRequestSize caps how large a request file root will ever read: a
// small JSON request is at most a few dozen bytes, so anything near this
// is already suspicious.
const maxRequestSize = 4096

// fstatOwner returns the uid that owns an already-open file (var for
// tests: creating a file actually owned by an arbitrary uid requires
// root, so tests inject a fake answer here instead).
var fstatOwner = func(fi os.FileInfo) (uint32, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return st.Uid, true
}

// openRequestFile opens dir/name the only way root may ever read a file
// `share` wrote: O_NOFOLLOW refuses a symlink outright (share owns dir and
// could otherwise point a request name at an arbitrary root-owned file
// elsewhere on the system), then fstat *on the already-open fd* -- never a
// second, racable path-based stat -- requires a regular file owned by
// shareUID and no larger than maxRequestSize. A FIFO, directory, device or
// oversized file is refused outright.
func openRequestFile(dir, name string, shareUID int) (*os.File, error) {
	path := filepath.Join(dir, name)
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		f.Close()
		return nil, fmt.Errorf("%s: not a regular file", name)
	}
	uid, ok := fstatOwner(fi)
	if !ok {
		f.Close()
		return nil, fmt.Errorf("%s: cannot determine owner", name)
	}
	if int(uid) != shareUID {
		f.Close()
		return nil, fmt.Errorf("%s: not owned by the share user", name)
	}
	if fi.Size() > maxRequestSize {
		f.Close()
		return nil, fmt.Errorf("%s: too large (%d bytes)", name, fi.Size())
	}
	return f, nil
}

// --- fleet-share-serve (runs as the unprivileged `share` user) ---

// shareRequest is the JSON written into Config.RequestsDir by Serve and
// read back by Apply. It carries only the two primitives Apply
// independently re-validates and re-renders from -- never rendered nginx
// text.
type shareRequest struct {
	Name string `json:"name"`
	Port int    `json:"port"`
}

// waitForStatus polls for Config.StatusDir/<name>.status for up to
// timeout, removing it once read if possible (StatusDir is root-owned, so
// this is best-effort; fleet-share-sweep cleans up whatever's left). "ok"
// means success; anything else is the error message from Apply.
func (c *Config) waitForStatus(name string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	p := c.statusPath(name)
	for {
		b, err := os.ReadFile(p)
		if err == nil {
			_ = os.Remove(p)
			return strings.TrimSpace(string(b)), nil
		}
		if !os.IsNotExist(err) {
			return "", err
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("timed out waiting for fleet-share-apply")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// statusWaitTimeout is how long Serve waits for Apply to answer (var for
// tests).
var statusWaitTimeout = 15 * time.Second

// Serve is the forced-command entry point, run as `share`. It never
// touches nginx: it writes a JSON request into the one directory `share`
// can write to (RequestsDir), waits for fleet-share-apply (root, triggered
// by the .path unit on Config.RequestsDir) to render and reload, then
// blocks until the share ends and asks Apply to remove it. stdin is read
// until EOF/error (client disconnect); hup is closed on SIGHUP.
func Serve(c *Config, cmd string, stdin io.Reader, hup <-chan struct{}, stdout io.Writer) error {
	r, err := ParseCommand(cmd)
	if err != nil {
		return err
	}
	if err := c.Validate(r); err != nil {
		return err
	}
	if err := VerifyPort(r.Port); err != nil {
		return err
	}
	reqJSON, err := json.Marshal(shareRequest{Name: r.Name, Port: r.Port})
	if err != nil {
		return err
	}
	if err := writeFileAtomic(c.RequestsDir, newName(r.Name), reqJSON, 0o600); err != nil {
		return fmt.Errorf("writing request: %w", err)
	}
	status, err := c.waitForStatus(r.Name, statusWaitTimeout)
	if err != nil {
		return err
	}
	if status != "ok" {
		return fmt.Errorf("%s", status)
	}

	fqdn := r.Name + "." + c.Domain
	fmt.Fprintf(stdout, "https://%s (closes when this session ends", fqdn)
	d := c.forDuration(r)
	fmt.Fprintf(stdout, ", max %s)\n", d)

	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 4096)
		for {
			if _, err := stdin.Read(buf); err != nil {
				return
			}
		}
	}()

	select {
	case <-done: // client disconnected (stdin EOF)
	case <-hup: // SIGHUP
	case <-time.After(d): // --for cap
	}
	// Best-effort cleanup: ask Apply to remove the vhost. A crash here
	// still leaves the request answered for fleet-share-sweep to catch on
	// Apply's side (it only ever acts on ConfDir, keyed off live ports).
	_ = writeFileAtomic(c.RequestsDir, removeName(r.Name), []byte{}, 0o600)
	return nil
}

// LoadConfig reads the receiver config.
func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return &c, nil
}

// --- fleet-share-apply (runs as root, triggered by the .path unit) ---

// validateRequest re-derives a Request from a parsed shareRequest,
// independently re-validating the name and port: the JSON came from a file
// `share` wrote, so none of it -- including a name crafted to escape
// ConfDir, or an out-of-range port -- is trusted past this point.
func validateRequest(req shareRequest) (Request, error) {
	r := Request{Name: req.Name, Port: req.Port}
	if !nameRe.MatchString(r.Name) {
		return Request{}, fmt.Errorf("name %q: want [a-z0-9-]{1,63}", r.Name)
	}
	if r.Port < 1 || r.Port > 65535 {
		return Request{}, fmt.Errorf("port %d out of range", r.Port)
	}
	return r, nil
}

// Apply processes every `<name>.new` and `<name>.remove` in
// Config.RequestsDir, rendering/removing vhosts in Config.ConfDir and
// reloading nginx. It returns the names it processed. Every request is
// opened via openRequestFile (O_NOFOLLOW + fstat ownership/size checks)
// and deleted via removeAt (unlinkat on the directory fd): nothing here
// ever follows a path a second time after the initial, safe open.
func (c *Config) Apply() ([]string, error) {
	var processed []string

	shareUID, err := LookupUID(c.ShareUser)
	if err != nil {
		return processed, fmt.Errorf("looking up user %q: %w", c.ShareUser, err)
	}

	entries, err := os.ReadDir(c.RequestsDir)
	if err != nil {
		return processed, err
	}
	for _, e := range entries {
		name := e.Name()
		if base, ok := strings.CutSuffix(name, ".new"); ok {
			status := "ok"
			if err := c.applyOne(name, base, shareUID); err != nil {
				status = err.Error()
			}
			_ = writeFileAtomic(c.StatusDir, base+".status", []byte(status), 0o644)
			_ = removeAt(c.RequestsDir, name)
			processed = append(processed, base)
		}
	}

	// Re-list: applyOne above may have been working off a stale
	// directory snapshot's ordering, and .remove markers should be
	// processed after .new so a share that both applied and immediately
	// disconnected within one Apply pass still tears down cleanly.
	entries, err = os.ReadDir(c.RequestsDir)
	if err != nil {
		return processed, err
	}
	for _, e := range entries {
		name := e.Name()
		if base, ok := strings.CutSuffix(name, ".remove"); ok {
			if err := os.Remove(c.confPath(base)); err == nil {
				if err := c.reload(); err != nil {
					// Best-effort: the conf is already gone; a failed
					// reload here is surfaced via the exit code for the
					// unit log, but there's no requester left waiting on
					// a .status.
					_ = removeAt(c.RequestsDir, name)
					return processed, err
				}
			}
			_ = removeAt(c.RequestsDir, name)
			processed = append(processed, base)
		}
	}
	return processed, nil
}

// applyOne renders and installs one share, re-validating from scratch.
// reqName is the on-disk file name (e.g. "dev1.new"); name is its base
// ("dev1"), already a validated, slash-free token from os.ReadDir.
func (c *Config) applyOne(reqName, name string, shareUID int) error {
	f, err := openRequestFile(c.RequestsDir, reqName, shareUID)
	if err != nil {
		return fmt.Errorf("open request: %w", err)
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		return fmt.Errorf("read request: %w", err)
	}
	var req shareRequest
	if err := json.Unmarshal(b, &req); err != nil {
		return fmt.Errorf("parse request: %w", err)
	}
	// The name embedded in the request must match the filename it came
	// in on (already a validated, slash-free token from ReadDir), so a
	// mismatched/crafted "name" field in the JSON can't target another
	// file.
	if req.Name != name {
		return fmt.Errorf("request name %q doesn't match filename %q", req.Name, name)
	}
	r, err := validateRequest(req)
	if err != nil {
		return err
	}
	if err := VerifyPortForUser(r.Port, c.ShareUser); err != nil {
		return err
	}
	if inUse, err := portInUse(c.ConfDir, r.Port, r.Name); err != nil {
		return err
	} else if inUse {
		return fmt.Errorf("port %d is already shared under another name", r.Port)
	}
	if err := writeFileAtomic(c.ConfDir, r.Name+".conf", []byte(Render(c, r)), 0o644); err != nil {
		return fmt.Errorf("writing %s.conf: %w", r.Name, err)
	}
	if err := c.reload(); err != nil {
		_ = os.Remove(c.confPath(r.Name))
		_ = c.reload() // best-effort: restore a clean, reloadable state
		return err
	}
	return nil
}

// staleRequestAge is how old a .new/.remove/.status file must be before
// Sweep considers it abandoned (Apply normally consumes these within
// seconds; a crash mid-Apply can leave one behind).
var staleRequestAge = 2 * time.Minute

// Sweep removes any ConfDir entry whose port isn't currently a live
// 127.0.0.1 listener (a crash can leave one behind; a timer runs this
// every minute), plus any request or status file left behind by a crashed
// Apply run. It's conservative: it only ever removes files, and reloads
// once if it removed a conf. Request files are deleted via removeAt, same
// as Apply; Lstat (never Stat) is used to judge staleness so a symlink
// `share` left behind is judged by its own age, never the target's.
func (c *Config) Sweep() ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(c.ConfDir, "*.conf"))
	if err != nil {
		return nil, err
	}
	data, err := procNetTCP()
	if err != nil {
		return nil, fmt.Errorf("read /proc/net/tcp: %w", err)
	}
	live := map[int]bool{}
	for _, l := range loopbackListeners(data) {
		live[l.port] = true
	}
	var removed []string
	for _, m := range matches {
		port, ok := portFromFile(m)
		if !ok || !live[port] {
			if err := os.Remove(m); err == nil {
				removed = append(removed, m)
			}
		}
	}
	entries, err := os.ReadDir(c.RequestsDir)
	if err == nil {
		for _, e := range entries {
			name := e.Name()
			if !strings.HasSuffix(name, ".new") && !strings.HasSuffix(name, ".remove") {
				continue
			}
			fi, err := os.Lstat(filepath.Join(c.RequestsDir, name))
			if err != nil || time.Since(fi.ModTime()) < staleRequestAge {
				continue
			}
			if removeAt(c.RequestsDir, name) == nil {
				removed = append(removed, filepath.Join(c.RequestsDir, name))
			}
		}
	}
	stale, _ := filepath.Glob(filepath.Join(c.StatusDir, "*.status"))
	for _, m := range stale {
		fi, err := os.Lstat(m)
		if err != nil || time.Since(fi.ModTime()) < staleRequestAge {
			continue
		}
		if os.Remove(m) == nil {
			removed = append(removed, m)
		}
	}
	if len(removed) > 0 {
		if err := c.reload(); err != nil {
			return removed, err
		}
	}
	return removed, nil
}

var shareProxyPassRe = regexp.MustCompile(`proxy_pass http://127\.0\.0\.1:(\d+);`)

func portFromFile(path string) (int, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	m := shareProxyPassRe.FindSubmatch(b)
	if m == nil {
		return 0, false
	}
	p, err := strconv.Atoi(string(m[1]))
	return p, err == nil
}

// portInUse reports whether another *.conf in dir (besides exceptName)
// already proxies to port, refusing a second share of the same local
// service under a different name.
func portInUse(dir string, port int, exceptName string) (bool, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.conf"))
	if err != nil {
		return false, err
	}
	for _, m := range matches {
		if filepath.Base(m) == exceptName+".conf" {
			continue
		}
		if p, ok := portFromFile(m); ok && p == port {
			return true, nil
		}
	}
	return false, nil
}
