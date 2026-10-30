// Package edgevhost renders and installs runtime public vhosts on the edge
// (o002): temporary ones for `cnt expose --exposure public`
// (containers/ROUTING-PLAN.md §8 step 7, "Public expose design"), and the
// public routes of placed services (containers/PLACEMENT-PLAN.md §5).
//
// h005 (internal/overrides) pushes one JSON Request over a restricted SSH key
// whose forced command is `fleet-vhost-receive` (hosts/edge-vhost-receiver.nix).
// The receiver never accepts nginx text: it validates the request against its
// build-time Config (domain, fleet host -> overlay IP map, names o002 already
// serves) and renders the server block itself, like lib.nix
// edgeVirtualHosts: proxy to http://<overlayIp>:8443, the pushed wildcard,
// a limit_req zone. Every change is `nginx -t`-checked and rolled back on
// failure. Expiry is also local: each file carries its deadline in a header
// line and `fleet-edge vhost-expire` (timer, and at boot before nginx)
// removes expired files, so o002 closes even if h005 is gone.
package edgevhost

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

// EdgePort must match lib.nix edgePort and the host module's nginx.edge.port.
const EdgePort = 8443

// HeaderPrefix starts the first line of every rendered file.
const HeaderPrefix = "# fleet-edge-vhost "

// Kinds of runtime vhost. The kind travels in the file's header, so the edge
// itself records which writer owns each file: the expose authority never
// counts a placement file as its leftover, and the placement reconciler never
// removes an expose override.
const (
	KindExpose    = ""          // cnt expose --exposure public (internal/overrides)
	KindPlacement = "placement" // a public route of a placed service (internal/reconcile)
)

// Request is what h005 sends (one JSON object on stdin).
//
// A remove carries the Kind of the writer that owns the file (KindExpose or
// KindPlacement) and, optionally, the Host it expects; the receiver deletes
// only a file whose header matches (see Handle). A receiver from before
// this fence ignored both on remove; h005 and o002 deploy together, so
// o002's receiver always comes from the same build as its callers.
type Request struct {
	Op               string `json:"op"` // add | remove | list
	Kind             string `json:"kind,omitempty"`
	FQDN             string `json:"fqdn,omitempty"`
	Host             string `json:"host,omitempty"` // add: target; remove: expected owner host ("" = any)
	Until            int64  `json:"until"`          // unix seconds; 0 = no expiry
	MaxBody          string `json:"maxBody,omitempty"`
	Websockets       bool   `json:"websockets,omitempty"`
	Buffering        bool   `json:"buffering,omitempty"`
	RequestBuffering bool   `json:"requestBuffering,omitempty"`
	Timeouts         string `json:"timeouts,omitempty"`
}

// Entry is one installed runtime vhost (from its header line).
type Entry struct {
	FQDN  string `json:"fqdn"`
	Host  string `json:"host"`
	Until int64  `json:"until"`
	Kind  string `json:"kind,omitempty"`
}

// LiveExpose reports whether e is an expose override that has not expired
// (until 0 = no expiry). A live expose wins over a placement of the same
// name for its lifetime: the receiver refuses a placement add over it and
// the reconciler skips the push. An unparseable file (Until -1) is not live.
func (e Entry) LiveExpose(now time.Time) bool {
	return e.Kind == KindExpose && (e.Until == 0 || now.Unix() < e.Until)
}

// Config is the receiver's build-time configuration (JSON file on o002).
type Config struct {
	Domain   string            `json:"domain"`
	Dir      string            `json:"dir"`     // runtime include dir
	CertDir  string            `json:"certDir"` // holds fullchain.pem, key.pem
	Hosts    map[string]string `json:"hosts"`   // fleet host -> overlay IPv4
	Reserved []string          `json:"reserved"`
	// NginxTest and NginxReload are shell commands (exit 0 = ok).
	NginxTest   string `json:"nginxTest"`
	NginxReload string `json:"nginxReload"`
	LimitZone   string `json:"limitZone"` // limit_req zone name defined in http{}
}

var (
	labelRe   = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	maxBodyRe = regexp.MustCompile(`^[0-9]{1,6}[kKmMgG]?$`)
	timeRe    = regexp.MustCompile(`^[0-9]{1,6}(ms|s|m|h)?$`)
	ipv4Re    = regexp.MustCompile(`^[0-9]{1,3}(\.[0-9]{1,3}){3}$`)
)

// Validate checks an add/remove request against the config.
func (c *Config) Validate(r *Request) error {
	switch r.Op {
	case "list":
		return nil
	case "add", "remove":
	default:
		return fmt.Errorf("op %q: want add, remove or list", r.Op)
	}
	fq := strings.ToLower(r.FQDN)
	if fq != r.FQDN {
		return errors.New("fqdn must be lower case")
	}
	label, ok := strings.CutSuffix(fq, "."+c.Domain)
	if !ok || !labelRe.MatchString(label) {
		return fmt.Errorf("fqdn %q: want a single label under %s", r.FQDN, c.Domain)
	}
	for _, n := range c.Reserved {
		if strings.EqualFold(n, fq) {
			return fmt.Errorf("%s is already served by this edge's own config", fq)
		}
	}
	if err := validKind(r.Kind); err != nil {
		return err
	}
	if r.Op == "remove" {
		return nil
	}
	if r.Kind == KindPlacement && r.Until != 0 {
		return errors.New("a placement vhost has no expiry (until must be 0)")
	}
	ip, ok := c.Hosts[r.Host]
	if !ok || !ipv4Re.MatchString(ip) {
		return fmt.Errorf("host %q is not a fleet host with an overlay IP", r.Host)
	}
	if r.Until < 0 {
		return errors.New("until must be >= 0 (0 = no expiry)")
	}
	if !maxBodyRe.MatchString(r.MaxBody) {
		return fmt.Errorf("maxBody %q not allowed", r.MaxBody)
	}
	if !timeRe.MatchString(r.Timeouts) {
		return fmt.Errorf("timeouts %q not allowed", r.Timeouts)
	}
	return nil
}

func validKind(k string) error {
	switch k {
	case KindExpose, KindPlacement:
		return nil
	}
	return fmt.Errorf("kind %q: want %q or %q", k, KindExpose, KindPlacement)
}

// KindName is how output names a kind ("" reads as "expose").
func KindName(k string) string {
	if k == KindExpose {
		return "expose"
	}
	return k
}

// KeptPrefix starts the line a fenced remove writes when the file belongs
// to another owner and was left in place (not an error).
const KeptPrefix = "kept: owned by "

func onOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

// Render returns the nginx file for a validated add request.
func (c *Config) Render(r *Request) string {
	hdr, _ := json.Marshal(Entry{FQDN: r.FQDN, Host: r.Host, Until: r.Until, Kind: r.Kind})
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s\n", HeaderPrefix, hdr)
	if r.Kind == KindPlacement {
		b.WriteString("# runtime vhost from fleet-edge placements (public route of a placed service); do not edit\n")
	} else {
		b.WriteString("# runtime vhost from fleet-edge overrides (cnt expose --exposure public); do not edit\n")
	}
	fmt.Fprintf(&b, "server {\n  listen 80;\n  listen [::]:80;\n  server_name %s;\n  location / { return 301 https://$host$request_uri; }\n}\n", r.FQDN)
	fmt.Fprintf(&b, "server {\n  listen 443 ssl;\n  listen [::]:443 ssl;\n  server_name %s;\n", r.FQDN)
	fmt.Fprintf(&b, "  ssl_certificate %s/fullchain.pem;\n  ssl_certificate_key %s/key.pem;\n", c.CertDir, c.CertDir)
	// A placement vhost is the block lib.nix edgeVirtualHosts used to emit at
	// eval time, which had no rate limit; only the temporary expose path does.
	if c.LimitZone != "" && r.Kind != KindPlacement {
		fmt.Fprintf(&b, "  limit_req zone=%s burst=100 nodelay;\n", c.LimitZone)
	}
	b.WriteString("  location / {\n")
	fmt.Fprintf(&b, "    proxy_pass http://%s:%d;\n", c.Hosts[r.Host], EdgePort)
	b.WriteString("    proxy_http_version 1.1;\n")
	// Any proxy_set_header here drops the http-level ones, so set them all.
	b.WriteString("    proxy_set_header Host $host;\n")
	b.WriteString("    proxy_set_header X-Real-IP $remote_addr;\n")
	b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Proto $scheme;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Host $host;\n")
	if r.Websockets {
		b.WriteString("    proxy_set_header Upgrade $http_upgrade;\n    proxy_set_header Connection $connection_upgrade;\n")
	} else {
		b.WriteString("    proxy_set_header Connection \"\";\n")
	}
	fmt.Fprintf(&b, "    client_max_body_size %s;\n", r.MaxBody)
	fmt.Fprintf(&b, "    proxy_buffering %s;\n", onOff(r.Buffering))
	fmt.Fprintf(&b, "    proxy_request_buffering %s;\n", onOff(r.RequestBuffering))
	fmt.Fprintf(&b, "    proxy_read_timeout %s;\n    proxy_send_timeout %s;\n", r.Timeouts, r.Timeouts)
	b.WriteString("  }\n}\n")
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
	if json.Unmarshal(rest, &e) != nil || e.FQDN == "" {
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

func (c *Config) path(fqdn string) string { return filepath.Join(c.Dir, fqdn+".conf") }

// PendingMarker is written (atomically) before any change to Dir and
// removed only after nginx -t and the reload both succeeded. While it
// exists, nginx may still serve a site whose file is already gone, so
// every operation retries the reload first and reports failure.
const PendingMarker = ".reload-pending"

// ErrReloadPending prefixes errors while the marker stays set (h005 and
// cnt expose --list show it as "reload pending").
const ErrReloadPending = "reload pending"

func (c *Config) marker() string { return filepath.Join(c.Dir, PendingMarker) }

// LockFile in Dir serializes every receiver and expire invocation (each
// SSH push and each timer run is its own process), so a remove's ownership
// check and its delete see the same file. Not *.conf: nginx never reads it.
const LockFile = ".lock"

// lock takes an exclusive flock on Dir's lock file; call the result to
// release it.
func (c *Config) lock() (func(), error) {
	f, err := os.OpenFile(filepath.Join(c.Dir, LockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, fmt.Errorf("lock: %w", err)
	}
	return func() { f.Close() }, nil // closing drops the flock
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

// swap replaces (content != nil) or removes the file for fqdn, runs nginx -t,
// and reloads. On a failed test the previous file is restored. The marker
// is set before the file changes, so a failed reload (or a crash) is retried
// by the next call, including "already gone" and identical no-ops.
func (c *Config) swap(fqdn string, content []byte) error {
	p := c.path(fqdn)
	old, oldErr := os.ReadFile(p)
	if content != nil && oldErr == nil && bytes.Equal(old, content) {
		return c.flush() // identical: only an owed reload
	}
	if content == nil && oldErr != nil {
		return c.flush() // already gone: nginx may still serve it
	}
	wasPending := c.Pending()
	if err := c.setPending(); err != nil {
		return err
	}
	if content != nil {
		tmp := p + ".new"
		if err := os.WriteFile(tmp, content, 0o644); err != nil {
			return err
		}
		if err := os.Rename(tmp, p); err != nil {
			return err
		}
	} else if err := os.Remove(p); err != nil {
		return err
	}
	if err := Runner(c.NginxTest); err != nil {
		if oldErr == nil {
			_ = os.WriteFile(p, old, 0o644)
		} else {
			_ = os.Remove(p)
		}
		if !wasPending {
			_ = os.Remove(c.marker()) // dir is back to what nginx serves
		}
		return fmt.Errorf("nginx -t failed, %s restored: %v", fqdn, err)
	}
	if err := Runner(c.NginxReload); err != nil {
		return fmt.Errorf("%s: nginx reload: %v", ErrReloadPending, err)
	}
	if err := os.Remove(c.marker()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%s: clearing marker: %v", ErrReloadPending, err)
	}
	return nil
}

// List returns installed entries, sorted by fqdn.
func (c *Config) List() ([]Entry, error) {
	m, err := filepath.Glob(filepath.Join(c.Dir, "*.conf"))
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	for _, p := range m {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		e, ok := ParseHeader(b)
		if !ok {
			// Unknown file in our dir: report it so audit sees it.
			e = Entry{FQDN: strings.TrimSuffix(filepath.Base(p), ".conf"), Host: "?", Until: -1}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].FQDN < out[j].FQDN })
	return out, nil
}

// Handle executes one request under the dir lock; list output goes to w as
// JSON. Both writes are fenced by owner, checked against the current file
// while the lock is held:
//   - a placement add over a live expose file (Entry.LiveExpose) is kept;
//   - a remove deletes only a file owned by r.Kind (and r.Host, if set).
//
// A kept request writes KeptPrefix+kind to w and returns nil (only an owed
// reload is retried). A file without a parseable header has no owner and
// may be replaced or removed (fail closed, like Expire).
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
		return json.NewEncoder(w).Encode(l)
	case "add":
		now := time.Now()
		if r.Until != 0 && r.Until <= now.Unix() {
			return errors.New("until is in the past")
		}
		if e, ok := c.current(r.FQDN); ok && r.Kind == KindPlacement && e.LiveExpose(now) {
			return c.kept(w, e)
		}
		return c.swap(r.FQDN, []byte(c.Render(r)))
	default:
		if e, ok := c.current(r.FQDN); ok && (e.Kind != r.Kind || (r.Host != "" && e.Host != r.Host)) {
			return c.kept(w, e)
		}
		return c.swap(r.FQDN, nil)
	}
}

// current is the header of fqdn's file, if it exists and parses.
func (c *Config) current(fqdn string) (Entry, bool) {
	b, err := os.ReadFile(c.path(fqdn))
	if err != nil {
		return Entry{}, false
	}
	return ParseHeader(b)
}

// kept reports a fenced no-op on w and retries an owed reload.
func (c *Config) kept(w io.Writer, e Entry) error {
	if w != nil {
		fmt.Fprintf(w, "%s%s on %s\n", KeptPrefix, KindName(e.Kind), e.Host)
	}
	return c.flush()
}

// Expire removes files whose until has passed (and unparseable ones: fail
// closed), then tests and reloads once. The marker is set before any
// removal, and the reload also runs when only the marker is left (a
// previous run removed the files but its reload failed). With
// reload=false (boot, before nginx) the marker is left for the next run.
func (c *Config) Expire(now time.Time, reload bool) ([]string, error) {
	unlock, err := c.lock()
	if err != nil {
		return nil, err
	}
	defer unlock()
	m, err := filepath.Glob(filepath.Join(c.Dir, "*.conf"))
	if err != nil {
		return nil, err
	}
	var doomed []string
	for _, p := range m {
		b, err := os.ReadFile(p)
		e, ok := ParseHeader(b)
		if err == nil && ok && (e.Until == 0 || now.Unix() < e.Until) {
			continue
		}
		doomed = append(doomed, p)
	}
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
	if tmps, _ := filepath.Glob(filepath.Join(c.Dir, "*.conf.new")); len(tmps) > 0 {
		for _, t := range tmps {
			_ = os.Remove(t)
		}
	}
	if !reload {
		return gone, nil
	}
	return gone, c.flush()
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
	if c.Domain == "" || c.Dir == "" || c.CertDir == "" || c.NginxTest == "" || c.NginxReload == "" {
		return nil, fmt.Errorf("%s: domain, dir, certDir, nginxTest and nginxReload are required", path)
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
		fmt.Fprintf(stdout, "ok %s %s\n", r.Op, r.FQDN)
	}
	return nil
}
