// Package edgestream renders and installs the edge's (o002's) runtime nginx
// `stream` servers: one per public `via = edge` tcp route of a placed
// service (containers/PLACEMENT-PLAN.md §5, phase 4a), e.g. forgejo's SSH on
// :3032.
//
// h005's placement reconciler (internal/reconcile) pushes one JSON Request
// over the same restricted SSH key as internal/edgevhost; o002's forced
// command dispatches remote command `fleet-stream-receive` here
// (hosts/_shared_assets/utilities/edge-stream-receiver.nix). The receiver
// never accepts nginx text: it checks the port against its build-time list
// and the host against its fleet host -> overlay IP map, and renders
// `server { listen <port>; proxy_pass <overlayIp>:<port>; }` itself. Every
// change is `nginx -t`-checked and rolled back on failure.
//
// A closed port is the only fail-closed rendering (the stream module has no
// `return`, and a server without proxy_pass fails nginx -t), so removal and
// expiry delete the file. There is no TTL: `fleet-edge stream-expire` (timer,
// and at boot before nginx) drops only files it cannot vouch for
// (unparseable, or a port/host no longer in the config).
package edgestream

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// HeaderPrefix starts the first line of every rendered file.
const HeaderPrefix = "# fleet-edge-stream "

// KindPlacement is the only writer of stream files today (internal/reconcile).
// The kind travels in the header like edgevhost's, so a remove is fenced to
// the owner it names.
const KindPlacement = "placement"

// KeptPrefix starts the line a fenced remove writes when the file belongs to
// another owner and was left in place (not an error).
const KeptPrefix = "kept: owned by "

// PendingMarker, ErrReloadPending and LockFile mirror edgevhost's, in this
// receiver's own directory: one nginx reload serves http and stream, but each
// receiver tracks its own debt.
const (
	PendingMarker    = ".reload-pending"
	ErrReloadPending = "reload pending"
	LockFile         = ".lock"
)

// Request is what h005 sends (one JSON object on stdin).
type Request struct {
	Op   string `json:"op"` // add | remove | list
	Kind string `json:"kind,omitempty"`
	Port int    `json:"port,omitempty"`
	Host string `json:"host,omitempty"` // add: target; remove: expected owner host ("" = any)
}

// Entry is one installed stream (from its header line). An unparseable file
// lists with Host "?" and no Kind.
type Entry struct {
	Port int    `json:"port"`
	Host string `json:"host"`
	Kind string `json:"kind,omitempty"`
}

// List is the reply to a list request. An object, never a bare array, so an
// edge whose forced command still runs the vhost receiver (which answers a
// list with an array) is an error to the caller, not an empty list.
type List struct {
	Streams []Entry `json:"streams"`
}

// Config is the receiver's build-time configuration (JSON file on o002).
type Config struct {
	Dir   string            `json:"dir"`   // runtime include dir
	Hosts map[string]string `json:"hosts"` // fleet host -> overlay IPv4
	Ports []int             `json:"ports"` // the only ports a push may open
	// NginxTest and NginxReload are shell commands (exit 0 = ok).
	NginxTest   string `json:"nginxTest"`
	NginxReload string `json:"nginxReload"`
}

func validIP(s string) bool {
	ip, err := netip.ParseAddr(s)
	return err == nil && ip.Is4()
}

func (c *Config) allowed(port int) bool { return slices.Contains(c.Ports, port) }

// Validate checks a request against the config.
func (c *Config) Validate(r *Request) error {
	switch r.Op {
	case "list":
		return nil
	case "add", "remove":
	default:
		return fmt.Errorf("op %q: want add, remove or list", r.Op)
	}
	if !c.allowed(r.Port) {
		return fmt.Errorf("port %d is not a public edge stream port of this edge", r.Port)
	}
	if r.Kind != KindPlacement {
		return fmt.Errorf("kind %q: want %q", r.Kind, KindPlacement)
	}
	if r.Op == "remove" {
		return nil
	}
	if ip, ok := c.Hosts[r.Host]; !ok || !validIP(ip) {
		return fmt.Errorf("host %q is not a fleet host with an overlay IP", r.Host)
	}
	return nil
}

// Render returns the nginx file for a validated add request.
func (c *Config) Render(r *Request) string {
	return render(Entry{Port: r.Port, Host: r.Host, Kind: r.Kind}, c.Hosts[r.Host])
}

func render(e Entry, ip string) string {
	hdr, _ := json.Marshal(e)
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s\n", HeaderPrefix, hdr)
	b.WriteString("# runtime stream from fleet-edge placements (public tcp route of a placed service); do not edit\n")
	fmt.Fprintf(&b, "server {\n  listen %d;\n  proxy_pass %s:%d;\n}\n", e.Port, ip, e.Port)
	return b.String()
}

// ParseHeader reads the Entry from a rendered file's first line.
func ParseHeader(content []byte) (Entry, bool) {
	line, _, _ := bytes.Cut(content, []byte("\n"))
	rest, ok := bytes.CutPrefix(line, []byte(HeaderPrefix))
	if !ok {
		return Entry{}, false
	}
	var e Entry
	if json.Unmarshal(rest, &e) != nil || e.Port < 1 || e.Port > 65535 || e.Host == "" {
		return Entry{}, false
	}
	return e, true
}

// Runner runs a shell command (var for tests).
var Runner = func(cmd string) error {
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Stdout, c.Stderr = os.Stderr, os.Stderr
	return c.Run()
}

func (c *Config) path(port int) string { return filepath.Join(c.Dir, strconv.Itoa(port)+".stream") }
func (c *Config) marker() string       { return filepath.Join(c.Dir, PendingMarker) }

// lock takes an exclusive flock on Dir's lock file (every receiver, expire
// and seed invocation is its own process); call the result to release it.
func (c *Config) lock() (func(), error) {
	f, err := os.OpenFile(filepath.Join(c.Dir, LockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, fmt.Errorf("lock: %w", err)
	}
	return func() { f.Close() }, nil
}

// Pending reports whether a reload is still owed.
func (c *Config) Pending() bool {
	_, err := os.Stat(c.marker())
	return err == nil
}

func (c *Config) setPending() error {
	tmp := c.marker() + ".new"
	if err := os.WriteFile(tmp, []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", PendingMarker, err)
	}
	if err := os.Rename(tmp, c.marker()); err != nil {
		return fmt.Errorf("writing %s: %w", PendingMarker, err)
	}
	return nil
}

// reload runs nginx -t and the reload; the marker is cleared only if both
// succeed.
func (c *Config) reload() error {
	if err := Runner(c.NginxTest); err != nil {
		return fmt.Errorf("%s: nginx -t: %v", ErrReloadPending, err)
	}
	if err := Runner(c.NginxReload); err != nil {
		return fmt.Errorf("%s: nginx reload: %v", ErrReloadPending, err)
	}
	if err := os.Remove(c.marker()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%s: clearing marker: %v", ErrReloadPending, err)
	}
	return nil
}

// flush retries an owed reload (no-op without the marker).
func (c *Config) flush() error {
	if !c.Pending() {
		return nil
	}
	return c.reload()
}

func writeAtomic(p string, content []byte) error {
	tmp := p + ".new"
	if err := os.WriteFile(tmp, content, 0o644); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// swap replaces (content != nil) or removes the file for port, runs nginx -t
// and reloads; a failed test restores the previous file. The marker is set
// before the file changes, so a failed reload (or a crash) is retried by the
// next call.
func (c *Config) swap(port int, content []byte) error {
	p := c.path(port)
	old, oldErr := os.ReadFile(p)
	if content != nil && oldErr == nil && bytes.Equal(old, content) {
		return c.flush()
	}
	if content == nil && oldErr != nil {
		return c.flush()
	}
	wasPending := c.Pending()
	if err := c.setPending(); err != nil {
		return err
	}
	if content != nil {
		if err := writeAtomic(p, content); err != nil {
			return err
		}
	} else if err := os.Remove(p); err != nil {
		return err
	}
	if err := Runner(c.NginxTest); err != nil {
		if oldErr == nil {
			_ = writeAtomic(p, old)
		} else {
			_ = os.Remove(p)
		}
		if !wasPending {
			_ = os.Remove(c.marker())
		}
		return fmt.Errorf("nginx -t failed, :%d restored: %v", port, err)
	}
	if err := Runner(c.NginxReload); err != nil {
		return fmt.Errorf("%s: nginx reload: %v", ErrReloadPending, err)
	}
	if err := os.Remove(c.marker()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%s: clearing marker: %v", ErrReloadPending, err)
	}
	return nil
}

// files maps every *.stream file in Dir to its content (nil if unreadable).
func (c *Config) files() (map[string][]byte, error) {
	m, err := filepath.Glob(filepath.Join(c.Dir, "*.stream"))
	if err != nil {
		return nil, err
	}
	out := make(map[string][]byte, len(m))
	for _, p := range m {
		b, _ := os.ReadFile(p)
		out[p] = b
	}
	return out, nil
}

// List returns installed entries, sorted by port.
func (c *Config) List() ([]Entry, error) {
	fs, err := c.files()
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	for p, b := range fs {
		e, ok := ParseHeader(b)
		if !ok {
			n, _ := strconv.Atoi(strings.TrimSuffix(filepath.Base(p), ".stream"))
			e = Entry{Port: n, Host: "?"}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out, nil
}

func (c *Config) current(port int) (Entry, bool) {
	b, err := os.ReadFile(c.path(port))
	if err != nil {
		return Entry{}, false
	}
	return ParseHeader(b)
}

// Handle executes one request under the dir lock; list output goes to w as
// JSON. A remove deletes only a file owned by r.Kind (and r.Host, if set);
// otherwise it writes KeptPrefix to w and returns nil. A file without a
// parseable header has no owner and may be replaced or removed.
func (c *Config) Handle(r *Request, w io.Writer) error {
	if err := c.Validate(r); err != nil {
		return err
	}
	unlock, err := c.lock()
	if err != nil {
		return err
	}
	defer unlock()
	switch r.Op {
	case "list":
		if err := c.flush(); err != nil {
			return err
		}
		l, err := c.List()
		if err != nil {
			return err
		}
		return json.NewEncoder(w).Encode(List{Streams: l})
	case "add":
		return c.swap(r.Port, []byte(c.Render(r)))
	default:
		if e, ok := c.current(r.Port); ok && (e.Kind != r.Kind || (r.Host != "" && e.Host != r.Host)) {
			if w != nil {
				fmt.Fprintf(w, "%s%s on %s\n", KeptPrefix, e.Kind, e.Host)
			}
			return c.flush()
		}
		return c.swap(r.Port, nil)
	}
}

// Expire removes the files this config cannot vouch for (unparseable, a port
// no longer allowed, a host no longer known, a header that disagrees with the
// file name) and crash-left temp files, then tests and reloads once. With
// reload=false (boot, before nginx) the marker is left for the next run.
func (c *Config) Expire(reload bool) ([]string, error) {
	unlock, err := c.lock()
	if err != nil {
		return nil, err
	}
	defer unlock()
	fs, err := c.files()
	if err != nil {
		return nil, err
	}
	var doomed []string
	for p, b := range fs {
		e, ok := ParseHeader(b)
		if ok && c.allowed(e.Port) && c.path(e.Port) == p && validIP(c.Hosts[e.Host]) {
			continue
		}
		doomed = append(doomed, p)
	}
	sort.Strings(doomed)
	if len(doomed) > 0 {
		if err := c.setPending(); err != nil {
			return nil, err
		}
	}
	var gone []string
	for _, p := range doomed {
		if os.Remove(p) == nil {
			gone = append(gone, filepath.Base(p))
		}
	}
	if tmps, _ := filepath.Glob(filepath.Join(c.Dir, "*.stream.new")); len(tmps) > 0 {
		for _, t := range tmps {
			_ = os.Remove(t)
		}
	}
	if !reload {
		return gone, nil
	}
	return gone, c.flush()
}

// staticStreamRe matches a hand-written stream server that does nothing but
// forward one port to the same port on an IPv4 address, i.e. the block
// o002's nginx.nix carried before phase 4a.
var staticStreamRe = regexp.MustCompile(`server\s*\{\s*listen\s+([0-9]{1,5});\s*proxy_pass\s+([0-9.]+):([0-9]{1,5});\s*\}`)

// Seed installs the Nix-provided snapshot of the pre-cutover static stream
// when no stream files exist, at boot and activation. The reconciler owns
// subsequent changes. No nginx command runs before its service starts.
func (c *Config) Seed(nginxConf []byte) ([]Entry, error) {
	if err := os.MkdirAll(c.Dir, 0o755); err != nil {
		return nil, err
	}
	unlock, err := c.lock()
	if err != nil {
		return nil, err
	}
	defer unlock()
	fs, err := c.files()
	if err != nil {
		return nil, err
	}
	if len(fs) > 0 {
		return nil, nil
	}
	byIP := map[string][]string{}
	for h, ip := range c.Hosts {
		byIP[ip] = append(byIP[ip], h)
	}
	var out []Entry
	for _, m := range staticStreamRe.FindAllSubmatch(nginxConf, -1) {
		port, _ := strconv.Atoi(string(m[1]))
		to, _ := strconv.Atoi(string(m[3]))
		hosts := byIP[string(m[2])]
		if port != to || !c.allowed(port) || len(hosts) != 1 {
			continue
		}
		out = append(out, Entry{Port: port, Host: hosts[0], Kind: KindPlacement})
	}
	if len(out) == 0 {
		return nil, nil
	}
	if err := c.setPending(); err != nil {
		return nil, err
	}
	for _, e := range out {
		if err := writeAtomic(c.path(e.Port), []byte(render(e, c.Hosts[e.Host]))); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// LoadConfig reads the receiver config.
func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Dir == "" || c.NginxTest == "" || c.NginxReload == "" {
		return nil, fmt.Errorf("%s: dir, nginxTest and nginxReload are required", path)
	}
	for _, p := range c.Ports {
		if p < 1 || p > 65535 {
			return nil, fmt.Errorf("%s: port %d out of range", path, p)
		}
	}
	return &c, nil
}

// Receive is the forced-command entry point: one JSON request on stdin.
func Receive(configPath string, stdin io.Reader, stdout io.Writer) error {
	c, err := LoadConfig(configPath)
	if err != nil {
		return err
	}
	var r Request
	dec := json.NewDecoder(io.LimitReader(stdin, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return fmt.Errorf("bad request: %v", err)
	}
	if err := c.Handle(&r, stdout); err != nil {
		return err
	}
	if r.Op != "list" {
		fmt.Fprintf(stdout, "ok %s %d\n", r.Op, r.Port)
	}
	return nil
}

// ErrNotStreamReceiver is returned by ParseList for a reply that is not a
// stream list (e.g. an edge still running only the vhost receiver).
var ErrNotStreamReceiver = errors.New("reply is not a stream list (is fleet-stream-receive deployed on the edge?)")

// ParseList decodes a list reply, strictly.
func ParseList(b []byte) ([]Entry, error) {
	var l List
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&l); err != nil || l.Streams == nil {
		return nil, ErrNotStreamReceiver
	}
	return l.Streams, nil
}
