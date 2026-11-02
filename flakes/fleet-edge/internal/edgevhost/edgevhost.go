// Package edgevhost renders and installs runtime public vhosts on the edge
// (o002): temporary ones for `cnt expose --exposure public`, and the public
// routes of placed services.
//
// h005 (internal/overrides) pushes one JSON Request over a restricted SSH key
// whose forced command is `fleet-vhost-receive`
// (hosts/_shared_assets/utilities/edge-vhost-receiver.nix).
// The receiver never accepts nginx text: it validates the request against its
// build-time Config (domain, fleet host -> overlay IP map, names o002 already
// serves) and renders the server block itself: proxy to the bound host's
// http://<overlayIp>:8443 listener, the pushed wildcard, a limit_req zone,
// and a strictly limited, separately logged location for the route's
// loginPaths (fail2ban on o002 reads that log). Every change is
// `nginx -t`-checked and rolled back on
// failure. Expiry is also local: each file carries its deadline in a header
// line and `fleet-edge vhost-expire` (timer, and at boot before nginx)
// removes expired files, so o002 closes even if h005 is gone.
package edgevhost

import (
	"bytes"
	"crypto/rand"
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

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/nginxgen"
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
// only a file whose header matches (see Handle). h005 and o002 deploy
// together, so the receiver always comes from the same build as its callers.
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
	// LoginPaths are the route's exact login endpoints (lib.nix loginPaths):
	// one extra location with the strict login zone and the login log.
	LoginPaths []string `json:"loginPaths,omitempty"`
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
	// NginxMainPID is a shell command printing the nginx master's pid; settle
	// watches its workers to confirm a reload loaded the new config.
	NginxMainPID string `json:"nginxMainPid"`
	LimitZone    string `json:"limitZone"` // limit_req zone name defined in http{}
	// Login locations (Request.LoginPaths; lib.nix edgeLogin): the strict
	// limit_req zone and the extra access log (path, log_format name)
	// fail2ban reads. AccessLog is the main access log, re-stated because
	// a location's access_log replaces the inherited ones ("" = none).
	LoginZone      string `json:"loginZone"`
	LoginLog       string `json:"loginLog"`
	LoginLogFormat string `json:"loginLogFormat"`
	AccessLog      string `json:"accessLog"`
}

var (
	labelRe   = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	maxBodyRe = regexp.MustCompile(`^[0-9]{1,6}[kKmMgG]?$`)
	timeRe    = regexp.MustCompile(`^[0-9]{1,6}(ms|s|m|h)?$`)
	ipv4Re    = regexp.MustCompile(`^[0-9]{1,3}(\.[0-9]{1,3}){3}$`)
	// Same rule as lib.nix loginPaths: a path, not "/", <= 128 chars.
	loginPathRe = regexp.MustCompile(`^/[A-Za-z0-9_.-][A-Za-z0-9_./-]{0,126}$`)
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
	if len(r.LoginPaths) > 0 && c.LoginZone == "" {
		return errors.New("loginPaths given but this edge has no login zone")
	}
	if len(r.LoginPaths) > MaxLoginPaths {
		return fmt.Errorf("at most %d loginPaths", MaxLoginPaths)
	}
	for _, p := range r.LoginPaths {
		if !loginPathRe.MatchString(p) {
			return fmt.Errorf("loginPath %q not allowed", p)
		}
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

// MaxLoginPaths matches lib.nix's loginPaths limit.
const MaxLoginPaths = 16

// LoginBurst is the strict login zone's burst (the rate is lib.nix
// edgeLogin.rate, in the zone's http{} definition).
const LoginBurst = 5

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
	// Permanent placement vhosts have no server-wide rate limit; only
	// temporary exposes do. Login locations of both kinds get it below.
	if c.LimitZone != "" && r.Kind != KindPlacement {
		fmt.Fprintf(&b, "  limit_req zone=%s burst=100 nodelay;\n", c.LimitZone)
	}
	if len(r.LoginPaths) > 0 {
		// Exact paths, any case (ASP.NET routes ignore it), optional
		// trailing slash. A regex location wins over the `/` prefix.
		alts := make([]string, len(r.LoginPaths))
		for i, p := range r.LoginPaths {
			alts[i] = strings.ReplaceAll(p, ".", `\.`)
		}
		fmt.Fprintf(&b, "  location ~* ^(?:%s)/?$ {\n", strings.Join(alts, "|"))
		// A location's limit_req and access_log replace the inherited
		// ones, so the global zone and main log are stated again.
		if c.LimitZone != "" {
			fmt.Fprintf(&b, "    limit_req zone=%s burst=100 nodelay;\n", c.LimitZone)
		}
		fmt.Fprintf(&b, "    limit_req zone=%s burst=%d nodelay;\n", c.LoginZone, LoginBurst)
		b.WriteString("    limit_req_status 429;\n")
		if c.AccessLog != "" {
			fmt.Fprintf(&b, "    access_log %s;\n", c.AccessLog)
		}
		if c.LoginLog != "" {
			fmt.Fprintf(&b, "    access_log %s %s;\n", c.LoginLog, c.LoginLogFormat)
		}
		c.writeProxy(&b, r)
		b.WriteString("  }\n")
	}
	b.WriteString("  location / {\n")
	c.writeProxy(&b, r)
	b.WriteString("  }\n}\n")
	return b.String()
}

// writeProxy writes the proxy directives every location of r shares.
func (c *Config) writeProxy(b *strings.Builder, r *Request) {
	fmt.Fprintf(b, "    proxy_pass http://%s:%d;\n", c.Hosts[r.Host], EdgePort)
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
	fmt.Fprintf(b, "    client_max_body_size %s;\n", r.MaxBody)
	fmt.Fprintf(b, "    proxy_buffering %s;\n", onOff(r.Buffering))
	fmt.Fprintf(b, "    proxy_request_buffering %s;\n", onOff(r.RequestBuffering))
	fmt.Fprintf(b, "    proxy_read_timeout %s;\n    proxy_send_timeout %s;\n", r.Timeouts, r.Timeouts)
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

// Probe snapshots nginx before a reload and returns a check reporting
// whether nginx has since loaded a config read after the snapshot (var for
// tests; see internal/nginxgen).
var Probe = func(c *Config) (func() (bool, error), error) {
	w, err := nginxgen.Watch(c.NginxMainPID)
	if err != nil {
		return nil, err
	}
	return w.Applied, nil
}

// ConfirmTimeout bounds settle's wait for Probe (var for tests). A failing
// bind alone holds the nginx master ~2.5s (five 500ms retries).
var ConfirmTimeout = 15 * time.Second

func (c *Config) path(fqdn string) string { return filepath.Join(c.Dir, fqdn+".conf") }

// PendingMarker is written (atomically) before any change to Dir and
// removed only after nginx -t and the reload both succeeded, and only if no
// later change re-armed it meanwhile (see settle). While it exists, nginx may
// still serve a site whose file is already gone, so every operation retries
// the reload first and reports failure.
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

// setPending arms the marker with a fresh token (time, pid, nonce) and
// returns it. settle clears the marker only while it still holds the token
// it reloaded for, so a change made during that reload keeps its own debt.
func (c *Config) setPending() (string, error) {
	var nonce [8]byte
	_, _ = rand.Read(nonce[:])
	tok := fmt.Sprintf("%s %d %x\n", time.Now().UTC().Format(time.RFC3339Nano), os.Getpid(), nonce)
	tmp := c.marker() + ".new"
	if err := os.WriteFile(tmp, []byte(tok), 0o644); err != nil {
		return "", fmt.Errorf("writing %s: %w", PendingMarker, err)
	}
	if err := os.Rename(tmp, c.marker()); err != nil {
		return "", fmt.Errorf("writing %s: %w", PendingMarker, err)
	}
	return tok, nil
}

// underLock runs fn holding the dir lock; fn returns the marker token settle
// must reload for ("" if nothing is owed).
func (c *Config) underLock(fn func() (string, error)) (string, error) {
	unlock, err := c.lock()
	if err != nil {
		return "", err
	}
	defer unlock()
	return fn()
}

// owed (under the lock) runs nginx -t if a reload is owed and returns the
// marker's token ("" if none).
func (c *Config) owed() (string, error) {
	b, err := os.ReadFile(c.marker())
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("%s: reading marker: %v", ErrReloadPending, err)
	}
	if err := Runner(c.NginxTest); err != nil {
		return "", fmt.Errorf("%s: nginx -t: %v", ErrReloadPending, err)
	}
	return string(b), nil
}

// settle runs the reload owed for tok ("" = none) WITHOUT the dir lock: the
// blocking `systemctl reload nginx` waits behind a queued nginx start, which
// is ordered after fleet-vhost-expire-boot, which takes this lock. The
// reload's exit status only says nginx -t passed and the master got SIGHUP;
// the master can still fail to load the config (e.g. bind() of a listen
// address that is taken) and keep the old one. So settle waits until Probe
// confirms nginx serves a config loaded after the reload (or ConfirmTimeout
// passes: the marker stays and the error is a pending one). Only then does
// it re-take the lock and remove the marker, and only if the marker still
// holds tok: a change made meanwhile re-armed it, and that debt stays until
// its own reload is confirmed.
func (c *Config) settle(tok string) error {
	if tok == "" {
		return nil
	}
	applied, perr := Probe(c)
	if err := Runner(c.NginxReload); err != nil {
		return fmt.Errorf("%s: nginx reload: %v", ErrReloadPending, err)
	}
	if perr != nil {
		return fmt.Errorf("%s: watching nginx: %v", ErrReloadPending, perr)
	}
	if err := nginxgen.Await(applied, ConfirmTimeout); err != nil {
		return fmt.Errorf("%s: %v", ErrReloadPending, err)
	}
	_, err := c.underLock(func() (string, error) {
		b, err := os.ReadFile(c.marker())
		if os.IsNotExist(err) || (err == nil && string(b) != tok) {
			return "", nil
		}
		if err == nil {
			err = os.Remove(c.marker())
		}
		if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("%s: clearing marker: %v", ErrReloadPending, err)
		}
		return "", nil
	})
	return err
}

// flush retries an owed reload (no-op without the marker). Call it without
// the lock held.
func (c *Config) flush() error {
	tok, err := c.underLock(c.owed)
	if err != nil {
		return err
	}
	return c.settle(tok)
}

// swap (under the lock) replaces (content != nil) or removes the file for
// fqdn and runs nginx -t; on a failed test the previous file is restored. It
// returns the token for settle. The marker is set before the file changes,
// so a failed reload (or a crash) is retried by the next call, including
// "already gone" and identical no-ops.
func (c *Config) swap(fqdn string, content []byte) (string, error) {
	p := c.path(fqdn)
	old, oldErr := os.ReadFile(p)
	if content != nil && oldErr == nil && bytes.Equal(old, content) {
		return c.owed() // identical: only an owed reload
	}
	if content == nil && oldErr != nil {
		return c.owed() // already gone: nginx may still serve it
	}
	wasPending := c.Pending()
	tok, err := c.setPending()
	if err != nil {
		return "", err
	}
	if content != nil {
		tmp := p + ".new"
		if err := os.WriteFile(tmp, content, 0o644); err != nil {
			return "", err
		}
		if err := os.Rename(tmp, p); err != nil {
			return "", err
		}
	} else if err := os.Remove(p); err != nil {
		return "", err
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
		return "", fmt.Errorf("nginx -t failed, %s restored: %v", fqdn, err)
	}
	return tok, nil
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

// Handle executes one request under the dir lock, then runs the owed reload
// after releasing it (settle); list output goes to w as JSON. Both writes
// are fenced by owner, checked against the current file while the lock is
// held:
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
	if r.Op == "list" {
		if err := c.flush(); err != nil {
			return err
		}
		unlock, err := c.lock()
		if err != nil {
			return err
		}
		defer unlock()
		l, err := c.List()
		if err != nil {
			return err
		}
		return json.NewEncoder(w).Encode(l)
	}
	tok, err := c.underLock(func() (string, error) {
		if r.Op == "add" {
			now := time.Now()
			if r.Until != 0 && r.Until <= now.Unix() {
				return "", errors.New("until is in the past")
			}
			if e, ok := c.current(r.FQDN); ok && r.Kind == KindPlacement && e.LiveExpose(now) {
				return c.kept(w, e)
			}
			return c.swap(r.FQDN, []byte(c.Render(r)))
		}
		if e, ok := c.current(r.FQDN); ok && (e.Kind != r.Kind || (r.Host != "" && e.Host != r.Host)) {
			return c.kept(w, e)
		}
		return c.swap(r.FQDN, nil)
	})
	if err != nil {
		return err
	}
	return c.settle(tok)
}

// current is the header of fqdn's file, if it exists and parses.
func (c *Config) current(fqdn string) (Entry, bool) {
	b, err := os.ReadFile(c.path(fqdn))
	if err != nil {
		return Entry{}, false
	}
	return ParseHeader(b)
}

// kept (under the lock) reports a fenced no-op on w and returns an owed
// reload's token.
func (c *Config) kept(w io.Writer, e Entry) (string, error) {
	if w != nil {
		fmt.Fprintf(w, "%s%s on %s\n", KeptPrefix, KindName(e.Kind), e.Host)
	}
	return c.owed()
}

// Expire removes files whose until has passed (and unparseable ones: fail
// closed), then tests and (after releasing the lock) reloads once. The
// marker is set before any removal, and the reload also runs when only the
// marker is left (a previous run removed the files but its reload failed).
// With reload=false (boot, before nginx) the marker is left for the next run.
func (c *Config) Expire(now time.Time, reload bool) ([]string, error) {
	var gone []string
	tok, err := c.underLock(func() (string, error) {
		m, err := filepath.Glob(filepath.Join(c.Dir, "*.conf"))
		if err != nil {
			return "", err
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
			if _, err := c.setPending(); err != nil {
				return "", err
			}
		}
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
			return "", nil
		}
		return c.owed()
	})
	if err != nil {
		return gone, err
	}
	return gone, c.settle(tok)
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
	if c.Domain == "" || c.Dir == "" || c.CertDir == "" || c.NginxTest == "" || c.NginxReload == "" || c.NginxMainPID == "" {
		return nil, fmt.Errorf("%s: domain, dir, certDir, nginxTest, nginxReload and nginxMainPid are required", path)
	}
	if strings.Contains(c.NginxReload, "--no-block") {
		return nil, fmt.Errorf("%s: nginxReload must not use --no-block: settle confirms the reload only after it ran", path)
	}
	if c.LoginLog != "" && c.LoginLogFormat == "" {
		return nil, fmt.Errorf("%s: loginLog needs loginLogFormat", path)
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
