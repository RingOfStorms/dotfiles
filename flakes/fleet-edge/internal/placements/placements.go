// Package placements is h005's registry of where each container service runs
// (containers/PLACEMENT-PLAN.md).
//
// It is the only runtime answer to "which host runs service X". Nix describes
// what a service is; placement, DNS, o002 vhosts, certificates and firewall
// admission are decided here, at deploy and move time, and recorded in one
// JSON file in its own 0700 state dir (written atomically under a mutex).
// Flow:
//
//	reserve  validate the destination, record it and the prior binding
//	commit   DNS and o002 point at the destination (the cutover is done)
//	retire   the source is being uninstalled; a rollback now needs force
//	delete   restore the prior binding, or drop the row if there is none
//	sweep    every 30 s: expired reservations, host drift, split brain,
//	         retired sources
//
// A move reserves before the source stops and commits only after routing has
// cut over, so the old host stays intact for rollback; rollback restores the
// prior binding, it never deletes it. A service seen on two hosts is flagged
// and never resolved automatically.
//
// Callers are hosts authenticating with their own Zitadel machine identity,
// through internal/authority (the same allowlist as the expose authority):
// a verified token whose sub is listed, sent from that host's overlay IP.
// Every request (refusals too) goes to placements-audit.log as one JSON line
// carrying the caller's sub and host.
package placements

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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// ReserveTTL bounds how long a reservation may sit uncommitted: the sweep
// rolls it back, because a move that never cut over left the source serving.
const ReserveTTL = 30 * time.Minute

// Row states.
const (
	Prepared  = "prepared"  // destination reserved; the source still serves
	Committed = "committed" // routing points at the destination
	Retiring  = "retiring"  // the source is being uninstalled
)

// Binding is one placement of a service on a host.
type Binding struct {
	Host string `json:"host"`
}

// Row is one service's placement.
type Row struct {
	Service string `json:"service"`
	// Host is the destination: where the service should run. While State is
	// Prepared it is reserved rather than live; see Effective.
	Host     string   `json:"host"`
	State    string   `json:"state"`
	Previous *Binding `json:"previous,omitempty"` // the prior binding, for rollback
	Device   string   `json:"device"`             // calling host (Writers key)
	User     string   `json:"user,omitempty"`
	Reason   string   `json:"reason,omitempty"`
	Created  int64    `json:"created"`
	Updated  int64    `json:"updated"`
	// ReserveSince: when the current reservation was made; the sweep rolls
	// back a reservation older than ReserveTTL (0 = committed).
	ReserveSince int64 `json:"reserveSince,omitempty"`
	// HostMissingSince: first sweep at which the bound host didn't report
	// the service (0 = reported, or not checked yet).
	HostMissingSince int64 `json:"hostMissingSince,omitempty"`
	// Conflict names another host that also reports the service (split
	// brain). Never resolved automatically.
	Conflict  string `json:"conflict,omitempty"`
	LastError string `json:"lastError,omitempty"`
}

// Effective is the host that runs the service now: the destination only once
// the move is committed; while prepared the source still serves, and a first
// placement serves nowhere yet.
func (r *Row) Effective() string {
	if r.State != Prepared {
		return r.Host
	}
	if r.Previous != nil {
		return r.Previous.Host
	}
	return ""
}

// Config wires a Service.
type Config struct {
	Inventory *inventory.Inventory
	StateDir  string
	Auth      *authority.Auth // shared writer allowlist
	Status    HostServices    // nil: host checks are skipped
	Now       func() time.Time
}

// Service is the running registry.
type Service struct {
	cfg   Config
	auth  *authority.Auth
	mu    sync.Mutex
	rows  map[string]*Row // key: service
	audit *os.File
}

// New loads state and opens the audit log.
func New(cfg Config) (*Service, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Inventory == nil || cfg.StateDir == "" {
		return nil, errors.New("placements: an inventory and a state dir are required")
	}
	if cfg.Auth == nil {
		return nil, errors.New("placements: a writer allowlist is required")
	}
	s := &Service{cfg: cfg, auth: cfg.Auth, rows: map[string]*Row{}}
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
	s.audit, err = os.OpenFile(filepath.Join(cfg.StateDir, "placements-audit.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Service) statePath() string { return filepath.Join(s.cfg.StateDir, "placements.json") }

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

// auditEntry is one placements-audit.log line.
type auditEntry struct {
	TS      string `json:"ts"`
	Host    string `json:"host,omitempty"`
	Sub     string `json:"sub,omitempty"`
	Peer    string `json:"peer,omitempty"`
	User    string `json:"user,omitempty"`
	Action  string `json:"action"`
	Target  string `json:"target,omitempty"`
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

// Handler serves /api/placements* (behind h005 nginx) and the loopback-only
// /internal/placements.json export.
func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/placements.json", s.handleExport)
	mux.HandleFunc("/api/placements", s.handleAPI)
	mux.HandleFunc("/api/placements/", s.handleAPI)
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

// Export is the read-only view (dashboard, dns-plan, o002 vhosts, `cnt`).
type Export struct {
	Rows []*Row `json:"rows"`
	// Host maps a service to the host that runs it now, so a reader that
	// only needs "where" does not have to replay the state machine.
	Host map[string]string `json:"host"`
	// Conflicts maps a service to another host that also reports it.
	Conflicts map[string]string `json:"conflicts,omitempty"`
}

func (s *Service) export() Export {
	e := Export{Rows: s.sortedRows(), Host: map[string]string{}, Conflicts: map[string]string{}}
	for _, r := range e.Rows {
		if h := r.Effective(); h != "" {
			e.Host[r.Service] = h
		}
		if r.Conflict != "" {
			e.Conflicts[r.Service] = r.Conflict
		}
	}
	return e
}

// Request is the reserve/commit/retire body.
type Request struct {
	Service string `json:"service,omitempty"`
	Host    string `json:"host,omitempty"`
	Reason  string `json:"reason,omitempty"`
	User    string `json:"user,omitempty"`
	// Force overrides a safety check the operator has verified by hand.
	Force bool `json:"force,omitempty"`
}

// Import is the one-time bootstrap body: the placements currently observed,
// so the registry starts from reality instead of from Nix.
type Import struct {
	User       string      `json:"user,omitempty"`
	Reason     string      `json:"reason,omitempty"`
	Force      bool        `json:"force,omitempty"`
	Placements []Placement `json:"placements"`
}

// Placement is one imported service -> host.
type Placement struct {
	Service string `json:"service"`
	Host    string `json:"host"`
}

func decode(w http.ResponseWriter, r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func (s *Service) handleAPI(w http.ResponseWriter, r *http.Request) {
	c, err := s.auth.Authenticate(r)
	if err != nil {
		s.logAudit(auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, Action: r.Method + " " + r.URL.Path, Result: "denied", Message: err.Error()})
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	rest := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/api/placements"), "/")
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Method == http.MethodGet && rest == "" {
		v := map[string]any{"rows": s.sortedRows(), "host": s.export().Host}
		if r.URL.Query().Get("verify") == "1" {
			v["verify"] = s.verify(r.Context())
		}
		writeJSON(w, 200, v)
		return
	}
	var (
		req Request
		imp Import
		act string
	)
	switch {
	case r.Method == http.MethodPost && rest == "import":
		act = rest
		if err := decode(w, r, &imp); err != nil {
			http.Error(w, "bad request: "+err.Error(), 400)
			return
		}
		req.Service, req.User, req.Force = "import", imp.User, imp.Force
	case r.Method == http.MethodPost && (rest == "reserve" || rest == "commit" || rest == "retire"):
		act = rest
		if err := decode(w, r, &req); err != nil {
			http.Error(w, "bad request: "+err.Error(), 400)
			return
		}
	case r.Method == http.MethodDelete && rest != "" && !strings.Contains(rest, "/"):
		act, req.Service = "delete", rest
		req.User = r.URL.Query().Get("user")
		req.Force = r.URL.Query().Get("force") == "1"
	default:
		http.Error(w, "not found", 404)
		return
	}
	if ok, wait := s.auth.AllowWrite(c.Host); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		s.logAudit(auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, User: req.User, Action: act, Target: req.Service, Result: "rate-limited"})
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	target := req.Service
	if req.Host != "" {
		target = req.Service + "@" + req.Host
	}
	var (
		row *Row
		out map[string]any
	)
	switch act {
	case "reserve":
		row, err = s.reserve(req, c.Host)
	case "commit":
		row, err = s.commit(req, c.Host)
	case "retire":
		row, err = s.retire(req, c.Host)
	case "delete":
		row, err = s.remove(req.Service, req.Force)
	case "import":
		out, err = s.importRows(imp, c.Host)
	}
	e := auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, User: req.User, Action: act, Target: target, Result: "ok"}
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
	if out != nil {
		writeJSON(w, 200, out)
		return
	}
	writeJSON(w, 200, map[string]any{"row": row})
}

// ---------------------------------------------------------------- operations

// knownHost reports whether h may hold containers: a container host or a host
// the inventory otherwise knows.
func (s *Service) knownHost(h string) bool {
	if _, ok := s.cfg.Inventory.Hosts[h]; ok {
		return true
	}
	for _, c := range s.cfg.Inventory.ContainerHosts {
		if c == h {
			return true
		}
	}
	return false
}

func (s *Service) checkService(name string) error {
	if name == "" {
		return fail(400, "service is required")
	}
	if _, ok := s.cfg.Inventory.Services[name]; !ok {
		return fail(404, "%s: unknown service", name)
	}
	return nil
}

func (s *Service) checkHost(h string) error {
	if h == "" {
		return fail(400, "host is required")
	}
	if !s.knownHost(h) {
		return fail(409, "%s: not a container host", h)
	}
	return nil
}

// runsOn reports whether host reports the service. known is false when the
// host could not be asked, so callers never treat silence as absence.
func (s *Service) runsOn(ctx context.Context, host, service string) (running, known bool) {
	if s.cfg.Status == nil {
		return false, false
	}
	svcs, err := s.cfg.Status(ctx, host)
	if err != nil {
		return false, false
	}
	return svcs[service], true
}

// reserve prepares a placement: the destination is recorded (with the prior
// binding, if any) but nothing is routed to it yet. The source keeps serving
// until commit, so this is safe to run before stopping anything.
func (s *Service) reserve(req Request, dev string) (*Row, error) {
	if err := s.checkService(req.Service); err != nil {
		return nil, err
	}
	if err := s.checkHost(req.Host); err != nil {
		return nil, err
	}
	now := s.cfg.Now().Unix()
	r := s.rows[req.Service]
	if r != nil && r.Host == req.Host {
		if r.State != Prepared {
			return nil, fail(409, "%s is already placed on %s", req.Service, req.Host)
		}
		r.Device, r.User, r.Reason, r.Updated, r.ReserveSince = dev, req.User, req.Reason, now, now
		return r, s.save()
	}
	// A move onto a host that already runs the service would leave two copies
	// with one name. A first placement has no prior binding to duplicate.
	if r != nil && !req.Force {
		if running, known := s.runsOn(context.Background(), req.Host, req.Service); known && running {
			return nil, fail(409, "%s already runs on %s: a second copy would split it (force if that copy is the one to keep)", req.Service, req.Host)
		}
	}
	var prev *Binding
	if r != nil {
		switch r.State {
		case Prepared:
			// An abandoned destination is not a rollback target: keep the
			// last committed binding instead.
			prev = r.Previous
		default:
			prev = &Binding{Host: r.Host}
		}
	}
	if r == nil {
		r = &Row{Service: req.Service, Created: now}
		s.rows[req.Service] = r
	}
	r.Host, r.State, r.Previous = req.Host, Prepared, prev
	r.Device, r.User, r.Reason = dev, req.User, req.Reason
	r.Updated, r.ReserveSince = now, now
	r.HostMissingSince, r.Conflict, r.LastError = 0, "", ""
	return r, s.save()
}

// commit records that routing (DNS and o002) points at the destination. The
// destination must report the service unless it cannot be asked.
func (s *Service) commit(req Request, dev string) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement to commit", req.Service)
	}
	if r.State != Prepared {
		return nil, fail(409, "%s is not prepared (state %s)", req.Service, r.State)
	}
	if req.Host != "" && req.Host != r.Host {
		return nil, fail(409, "%s is reserved for %s, not %s", req.Service, r.Host, req.Host)
	}
	if running, known := s.runsOn(context.Background(), r.Host, r.Service); known && !running {
		return nil, fail(409, "%s does not report %s yet: deploy it there first", r.Host, req.Service)
	}
	r.State, r.Updated, r.ReserveSince, r.Device = Committed, s.cfg.Now().Unix(), 0, dev
	return r, s.save()
}

// retire records that the source is being uninstalled: its data is renamed, so
// a rollback onto it is no longer free. The previous binding is kept until the
// sweep sees the source stop reporting the service.
func (s *Service) retire(req Request, dev string) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement", req.Service)
	}
	if r.State == Prepared {
		return nil, fail(409, "%s is still prepared: commit the move first", req.Service)
	}
	if r.Previous == nil {
		return r, nil // something else already retired it
	}
	r.State, r.Updated, r.Device = Retiring, s.cfg.Now().Unix(), dev
	return r, s.save()
}

// remove rolls the placement back to its prior binding, or drops the row when
// there is none. A single placement (no prior binding) is simply deleted.
func (s *Service) remove(service string, force bool) (*Row, error) {
	r := s.rows[service]
	if r == nil {
		return nil, nil
	}
	if r.Previous == nil {
		delete(s.rows, service)
		return nil, s.save()
	}
	if r.State == Retiring && !force {
		return nil, fail(409, "%s's source was retired: %s no longer has its data (force to record it anyway)", service, r.Previous.Host)
	}
	r.Host, r.State, r.Previous = r.Previous.Host, Committed, nil
	r.Updated, r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = s.cfg.Now().Unix(), 0, 0, "", ""
	return r, s.save()
}

// importRows adopts observed placements. It is the one-time bootstrap, not a
// deploy path: an existing row is kept unless force.
func (s *Service) importRows(imp Import, dev string) (map[string]any, error) {
	if len(imp.Placements) == 0 {
		return nil, fail(400, "placements is empty")
	}
	seen := map[string]bool{}
	for _, p := range imp.Placements {
		if err := s.checkService(p.Service); err != nil {
			return nil, err
		}
		if err := s.checkHost(p.Host); err != nil {
			return nil, err
		}
		if seen[p.Service] {
			return nil, fail(400, "%s appears twice", p.Service)
		}
		seen[p.Service] = true
	}
	now := s.cfg.Now().Unix()
	imported, skipped := []string{}, []string{}
	for _, p := range imp.Placements {
		if r, ok := s.rows[p.Service]; ok && !imp.Force {
			skipped = append(skipped, p.Service+" on "+r.Host)
			continue
		}
		r := s.rows[p.Service]
		if r == nil {
			r = &Row{Service: p.Service, Created: now}
			s.rows[p.Service] = r
		}
		r.Host, r.State, r.Previous = p.Host, Committed, nil
		r.Device, r.User, r.Reason, r.Updated = dev, imp.User, imp.Reason, now
		r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = 0, 0, "", ""
		imported = append(imported, p.Service+" on "+p.Host)
	}
	return map[string]any{"imported": imported, "skipped": skipped}, s.save()
}

// ---------------------------------------------------------------- host status

// statuses asks every host that could matter (all container hosts, plus any
// host a row names) what it runs. A nil map means the host did not answer.
func (s *Service) statuses(ctx context.Context, rows []*Row) (map[string]map[string]bool, []string) {
	out := map[string]map[string]bool{}
	if s.cfg.Status == nil {
		return out, nil
	}
	want := map[string]bool{}
	for _, h := range s.cfg.Inventory.ContainerHosts {
		want[h] = true
	}
	for _, r := range rows {
		want[r.Host] = true
		if r.Previous != nil {
			want[r.Previous.Host] = true
		}
	}
	var errs []string
	for h := range want {
		svcs, err := s.cfg.Status(ctx, h)
		if err != nil {
			out[h] = nil
			errs = append(errs, h+": "+err.Error())
			continue
		}
		out[h] = svcs
	}
	return out, errs
}

// Sweep reconciles rows with host status: expired reservations roll back, drift
// and split brain are recorded (never auto-resolved), retired sources drop
// their rollback binding. Unreachable hosts change nothing.
func (s *Service) Sweep(ctx context.Context) {
	s.mu.Lock()
	snap := make([]*Row, 0, len(s.rows))
	for _, r := range s.rows {
		c := *r
		snap = append(snap, &c)
	}
	s.mu.Unlock()
	st, _ := s.statuses(ctx, snap)
	now := s.cfg.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for _, before := range snap {
		r, ok := s.rows[before.Service]
		if !ok || r.Host != before.Host || r.State != before.State {
			continue // changed under us: the mutating request owns it
		}
		if s.sweepRow(r, st, now) {
			changed = true
		}
	}
	if changed {
		_ = s.save()
	}
}

func (s *Service) sweepRow(r *Row, st map[string]map[string]bool, now time.Time) (changed bool) {
	audit := func(msg string) {
		s.logAudit(auditEntry{Host: "h005", Action: "sweep", Target: r.Service + "@" + r.Host, Result: "ok", Message: msg})
	}
	if r.State == Prepared && r.ReserveSince > 0 && now.Sub(time.Unix(r.ReserveSince, 0)) > ReserveTTL {
		if r.Previous != nil {
			before := r.Host
			r.Host, r.State, r.Previous = r.Previous.Host, Committed, nil
			r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = 0, 0, "", ""
			r.Updated = now.Unix()
			audit("reservation on " + before + " expired; kept " + r.Host)
		} else {
			audit("reservation on " + r.Host + " expired; dropped")
			delete(s.rows, r.Service)
		}
		return true
	}
	if s.cfg.Status == nil {
		return false
	}
	svcs, known := st[r.Host]
	if !known || svcs == nil {
		if msg := "unknown until " + r.Host + " answers"; r.LastError != msg {
			r.LastError = msg
			return true
		}
		return false
	}
	switch {
	case !svcs[r.Service]:
		if r.HostMissingSince == 0 {
			r.HostMissingSince = now.Unix()
			changed = true
		}
		if msg := "not running on " + r.Host; r.LastError != msg {
			r.LastError = msg
			changed = true
		}
	case r.HostMissingSince != 0 || r.LastError != "":
		r.HostMissingSince, r.LastError = 0, ""
		changed = true
	}
	// Split brain: any other host reporting the service. The previous host is
	// expected to report it until the move's source is retired.
	conflict := ""
	for h, s2 := range st {
		if h == r.Host || s2 == nil {
			continue
		}
		if r.Previous != nil && h == r.Previous.Host {
			continue
		}
		if s2[r.Service] {
			conflict = h
			break
		}
	}
	if r.Conflict != conflict {
		r.Conflict = conflict
		changed = true
		if conflict != "" {
			audit("split brain: also running on " + conflict)
		}
	}
	// The source stopped reporting the service: the rollback binding is gone.
	if r.Previous != nil && r.State != Prepared {
		if s2, k := st[r.Previous.Host]; k && s2 != nil && !s2[r.Service] {
			audit("source " + r.Previous.Host + " retired")
			r.Previous, r.State = nil, Committed
			r.Updated = now.Unix()
			changed = true
		}
	}
	return changed
}

// Verify is the live view for `cnt place --verify`: where each service is
// bound, what the host reports, and copies on a host that should not have one.
type Verify struct {
	Bound map[string]string `json:"bound"` // service -> ok|pending|missing|unreachable
	Stray map[string]string `json:"stray"` // service -> host running an unbound copy
	Error string            `json:"error,omitempty"`
}

func (s *Service) verify(ctx context.Context) Verify {
	v := Verify{Bound: map[string]string{}, Stray: map[string]string{}}
	st, errs := s.statuses(ctx, s.sortedRows())
	for _, r := range s.rows {
		if r.State == Prepared && r.Previous != nil {
			v.Bound[r.Service] = "pending"
			continue
		}
		svcs, known := st[r.Host]
		switch {
		case !known || svcs == nil:
			v.Bound[r.Service] = "unreachable"
		case !svcs[r.Service]:
			v.Bound[r.Service] = "missing"
		default:
			v.Bound[r.Service] = "ok"
		}
	}
	for h, svcs := range st {
		for svc := range svcs {
			r, ok := s.rows[svc]
			if !ok {
				if _, declared := s.cfg.Inventory.Services[svc]; declared {
					v.Stray[svc] = h
				}
				continue
			}
			if h != r.Host && (r.Previous == nil || h != r.Previous.Host) {
				v.Stray[svc] = h
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
