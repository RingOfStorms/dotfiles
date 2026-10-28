// Package overrides is h005's authority for public `cnt expose` overrides
// (containers/ROUTING-PLAN.md §8 step 7, "Public expose design").
//
// It runs as `fleet-edge overrides` in its own unit (fleet-edge-overrides),
// separate from the dashboard: only this process holds the bunny key and the
// o002 push key. State is one JSON file in its own 0700 state dir, written
// atomically under a mutex. Flow:
//
//	prepare  validate against the built-in inventory + publicSpec, reserve
//	commit   host status reports the public override -> CNAME -> o002 vhost
//	delete   o002 vhost -> CNAME (by id, exact match) -> row
//	sweep    every 30 s: expiry, retries, stale reservations, host drift
//
// Callers are hosts authenticating with their own Zitadel machine identity
// (the sec-agent machine key): a verified token whose sub is in an explicit
// allowlist, sent from that host's overlay IP. Roles and trust levels are
// never consulted. Every request (refusals too) goes to audit.log as one
// JSON line carrying the caller's sub and host.
package overrides

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/bunny"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgevhost"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

const (
	RecordTTL     = 60
	PrepareTTL    = 5 * time.Minute
	DriftGrace    = 2 * time.Minute
	RateWindow    = 10 * time.Minute
	RateMaxWrites = 30
)

// Row states.
const (
	Prepared  = "prepared"
	Committed = "committed"
	Removing  = "removing"
)

// Row is one override.
type Row struct {
	Service  string `json:"service"`
	Route    string `json:"route"`
	Host     string `json:"host"`
	FQDN     string `json:"fqdn"`
	Name     string `json:"name"` // zone-relative label
	Baseline string `json:"baseline"`
	Until    int64  `json:"until"` // 0 = forever
	State    string `json:"state"`
	RecordID int64  `json:"recordId,omitempty"`
	Edge     bool   `json:"edge"`   // o002 file pushed
	DNS      string `json:"dns"`    // "", ok, mismatch, released
	Device   string `json:"device"` // calling host (Writers key)
	User     string `json:"user,omitempty"`
	Reason   string `json:"reason,omitempty"`
	Created  int64  `json:"created"`
	Updated  int64  `json:"updated"`
	// HostMissingSince: first sweep at which the host's status didn't
	// report this override (0 = reported, or not checked yet).
	HostMissingSince int64  `json:"hostMissingSince,omitempty"`
	LastError        string `json:"lastError,omitempty"`
}

// Writer is one host allowed to call the API: its Zitadel machine user and
// the overlay IP its requests must come from.
type Writer struct {
	Sub  string `json:"sub"`
	Peer string `json:"peer"`
}

// TokenVerifier checks a Zitadel JWT's signature, issuer, project audience
// and expiry (auth.Authenticator).
type TokenVerifier interface {
	VerifyZitadelToken(raw string) (auth.VerifiedToken, error)
}

// DNS is the bunny side (interface for tests).
type DNS interface {
	Zone(ctx context.Context) (*bunny.Zone, error)
	Create(ctx context.Context, zoneID int64, name, value string, ttl int) (int64, error)
	Delete(ctx context.Context, zoneID, id int64) error
}

// Edge is the o002 side (interface for tests).
type Edge interface {
	Do(ctx context.Context, r edgevhost.Request) ([]byte, error)
}

// HostStatus fetches the overrides a host reports (nil, nil = old agent).
type HostStatus func(ctx context.Context, host string) ([]HostOverride, error)

// HostOverride mirrors fleet-agent's StatusDoc.Overrides entry.
type HostOverride struct {
	Service  string `json:"service"`
	Route    string `json:"route"`
	Exposure string `json:"exposure"`
	Until    int64  `json:"until"`
}

// Config wires a Service.
type Config struct {
	Inventory *inventory.Inventory
	Spec      *bunny.Spec
	Domain    string // fleet domain, = Spec.Zone
	Target    string // CNAME value, e.g. o002.joshuabell.xyz
	StateDir  string
	LockPath  string // shared with dns-plan --apply
	Verifier  TokenVerifier
	Writers   map[string]Writer // host -> machine user + overlay IP
	DNS       DNS               // nil: writes return 503
	Edge      Edge              // nil: writes return 503
	Status    HostStatus
	Now       func() time.Time
}

// Service is the running authority.
type Service struct {
	cfg   Config
	bySub map[string]string // Writers sub -> host
	mu    sync.Mutex
	rows  map[string]*Row // key: service
	rate  map[string][]time.Time
	audit *os.File
}

var nameRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// New loads state and opens the audit log.
func New(cfg Config) (*Service, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Spec == nil || cfg.Inventory == nil || cfg.Domain == "" || cfg.Target == "" || cfg.StateDir == "" {
		return nil, errors.New("overrides: inventory, spec, domain, target and state dir are required")
	}
	if cfg.Verifier == nil {
		return nil, errors.New("overrides: a token verifier is required")
	}
	s := &Service{cfg: cfg, bySub: map[string]string{}, rows: map[string]*Row{}, rate: map[string][]time.Time{}}
	for host, w := range cfg.Writers {
		if w.Sub == "" || net.ParseIP(w.Peer) == nil {
			return nil, fmt.Errorf("overrides: writer %s needs a sub and a peer IP", host)
		}
		if other, dup := s.bySub[w.Sub]; dup {
			return nil, fmt.Errorf("overrides: writers %s and %s share sub %s", other, host, w.Sub)
		}
		s.bySub[w.Sub] = host
	}
	b, err := os.ReadFile(s.statePath())
	if err == nil {
		var rows []*Row
		if err := json.Unmarshal(b, &rows); err != nil {
			return nil, fmt.Errorf("%s: %w", s.statePath(), err)
		}
		for _, r := range rows {
			s.rows[r.Service] = r
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	s.audit, err = os.OpenFile(filepath.Join(cfg.StateDir, "audit.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Service) statePath() string { return filepath.Join(s.cfg.StateDir, "state.json") }

func (s *Service) save() error {
	rows := s.sortedRows()
	b, err := json.MarshalIndent(rows, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.statePath() + ".new"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.statePath())
}

func (s *Service) sortedRows() []*Row {
	rows := make([]*Row, 0, len(s.rows))
	for _, r := range s.rows {
		rows = append(rows, r)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Service < rows[j].Service })
	return rows
}

// auditEntry is one audit.log line.
type auditEntry struct {
	TS      string `json:"ts"`
	Host    string `json:"host,omitempty"`
	Sub     string `json:"sub,omitempty"`
	Peer    string `json:"peer,omitempty"`
	User    string `json:"user,omitempty"`
	Action  string `json:"action"`
	Target  string `json:"target,omitempty"`
	Until   int64  `json:"until,omitempty"`
	Result  string `json:"result"`
	Message string `json:"message,omitempty"`
}

func (s *Service) logAudit(e auditEntry) {
	e.TS = s.cfg.Now().UTC().Format(time.RFC3339)
	b, _ := json.Marshal(e)
	log.Printf("audit %s", b)
	if s.audit != nil {
		_, _ = s.audit.Write(append(b, '\n'))
	}
}

// ---------------------------------------------------------------- validation

// Request is the prepare/commit body.
type Request struct {
	Service string `json:"service,omitempty"`
	Route   string `json:"route,omitempty"`
	Host    string `json:"host,omitempty"`
	Until   int64  `json:"until"` // 0 = forever
	Reason  string `json:"reason,omitempty"`
	User    string `json:"user,omitempty"`
}

// Check validates a request against the inventory and public spec, the same
// rules as lib.nix and the CLI's exposeCheck. It returns the route and the
// zone-relative name.
func Check(inv *inventory.Inventory, spec *bunny.Spec, domain string, req Request) (inventory.Route, string, error) {
	var zero inventory.Route
	svc, ok := inv.Services[req.Service]
	if !ok {
		return zero, "", fmt.Errorf("unknown service %q", req.Service)
	}
	r, ok := svc.Routes[req.Route]
	if !ok {
		return zero, "", fmt.Errorf("%s has no route %q", req.Service, req.Route)
	}
	where := req.Service + "." + req.Route
	if svc.Host == "" || svc.Host != req.Host {
		return zero, "", fmt.Errorf("%s: h005's inventory has host %q, the CLI says %q (rebuild h005 after deploys/moves)", where, svc.Host, req.Host)
	}
	if r.Proto != "http" {
		return zero, "", fmt.Errorf("%s: only http routes can be exposed publicly", where)
	}
	if inventory.Str(r.Zone) != "main" {
		return zero, "", fmt.Errorf("%s: zone %q can't be public", where, inventory.Str(r.Zone))
	}
	switch r.Exposure {
	case "local":
		return zero, "", fmt.Errorf("%s: local routes can't be exposed", where)
	case "public":
		return zero, "", fmt.Errorf("%s is already public in service.nix", where)
	case "tailnet", "lan":
	default:
		return zero, "", fmt.Errorf("%s: unknown exposure %q", where, r.Exposure)
	}
	if len(r.Via) > 0 && !(len(r.Via) == 1 && r.Via[0] == "edge") {
		return zero, "", fmt.Errorf("%s: via %v; public expose only goes through the edge", where, r.Via)
	}
	switch r.AuthStr() {
	case "none":
		if !r.PublicWithoutAuth {
			return zero, "", fmt.Errorf("%s: public with auth none needs publicWithoutAuth in service.nix", where)
		}
	case "oauth2-proxy", "native", "native-oidc":
	default:
		return zero, "", fmt.Errorf("%s: unknown auth %q", where, r.AuthStr())
	}
	if r.MaxBody == "" || r.Timeouts == "" {
		return zero, "", fmt.Errorf("%s: h005's inventory lacks maxBody/timeouts (rebuild h005 with the current containers input)", where)
	}
	fq := strings.ToLower(r.FQDNStr())
	name, ok := strings.CutSuffix(fq, "."+domain)
	if !ok || !nameRe.MatchString(name) {
		return zero, "", fmt.Errorf("%s: fqdn %q is not a single label under %s", where, fq, domain)
	}
	for _, d := range spec.Records {
		if strings.EqualFold(d.Name, name) {
			return zero, "", fmt.Errorf("%s: %s is declared in the public spec (%s)", where, fq, d.Source)
		}
	}
	for _, e := range spec.External {
		if strings.EqualFold(e, name) {
			return zero, "", fmt.Errorf("%s: %s is an external name", where, fq)
		}
	}
	// Retire-listed names are allowed: the override owns its record by id
	// and bunny.PlanWith never retires an owned record.
	return r, name, nil
}

// ---------------------------------------------------------------- auth / http

// caller is who made a request; fields are filled as far as auth got, for
// the audit log.
type caller struct {
	Host, Sub, Peer string
}

// authenticate accepts a request only if its bearer token is a valid
// Zitadel token (signature, issuer, project audience, expiry), its sub is a
// configured writer, and it came from that writer's overlay IP. The peer is
// X-Fleet-Peer when the TCP peer is loopback (h005 nginx sets it), else the
// TCP peer. Token roles are ignored.
func (s *Service) authenticate(r *http.Request) (caller, error) {
	var c caller
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return c, errors.New("no peer")
	}
	if ip := net.ParseIP(peer); ip != nil && ip.IsLoopback() {
		if p := strings.TrimSpace(r.Header.Get("X-Fleet-Peer")); p != "" {
			peer = p
		}
	}
	c.Peer = peer
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || strings.TrimSpace(tok) == "" {
		return c, errors.New("missing bearer token")
	}
	id, err := s.cfg.Verifier.VerifyZitadelToken(tok)
	if err != nil {
		return c, fmt.Errorf("token: %w", err)
	}
	c.Sub = id.Subject
	host, ok := s.bySub[id.Subject]
	if !ok {
		return c, errors.New("sub is not an override writer")
	}
	c.Host = host
	want := net.ParseIP(s.cfg.Writers[host].Peer)
	if got := net.ParseIP(peer); got == nil || !got.Equal(want) {
		return c, fmt.Errorf("token of %s used from %s", host, peer)
	}
	return c, nil
}

func (s *Service) allowWrite(host string) (bool, time.Duration) {
	now := s.cfg.Now()
	var keep []time.Time
	for _, t := range s.rate[host] {
		if now.Sub(t) < RateWindow {
			keep = append(keep, t)
		}
	}
	if len(keep) >= RateMaxWrites {
		s.rate[host] = keep
		return false, RateWindow - now.Sub(keep[0])
	}
	s.rate[host] = append(keep, now)
	return true, 0
}

type httpErr struct {
	code int
	msg  string
}

func (e *httpErr) Error() string { return e.msg }

func fail(code int, f string, a ...any) error { return &httpErr{code, fmt.Sprintf(f, a...)} }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// Handler serves /api/overrides* (behind h005 nginx) and the loopback-only
// /internal/overrides.json export.
func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/overrides.json", s.handleExport)
	mux.HandleFunc("/api/overrides", s.handleAPI)
	mux.HandleFunc("/api/overrides/", s.handleAPI)
	return mux
}

func (s *Service) handleExport(w http.ResponseWriter, r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() || r.Header.Get("X-Fleet-Peer") != "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, s.export())
}

// Export is the read-only view (dashboard, dns-plan).
type Export struct {
	Rows  []*Row        `json:"rows"`
	Owned []bunny.Owned `json:"owned"`
}

func (s *Service) export() Export {
	e := Export{Rows: s.sortedRows(), Owned: []bunny.Owned{}}
	for _, r := range e.Rows {
		if r.RecordID != 0 && r.DNS != "released" {
			e.Owned = append(e.Owned, bunny.Owned{ID: r.RecordID, Name: r.Name, Service: r.Service})
		}
	}
	return e
}

func (s *Service) handleAPI(w http.ResponseWriter, r *http.Request) {
	c, err := s.authenticate(r)
	if err != nil {
		s.logAudit(auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, Action: r.Method + " " + r.URL.Path, Result: "denied", Message: err.Error()})
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	rest := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/api/overrides"), "/")
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Method == http.MethodGet && rest == "" {
		v := map[string]any{"rows": s.sortedRows()}
		if r.URL.Query().Get("verify") == "1" {
			v["verify"] = s.verify(r.Context())
		}
		writeJSON(w, 200, v)
		return
	}
	act := ""
	var req Request
	switch {
	case r.Method == http.MethodPost && (rest == "prepare" || rest == "commit"):
		act = rest
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			http.Error(w, "bad request: "+err.Error(), 400)
			return
		}
	case r.Method == http.MethodDelete && rest != "" && !strings.Contains(rest, "/"):
		act, req.Service = "delete", rest
		req.User = r.URL.Query().Get("user")
	default:
		http.Error(w, "not found", 404)
		return
	}
	if ok, wait := s.allowWrite(c.Host); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		s.logAudit(auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, User: req.User, Action: act, Target: req.Service, Result: "rate-limited"})
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	var row *Row
	switch act {
	case "prepare":
		row, err = s.prepare(req, c.Host)
	case "commit":
		row, err = s.commit(r.Context(), req, c.Host)
	case "delete":
		row, err = s.remove(r.Context(), req.Service, "revoke")
	}
	e := auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, User: req.User, Action: act, Target: req.Service + "." + req.Route, Until: req.Until, Result: "ok"}
	if err != nil {
		code := 500
		var he *httpErr
		if errors.As(err, &he) {
			code = he.code
		}
		e.Result, e.Message = "error", err.Error()
		s.logAudit(e)
		writeJSON(w, code, map[string]any{"error": err.Error(), "row": row})
		return
	}
	s.logAudit(e)
	writeJSON(w, 200, map[string]any{"row": row})
}

// ---------------------------------------------------------------- operations

func (s *Service) writable() error {
	if s.cfg.DNS == nil || s.cfg.Edge == nil {
		return fail(503, "public expose is not configured on h005 (no bunny or push key)")
	}
	return nil
}

func (s *Service) prepare(req Request, dev string) (*Row, error) {
	if err := s.writable(); err != nil {
		return nil, err
	}
	now := s.cfg.Now().Unix()
	if req.Until != 0 && req.Until <= now {
		return nil, fail(400, "until is in the past")
	}
	rt, name, err := Check(s.cfg.Inventory, s.cfg.Spec, s.cfg.Domain, req)
	if err != nil {
		return nil, fail(409, "%v", err)
	}
	for _, o := range s.rows {
		if o.Name == name && o.Service != req.Service {
			return nil, fail(409, "%s is held by %s's override", name, o.Service)
		}
	}
	if o, ok := s.rows[req.Service]; ok {
		if o.Route != req.Route {
			return o, fail(409, "%s already has a public override on route %s; revoke first", req.Service, o.Route)
		}
		if o.State == Removing {
			return o, fail(409, "%s is being removed; retry in a minute", req.Service)
		}
		o.Until, o.Reason, o.User, o.Device, o.Updated = req.Until, req.Reason, req.User, dev, now
		return o, s.save()
	}
	o := &Row{Service: req.Service, Route: req.Route, Host: req.Host, FQDN: rt.FQDNStr(), Name: name,
		Baseline: rt.Exposure, Until: req.Until, State: Prepared, Device: dev, User: req.User,
		Reason: req.Reason, Created: now, Updated: now}
	s.rows[req.Service] = o
	return o, s.save()
}

func (s *Service) hostReports(ctx context.Context, o *Row) (bool, error) {
	if s.cfg.Status == nil {
		return false, errors.New("no host status fetcher")
	}
	c, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ovs, err := s.cfg.Status(c, o.Host)
	if err != nil {
		return false, err
	}
	if ovs == nil {
		return false, fmt.Errorf("%s's fleet-agent doesn't report overrides (update fleet-agent there)", o.Host)
	}
	for _, h := range ovs {
		if h.Service == o.Service && h.Route == o.Route && h.Exposure == "public" {
			return true, nil
		}
	}
	return false, nil
}

func (s *Service) lock() (func(), error) {
	if s.cfg.LockPath == "" {
		return func() {}, nil
	}
	return bunny.Lock(s.cfg.LockPath)
}

// ensureDNS makes sure o's CNAME exists and is ours.
func (s *Service) ensureDNS(ctx context.Context, o *Row) (created bool, err error) {
	unlock, err := s.lock()
	if err != nil {
		return false, err
	}
	defer unlock()
	z, err := s.cfg.DNS.Zone(ctx)
	if err != nil {
		return false, err
	}
	if o.RecordID != 0 {
		if r := z.FindRecord(o.RecordID); r != nil && s.matches(r, o) {
			o.DNS = "ok"
			return false, nil
		}
		o.RecordID = 0
	}
	for _, r := range z.Records {
		if strings.EqualFold(r.Name, o.Name) {
			return false, fmt.Errorf("bunny already has a %s record for %s that this override doesn't own", bunny.TypeName(r.Type), o.FQDN)
		}
	}
	id, err := s.cfg.DNS.Create(ctx, z.ID, o.Name, s.cfg.Target, RecordTTL)
	if err != nil {
		return false, err
	}
	o.RecordID, o.DNS = id, "ok"
	return true, nil
}

func (s *Service) matches(r *bunny.Record, o *Row) bool {
	return strings.EqualFold(r.Name, o.Name) && bunny.TypeName(r.Type) == "CNAME" &&
		strings.TrimSuffix(strings.ToLower(r.Value), ".") == strings.ToLower(s.cfg.Target)
}

// dropDNS deletes o's record by id, only if it still matches.
func (s *Service) dropDNS(ctx context.Context, o *Row) error {
	if o.RecordID == 0 || o.DNS == "released" {
		return nil
	}
	if s.declared(o.Name) {
		o.DNS = "released"
		return nil
	}
	unlock, err := s.lock()
	if err != nil {
		return err
	}
	defer unlock()
	z, err := s.cfg.DNS.Zone(ctx)
	if err != nil {
		return err
	}
	r := z.FindRecord(o.RecordID)
	if r == nil {
		o.RecordID, o.DNS = 0, ""
		return nil
	}
	if !s.matches(r, o) {
		o.DNS = "mismatch"
		return fmt.Errorf("record %d no longer matches %s CNAME %s; left in place", o.RecordID, o.Name, s.cfg.Target)
	}
	if err := s.cfg.DNS.Delete(ctx, z.ID, o.RecordID); err != nil {
		return err
	}
	o.RecordID, o.DNS = 0, ""
	return nil
}

func (s *Service) declared(name string) bool {
	for _, d := range s.cfg.Spec.Records {
		if strings.EqualFold(d.Name, name) {
			return true
		}
	}
	return false
}

func (s *Service) edgeReq(o *Row) (edgevhost.Request, error) {
	rt := s.cfg.Inventory.Services[o.Service].Routes[o.Route]
	if rt.MaxBody == "" {
		return edgevhost.Request{}, fmt.Errorf("%s.%s missing from h005's inventory", o.Service, o.Route)
	}
	rb := true
	if rt.RequestBuffering != nil {
		rb = *rt.RequestBuffering
	}
	return edgevhost.Request{Op: "add", FQDN: o.FQDN, Host: o.Host, Until: o.Until, MaxBody: rt.MaxBody,
		Websockets: rt.Websockets, Buffering: rt.Buffering, RequestBuffering: rb, Timeouts: rt.Timeouts}, nil
}

func (s *Service) pushEdge(ctx context.Context, o *Row) error {
	req, err := s.edgeReq(o)
	if err != nil {
		return err
	}
	c, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if _, err := s.cfg.Edge.Do(c, req); err != nil {
		return err
	}
	o.Edge = true
	return nil
}

func (s *Service) dropEdge(ctx context.Context, o *Row) error {
	c, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if _, err := s.cfg.Edge.Do(c, edgevhost.Request{Op: "remove", FQDN: o.FQDN}); err != nil {
		return err
	}
	o.Edge = false
	return nil
}

func (s *Service) commit(ctx context.Context, req Request, dev string) (*Row, error) {
	if err := s.writable(); err != nil {
		return nil, err
	}
	o, ok := s.rows[req.Service]
	if !ok || o.Route != req.Route || o.Host != req.Host {
		return o, fail(409, "no matching prepared override for %s.%s on %s (prepare first)", req.Service, req.Route, req.Host)
	}
	if o.State == Removing {
		return o, fail(409, "%s is being removed", req.Service)
	}
	if _, _, err := Check(s.cfg.Inventory, s.cfg.Spec, s.cfg.Domain, req); err != nil {
		return o, fail(409, "%v", err)
	}
	if req.Until != o.Until {
		o.Until = req.Until
	}
	now := s.cfg.Now().Unix()
	if o.Until != 0 && o.Until <= now {
		return o, fail(400, "until is in the past")
	}
	okHost, err := s.hostReports(ctx, o)
	if err != nil {
		return o, fail(502, "%s status: %v", o.Host, err)
	}
	if !okHost {
		return o, fail(409, "%s doesn't report %s.%s as public; apply the host vhost first", o.Host, o.Service, o.Route)
	}
	if _, err := s.ensureDNS(ctx, o); err != nil {
		o.LastError = err.Error()
		_ = s.save()
		return o, fail(502, "dns: %v", err)
	}
	_ = s.save() // record id is durable before o002 is touched
	if err := s.pushEdge(ctx, o); err != nil {
		// The ssh error can arrive after o002 applied the site, and on a
		// renewal the record predates this commit: never drop the row here.
		// Mark it Removing durably, then drive the same idempotent cleanup
		// as revoke (o002 remove, then dropDNS by id+name+type+value). The
		// row goes only once both succeeded; otherwise the sweep retries.
		perr := fmt.Errorf("o002: %v", err)
		o.State, o.LastError, o.Updated = Removing, perr.Error(), now
		o.Edge = true // unknown: assume applied so removal is attempted
		if serr := s.save(); serr != nil {
			return o, fail(500, "%v; saving removal state: %v", perr, serr)
		}
		if _, rerr := s.remove(ctx, o.Service, "commit failed"); rerr != nil {
			return o, fail(502, "%v; cleanup: %v", perr, rerr)
		}
		return o, fail(502, "%v (cleaned up)", perr)
	}
	o.State, o.LastError, o.HostMissingSince, o.Updated, o.Device = Committed, "", 0, now, dev
	if req.User != "" {
		o.User = req.User
	}
	return o, s.save()
}

// remove takes o002 down, then DNS, then the row. A failed o002 remove
// still deletes DNS and leaves the row Removing for the sweep.
func (s *Service) remove(ctx context.Context, svc, why string) (*Row, error) {
	o, ok := s.rows[svc]
	if !ok {
		return nil, nil // idempotent
	}
	o.State, o.Updated = Removing, s.cfg.Now().Unix()
	var errs []string
	if s.cfg.Edge == nil || s.cfg.DNS == nil {
		if o.Edge || o.RecordID != 0 {
			errs = append(errs, "not configured; leftovers stay until the keys are back")
		}
	} else {
		if err := s.dropEdge(ctx, o); err != nil {
			errs = append(errs, "o002: "+err.Error())
		}
		if err := s.dropDNS(ctx, o); err != nil {
			errs = append(errs, "dns: "+err.Error())
		}
	}
	if len(errs) > 0 && o.DNS != "mismatch" {
		o.LastError = strings.Join(errs, "; ")
		_ = s.save()
		return o, fail(502, "%s (%s; sweep retries)", o.LastError, why)
	}
	if o.DNS == "mismatch" {
		// Kept and flagged for a human; o002 is closed.
		o.LastError = strings.Join(errs, "; ")
		_ = s.save()
		return o, fail(409, "%s", o.LastError)
	}
	delete(s.rows, svc)
	log.Printf("override %s.%s removed (%s)", o.Service, o.Route, why)
	return o, s.save()
}

// Sweep runs expiry, retries and drift checks once.
func (s *Service) Sweep(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.cfg.Now()
	for _, o := range s.sortedRows() {
		why := ""
		switch {
		case o.State == Removing:
			if o.DNS == "mismatch" && !o.Edge { // edge gone: only the DNS record is left, for a human
				continue
			}
			why = "retry"
		case o.State == Prepared && now.Sub(time.Unix(o.Updated, 0)) > PrepareTTL:
			why = "stale reservation"
		case o.Until != 0 && now.Unix() >= o.Until:
			why = "expired"
		case o.State == Committed && s.cfg.Status != nil:
			okHost, err := s.hostReports(ctx, o)
			if err != nil || okHost {
				o.HostMissingSince = 0 // unreachable host: its own expiry closes it
				continue
			}
			if o.HostMissingSince == 0 {
				o.HostMissingSince = now.Unix()
				_ = s.save()
				continue
			}
			if now.Sub(time.Unix(o.HostMissingSince, 0)) < DriftGrace {
				continue
			}
			why = "host no longer reports it"
		default:
			continue
		}
		_, err := s.remove(ctx, o.Service, why)
		e := auditEntry{Host: "h005", Action: "sweep", Target: o.Service + "." + o.Route, Result: "ok", Message: why}
		if err != nil {
			e.Result, e.Message = "error", why+": "+err.Error()
		}
		s.logAudit(e)
	}
	if s.cfg.Edge != nil {
		s.reconcileEdge(ctx)
	}
}

// reconcileEdge re-pushes committed rows missing on o002 (it doesn't persist
// its dir) and marks rows whose file is gone.
func (s *Service) reconcileEdge(ctx context.Context) {
	c, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := s.cfg.Edge.Do(c, edgevhost.Request{Op: "list"})
	if err != nil {
		return
	}
	var live []edgevhost.Entry
	if json.Unmarshal(out, &live) != nil {
		return
	}
	have := map[string]bool{}
	for _, e := range live {
		have[e.FQDN] = true
	}
	for _, o := range s.rows {
		if o.State == Committed && !have[o.FQDN] {
			o.Edge = false
			if err := s.pushEdge(ctx, o); err != nil {
				o.LastError = "re-push: " + err.Error()
			} else {
				s.logAudit(auditEntry{Host: "h005", Action: "sweep", Target: o.Service + "." + o.Route, Result: "ok", Message: "re-pushed to o002"})
			}
		}
	}
	_ = s.save()
}

// Verify is live state for `cnt audit` / `cnt expose --list`.
type Verify struct {
	DNS       map[string]string `json:"dns"`       // service -> ok|missing|mismatch|error
	Edge      map[string]string `json:"edge"`      // service -> ok|missing|error
	EdgeExtra []string          `json:"edgeExtra"` // o002 files without a row
	// EdgeReloadPending: o002's nginx still owes a reload (a removed site
	// may still be served); every row's edge state is "reload pending".
	EdgeReloadPending bool   `json:"edgeReloadPending,omitempty"`
	Error             string `json:"error,omitempty"` // fetch errors
}

func (s *Service) verify(ctx context.Context) Verify {
	v := Verify{DNS: map[string]string{}, Edge: map[string]string{}, EdgeExtra: []string{}}
	var errs []string
	if s.cfg.DNS != nil {
		if z, err := s.cfg.DNS.Zone(ctx); err != nil {
			errs = append(errs, "dns: "+err.Error())
		} else {
			for _, o := range s.rows {
				switch r := z.FindRecord(o.RecordID); {
				case o.RecordID == 0:
					v.DNS[o.Service] = "missing"
				case r == nil:
					v.DNS[o.Service] = "missing"
				case !s.matches(r, o):
					v.DNS[o.Service] = "mismatch"
				default:
					v.DNS[o.Service] = "ok"
				}
			}
		}
	}
	if s.cfg.Edge != nil {
		c, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		out, err := s.cfg.Edge.Do(c, edgevhost.Request{Op: "list"})
		var live []edgevhost.Entry
		if err == nil {
			err = json.Unmarshal(out, &live)
		}
		if err != nil && strings.Contains(err.Error(), edgevhost.ErrReloadPending) {
			v.EdgeReloadPending = true
			for _, o := range s.rows {
				v.Edge[o.Service] = edgevhost.ErrReloadPending
			}
			errs = append(errs, "o002: "+err.Error())
		} else if err != nil {
			errs = append(errs, "o002: "+err.Error())
		} else {
			have := map[string]bool{}
			rowFor := map[string]bool{}
			for _, o := range s.rows {
				rowFor[o.FQDN] = true
			}
			for _, e := range live {
				have[e.FQDN] = true
				if !rowFor[e.FQDN] {
					v.EdgeExtra = append(v.EdgeExtra, e.FQDN)
				}
			}
			for _, o := range s.rows {
				if have[o.FQDN] {
					v.Edge[o.Service] = "ok"
				} else {
					v.Edge[o.Service] = "missing"
				}
			}
		}
	}
	v.Error = strings.Join(errs, "; ")
	return v
}

// Run sweeps at startup and every interval until ctx ends.
func (s *Service) Run(ctx context.Context, every time.Duration) {
	s.Sweep(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Sweep(ctx)
		}
	}
}
