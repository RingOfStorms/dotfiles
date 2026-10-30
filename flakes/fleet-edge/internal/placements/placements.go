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
	"crypto/rand"
	"encoding/hex"
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

// ReserveTTL is the lease on a reservation. A move renews it as it advances;
// one that runs past it is not rolled back, because a slow move has already
// stopped its source and a rollback would route to a host that serves nothing.
// The reservation is fenced as Stale instead, and only an explicit recovery
// (which checks the hosts) or the lease holder renewing it ends that.
const ReserveTTL = 30 * time.Minute

// Row states.
const (
	Prepared  = "prepared"  // destination reserved; the source still serves
	Committed = "committed" // routing points at the destination
	Retiring  = "retiring"  // the source is being uninstalled
	// Stale: the reservation outlived its lease. Nothing is routed to the
	// destination because the commit never landed, the row stays fenced
	// (a second move is refused), and who serves is unknown until recover
	// reads the hosts. Sweeping does not resolve it.
	Stale = "stale"
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
	// ReserveSince: when the lease on the current reservation was last renewed;
	// a move renews it as it advances. Once it is older than ReserveTTL the row
	// is fenced as Stale (0 = committed).
	ReserveSince int64 `json:"reserveSince,omitempty"`
	// HostMissingSince: first sweep at which the bound host didn't report
	// the service (0 = reported, or not checked yet).
	HostMissingSince int64 `json:"hostMissingSince,omitempty"`
	// Token is the opaque handle the reserving client keeps: commit, retire,
	// rollback, recover and renew must present it, so a stale move cannot act on
	// a binding someone else has since reserved. While it is set the row is
	// fenced — a second reserve is refused whatever the state or lease age — and
	// it is cleared when the move ends (committed with nothing to retire, or the
	// source confirmed uninstalled).
	Token string `json:"token,omitempty"`
	// Revision is the row's incarnation: a number minted from the registry's
	// counter and replaced on every write, for compare-and-swap. A caller that
	// sends a stale revision is refused rather than clobbering a newer
	// decision. The counter is persisted apart from the rows, so a number is
	// never reissued — not even to a placement recreated after a delete.
	Revision int64 `json:"revision"`
	// Conflict names another host that also reports the service (split
	// brain). Never resolved automatically.
	Conflict  string `json:"conflict,omitempty"`
	LastError string `json:"lastError,omitempty"`
}

// Effective is the host that runs the service now: the destination only once
// the move is committed; while prepared the source still serves, and a first
// placement serves nowhere yet. A stale row claims nothing either way — nobody
// knows which copy answers until recover looks — so it reports nowhere and the
// dashboard shows the service as in doubt.
func (r *Row) Effective() string {
	switch r.State {
	case Prepared:
		if r.Previous != nil {
			return r.Previous.Host
		}
		return ""
	case Stale:
		return ""
	}
	return r.Host
}

// Config wires a Service.
type Config struct {
	Inventory *inventory.Inventory
	StateDir  string
	Auth      *authority.Auth // shared writer allowlist
	Status    HostServices    // nil: host checks are skipped
	Now       func() time.Time
	// Notify is called (under the registry lock, so it must not block) after
	// every write that changed the rows, so the routing reconciler cuts over
	// on commit instead of on its next tick. nil: nobody listens.
	Notify func()
}

// Service is the running registry.
type Service struct {
	cfg   Config
	auth  *authority.Auth
	mu    sync.Mutex
	rows  map[string]*Row // key: service
	rev   int64           // last revision issued; outlives the rows
	audit *os.File
	write func(string, []byte, os.FileMode) error // the state write; a test seam
}

// state is the on-disk shape: the rows plus the registry-wide revision
// counter. The counter is persisted because it is the one thing a row cannot
// carry: the delete that ends a placement mints nothing more, and the next row
// for the same service must not reuse the number the destroyed deployment
// still holds.
type state struct {
	Revision int64  `json:"revision"`
	Rows     []*Row `json:"rows"`
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
	s := &Service{cfg: cfg, auth: cfg.Auth, rows: map[string]*Row{}, write: os.WriteFile}
	b, err := os.ReadFile(s.statePath())
	if err == nil {
		st, err := decodeState(b)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", s.statePath(), err)
		}
		s.rev = st.Revision
		for _, r := range st.Rows {
			// A file without a counter (the bare-array format an earlier
			// version wrote) seeds it from the rows, so the numbering continues
			// past every number already handed out.
			if r.Revision > s.rev {
				s.rev = r.Revision
			}
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

// decodeState reads the state file, or the bare array an earlier version
// wrote. An array's revisions were not minted from a counter that outlives
// deletion, so they only seed it.
func decodeState(b []byte) (*state, error) {
	var st state
	err := json.Unmarshal(b, &st)
	if err == nil {
		return &st, nil
	}
	var rows []*Row
	if json.Unmarshal(b, &rows) == nil {
		return &state{Rows: rows}, nil
	}
	return nil, err
}

// stage is one write's working copy: a copy of the rows map (with the rows it
// touches cloned) and of the revision counter. Nothing is visible — not to the
// export, not to the next request, not to a restart — until commit persists it
// and swaps it in, so a write that cannot be saved leaves the registry exactly
// as it was instead of exposing a binding only this process believes in.
type stage struct {
	s    *Service
	rows map[string]*Row // a copy of s.rows; the rows it edits are clones
	rev  int64           // a copy of s.rev
}

func (s *Service) stage() *stage {
	rows := make(map[string]*Row, len(s.rows))
	for name, r := range s.rows {
		rows[name] = r
	}
	return &stage{s: s, rows: rows, rev: s.rev}
}

// edit is the stage's view of a row: a clone, so the live one is untouched
// until commit. The rollback binding is copied with it, since a reserve hands
// it on to the new row.
func (st *stage) edit(service string) *Row {
	r := st.rows[service]
	if r == nil {
		return nil
	}
	c := *r
	if r.Previous != nil {
		prev := *r.Previous
		c.Previous = &prev
	}
	st.rows[service] = &c
	return &c
}

// add puts a row that does not exist yet in the stage.
func (st *stage) add(r *Row) { st.rows[r.Service] = r }

// nextRev issues the next revision. It is minted from the registry rather than
// from the row, so a number is never reused: a delete that replays the
// revision of a destroyed placement cannot match its reincarnation.
func (st *stage) nextRev() int64 {
	st.rev++
	return st.rev
}

// persist writes the staged rows and counter and, only then, makes them the
// registry's. On failure nothing is assigned, so memory keeps holding the state
// a restart would load.
func (st *stage) persist() error {
	if err := st.s.saveState(st.rows, st.rev); err != nil {
		return err
	}
	st.s.rows, st.s.rev = st.rows, st.rev
	if st.s.cfg.Notify != nil {
		st.s.cfg.Notify()
	}
	return nil
}

// commit persists the stage and reports the row it made current. A failed
// write returns no row: the request did not happen, and the caller must not be
// handed a revision nothing holds.
func (st *stage) commit(r *Row) (*Row, error) {
	if err := st.persist(); err != nil {
		return nil, err
	}
	return r, nil
}

func (s *Service) statePath() string { return filepath.Join(s.cfg.StateDir, "placements.json") }

func (s *Service) saveState(rows map[string]*Row, rev int64) error {
	st := state{Revision: rev, Rows: sortedRows(rows)}
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.statePath() + ".new"
	if err := s.write(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.statePath())
}

func sortedRows(rows map[string]*Row) []*Row {
	out := make([]*Row, 0, len(rows))
	for _, r := range rows {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Service < out[j].Service })
	return out
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
	e := Export{Rows: sortedRows(s.rows), Host: map[string]string{}, Conflicts: map[string]string{}}
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

// Stale reports whether service's row is fenced: a move outlived its lease, so
// nobody knows which copy answers. Routing readers leave its names exactly as
// they are (the last answer stands) until recover settles it.
func (e Export) Stale(service string) bool {
	for _, r := range e.Rows {
		if r.Service == service {
			return r.State == Stale
		}
	}
	return false
}

// Placed reports whether service keeps its routing names: a host serves it
// now, or its row is fenced (see Stale). An unplaced service has no name.
func (e Export) Placed(service string) bool {
	return e.Host[service] != "" || e.Stale(service)
}

// Snapshot is the export for an in-process reader (the routing reconciler in
// the same unit): the same view as /internal/placements.json, with rows
// copied so the caller never shares memory with the registry.
func (s *Service) Snapshot() Export {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.export()
	for i, r := range e.Rows {
		c := *r
		if r.Previous != nil {
			p := *r.Previous
			c.Previous = &p
		}
		e.Rows[i] = &c
	}
	return e
}

// Request is the body of every placement operation. reserve, commit, retire,
// recover, renew and DELETE all take the same shape; the token is what ties
// them to one move.
type Request struct {
	Service string `json:"service,omitempty"`
	Host    string `json:"host,omitempty"`
	Reason  string `json:"reason,omitempty"`
	User    string `json:"user,omitempty"`
	// Token is the reservation handle returned by reserve. commit, retire,
	// rollback, recover and renew require it while a reservation exists: without
	// it an older move could finish or undo a binding a newer client now owns. A
	// handle from a move that has ended is refused, not treated as absent.
	Token string `json:"token,omitempty"`
	// Revision is the row incarnation the caller last saw, for compare-and-swap
	// on writes that carry no token (force, import adoption, a tokenless
	// DELETE). It is never reissued, so a revision read from a placement that
	// has since been deleted cannot match its replacement. 0 skips the check,
	// except on DELETE where it is the minimum evidence that the caller read
	// the row it is deleting.
	Revision int64 `json:"revision,omitempty"`
	// Force overrides a safety check the operator has verified by hand.
	Force bool `json:"force,omitempty"`
}

// Import is the one-time bootstrap body: the placements currently observed,
// so the registry starts from reality instead of from Nix. Token and Revision
// let a re-run adopt a row it already owns instead of colliding with it.
type Import struct {
	User       string      `json:"user,omitempty"`
	Reason     string      `json:"reason,omitempty"`
	Token      string      `json:"token,omitempty"`
	Revision   int64       `json:"revision,omitempty"`
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
		v := map[string]any{"rows": sortedRows(s.rows), "host": s.export().Host}
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
		req.Token, req.Revision = imp.Token, imp.Revision
	case r.Method == http.MethodPost && (rest == "reserve" || rest == "commit" || rest == "retire" || rest == "recover" || rest == "renew"):
		act = rest
		if err := decode(w, r, &req); err != nil {
			http.Error(w, "bad request: "+err.Error(), 400)
			return
		}
	case r.Method == http.MethodDelete && rest != "" && !strings.Contains(rest, "/"):
		// ?recover=1 settles a fenced reservation the way POST recover does;
		// the plain form is the rollback.
		act, req.Service = "delete", rest
		if r.URL.Query().Get("recover") == "1" {
			act = "recover"
		}
		req.User = r.URL.Query().Get("user")
		req.Token = r.URL.Query().Get("token")
		req.Force = r.URL.Query().Get("force") == "1"
		if rev := r.URL.Query().Get("revision"); rev != "" {
			// A tokenless delete names the revision it read, so it can only drop
			// the row it was composed against.
			n, err := strconv.ParseInt(rev, 10, 64)
			if err != nil || n <= 0 {
				http.Error(w, "bad request: revision must be a positive integer", 400)
				return
			}
			req.Revision = n
		}
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
		row, err = s.remove(req)
	case "recover":
		row, err = s.recover(req, c.Host)
	case "renew":
		row, err = s.renew(req)
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

// runsOn reports what host says about the service: whether it is installed and
// whether it is running. known is false when the host could not be asked, so
// callers never treat silence as absence. Serving needs both facts, so a copy
// that a move stopped is installed but not running.
func (s *Service) runsOn(ctx context.Context, host, service string) (st ServiceState, known bool) {
	if s.cfg.Status == nil {
		return ServiceState{}, false
	}
	svcs, err := s.cfg.Status(ctx, host)
	if err != nil {
		return ServiceState{}, false
	}
	return svcs[service], true
}

// newToken mints a reservation handle. It is random so a client cannot guess
// another's, and opaque so nothing may attach meaning to it.
func newToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("reservation token: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// fenced reports whether a move's token is still outstanding. Whatever the
// row's state or the age of its lease, a token means a client still owns the
// right to finish, roll back or recover this placement, so nobody else may
// reserve over it. The lease only decides *when* a Prepared row is announced as
// Stale (leaseExpired); it never frees the fence, because a move stops its
// source before it restores the destination and "expired" therefore does not
// mean "the source still serves". Committed and Retiring rows keep the token
// until the source's rollback binding is gone, so a second move cannot start
// while the first can still be undone.
func fenced(r *Row) bool { return r.Token != "" }

// leaseExpired reports whether a Prepared reservation has outlived its lease,
// i.e. whether the sweep should announce it as Stale. It does not release the
// fence: the token alone decides who may act (see fenced).
func leaseExpired(r *Row, now int64) bool {
	return r.State == Prepared && r.Token != "" && now-r.ReserveSince >= int64(ReserveTTL/time.Second)
}

// checkToken refuses a request that would finish, replace or undo a move it
// did not reserve. The token is an identity handle, not a secret: every writer
// can read it from the row, but only the client that made the move holds it,
// so a slow client cannot touch someone else's binding.
//
// A token nobody holds any more is refused too, even though the row has none:
// once the sweep clears it (the source was uninstalled), a late DELETE from the
// old move would otherwise drop the binding that move established. Ending a
// placement is then an explicit act — the row's revision as a CAS guard, or
// force.
func checkToken(r *Row, req Request, action string) error {
	if req.Force || req.Token == r.Token {
		// The matching cases: the holder acting again, or a tokenless write on a
		// row nobody reserved.
		return nil
	}
	if r.Token == "" {
		// The reservation this handle belonged to has ended — committed with
		// nothing to retire, recovered, or rolled back — so the handle must stop
		// working: the row now names a binding it never reserved, and a DELETE
		// carrying it would drop or move the live placement.
		return fail(409, "%s: %s refused: the reservation this token belongs to has ended (re-read the row, or force)", r.Service, action)
	}
	return fail(409, "%s: %s refused: %s's move to %s owns the reservation (present its token, or force)", r.Service, action, r.Device, r.Host)
}

// checkRevision refuses a tokenless write built on a stale read: the caller
// echoes the revision it acted on, so it cannot overwrite a decision made
// since. The number is minted from a counter that outlives the row, so it also
// cannot outlive the placement: a replayed revision from a deleted row is
// stale against whatever holds that name now, not equal to it.
func checkRevision(r *Row, rev int64, force bool) error {
	if force || rev == 0 || rev == r.Revision {
		return nil
	}
	return fail(409, "%s: changed since revision %d (now %d): re-read and retry", r.Service, rev, r.Revision)
}

// reserve prepares a placement: the destination is recorded (with the prior
// binding, if any) but nothing is routed to it yet. The source keeps serving
// until commit, so this is safe to run before stopping anything.
//
// An accepted reserve mints a token, which every later step of the same move
// must present. That is what keeps two interleaved moves apart: the second
// reserve is refused while the first holds the reservation, and the client that
// lost then cannot commit or roll back the binding the other one owns. Repeating
// the call with the same token and destination renews the lease, which is how a
// move that legitimately runs longer than ReserveTTL stays in charge of it.
func (s *Service) reserve(req Request, dev string) (*Row, error) {
	if err := s.checkService(req.Service); err != nil {
		return nil, err
	}
	if err := s.checkHost(req.Host); err != nil {
		return nil, err
	}
	now := s.cfg.Now().Unix()
	cur := s.rows[req.Service]
	// A reserve carries the identity of the move it belongs to: a token, or the
	// revision it read. On an existing row both are checked whether or not the
	// row still carries a token, because the token is the handle of the move
	// that made the binding and the revision is the compare-and-swap for writes
	// that carry none. Acting with either that the row has moved past would
	// start a new move against a binding the caller never reserved — including
	// the delayed reserve, which arrives after the sweep cleared the token.
	//
	// With no row at all, a handle can only name a placement that has since
	// been removed: a caller composing the *first* placement of a service has
	// nothing to present. Honouring the handle there would let a replay of an
	// old reserve bring a deleted placement back.
	//
	// force overrides all of it and mints a new token, invalidating the old.
	if cur == nil {
		if !req.Force && (req.Token != "" || req.Revision != 0) {
			return nil, fail(409, "%s: no placement; this request belongs to one that was removed (force to place it anew)", req.Service)
		}
	} else {
		if err := checkToken(cur, req, "reserve"); err != nil {
			return nil, err
		}
		if err := checkRevision(cur, req.Revision, req.Force); err != nil {
			return nil, err
		}
	}
	if cur != nil && cur.Host == req.Host {
		if cur.State != Prepared && cur.State != Stale {
			return nil, fail(409, "%s is already placed on %s", req.Service, req.Host)
		}
		w := s.stage()
		r := w.edit(req.Service)
		// A retried reserve from the client that made the move keeps its token.
		// A takeover mints a new one, which is what invalidates the old
		// holder's handle and stops it committing or rolling back afterwards.
		if req.Token != r.Token {
			tok, err := newToken()
			if err != nil {
				return nil, err
			}
			r.Token = tok
		}
		// Presenting the row's own token is a renewal, and a renewal also lifts
		// a stale fence: the client is proving it is still driving the move.
		r.State = Prepared
		r.Device, r.User, r.Reason, r.Updated, r.ReserveSince = dev, req.User, req.Reason, now, now
		r.Revision = w.nextRev()
		return w.commit(r)
	}
	// A move onto a host that already runs the service would leave two copies
	// with one name. A first placement has no prior binding to duplicate.
	if cur != nil && !req.Force {
		if st, known := s.runsOn(context.Background(), req.Host, req.Service); known && st.Running() {
			return nil, fail(409, "%s already runs on %s: a second copy would split it (force if that copy is the one to keep)", req.Service, req.Host)
		}
	}
	w := s.stage()
	r := w.edit(req.Service)
	var prev *Binding
	if r != nil {
		switch r.State {
		case Prepared, Stale:
			// An abandoned destination is not a rollback target: keep the
			// last committed binding instead. A stale row's destination is
			// half-restored, never a place to come back to. The staged row
			// holds its own copy of it.
			prev = r.Previous
		default:
			prev = &Binding{Host: r.Host}
		}
	}
	if r == nil {
		r = &Row{Service: req.Service, Created: now}
		w.add(r)
	}
	r.Host, r.State, r.Previous = req.Host, Prepared, prev
	r.Device, r.User, r.Reason = dev, req.User, req.Reason
	r.Updated, r.ReserveSince = now, now
	r.HostMissingSince, r.Conflict, r.LastError = 0, "", ""
	tok, err := newToken()
	if err != nil {
		return nil, err
	}
	r.Token, r.Revision = tok, w.nextRev()
	return w.commit(r)
}

// commit records that routing (DNS and o002) points at the destination. The
// destination must report the service unless it cannot be asked. The token is
// kept while a rollback binding remains, because retire and rollback belong to
// the same move.
func (s *Service) commit(req Request, dev string) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement to commit", req.Service)
	}
	// A fenced reservation cannot drift into a commit: the lease is gone, so
	// the move's own progress is not evidence that the destination finished
	// restoring. Renewing (another reserve with the same token) clears the
	// fence; otherwise the operator resolves it with --recover or force.
	if r.State == Stale && !req.Force {
		return nil, fail(409, "%s: the reservation on %s expired and is fenced (renew the lease, or --recover to settle it)", req.Service, r.Host)
	}
	if r.State != Prepared && r.State != Stale {
		return nil, fail(409, "%s is not prepared (state %s)", req.Service, r.State)
	}
	if req.Host != "" && req.Host != r.Host {
		return nil, fail(409, "%s is reserved for %s, not %s", req.Service, r.Host, req.Host)
	}
	// Only the client that reserved may commit: a stale client would otherwise
	// bind a destination someone else chose.
	if err := checkToken(r, req, "commit"); err != nil {
		return nil, err
	}
	if err := checkRevision(r, req.Revision, req.Force); err != nil {
		return nil, err
	}
	// The destination must be serving the copy: installed *and* active. An
	// installed unit that is stopped is not ready to take the name.
	if st, known := s.runsOn(context.Background(), r.Host, r.Service); known && !st.Running() {
		return nil, fail(409, "%s does not report %s yet: deploy and start it there first", r.Host, req.Service)
	}
	w := s.stage()
	r = w.edit(req.Service)
	r.State, r.Updated, r.ReserveSince, r.Device = Committed, s.cfg.Now().Unix(), 0, dev
	if r.Previous == nil {
		r.Token = "" // nothing to retire or roll back: the move is over
	}
	r.Revision = w.nextRev()
	return w.commit(r)
}

// retire records that the source is being uninstalled: its data is renamed, so
// a rollback onto it is no longer free. The previous binding is kept until the
// sweep sees the source stop reporting the service.
func (s *Service) retire(req Request, dev string) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement", req.Service)
	}
	if err := checkToken(r, req, "retire"); err != nil {
		return nil, err
	}
	if err := checkRevision(r, req.Revision, req.Force); err != nil {
		return nil, err
	}
	if r.State == Stale {
		return nil, fail(409, "%s: the reservation expired and is fenced: recover it before retiring the source", req.Service)
	}
	if r.State == Prepared {
		return nil, fail(409, "%s is still prepared: commit the move first", req.Service)
	}
	if r.Previous == nil {
		return r, nil // something else already retired it
	}
	w := s.stage()
	r = w.edit(req.Service)
	r.State, r.Updated, r.Device = Retiring, s.cfg.Now().Unix(), dev
	r.Revision = w.nextRev()
	return w.commit(r)
}

// remove rolls the placement back to its prior binding, or drops the row when
// there is none. A single placement (no prior binding) is simply deleted.
func (s *Service) remove(req Request) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, nil
	}
	if err := checkToken(r, req, "rollback"); err != nil {
		return nil, err
	}
	// Ending a placement is never implicit. A token proves the caller owns the
	// move it is undoing; without one the caller must name the revision it read,
	// so the delete can only drop the row it was composed against.
	if req.Token == "" && req.Revision == 0 && !req.Force {
		return nil, fail(409, "%s: a delete needs the reservation token, the revision it read (?revision=%d), or force", req.Service, r.Revision)
	}
	if err := checkRevision(r, req.Revision, req.Force); err != nil {
		return nil, err
	}
	if r.State == Stale && !req.Force {
		// A fenced reservation cannot be rolled back by assumption: the move may
		// have stopped its source, and restoring the previous binding blind is
		// the very thing the fence exists to prevent.
		return nil, fail(409, "%s: the reservation expired and is fenced: recover it (that checks the hosts)", req.Service)
	}
	if r.Previous != nil && r.State == Retiring && !req.Force {
		return nil, fail(409, "%s's source was retired: %s no longer has its data (force to record it anyway)", req.Service, r.Previous.Host)
	}
	w := s.stage()
	if r.Previous == nil {
		delete(w.rows, req.Service)
		return w.commit(nil)
	}
	r = w.edit(req.Service)
	r.Host, r.State, r.Previous, r.Token = r.Previous.Host, Committed, nil, ""
	r.Updated, r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = s.cfg.Now().Unix(), 0, 0, "", ""
	r.Revision = w.nextRev()
	return w.commit(r)
}

// recover settles a reservation that outlived its lease. The sweep cannot do
// it: only the hosts know whether the move's stop-and-restore actually landed,
// and a rollback that guesses wrong points the name at a host that is not
// serving. So this asks both ends and acts on the answer:
//
//   - a host that did not answer: nothing is decided, since the silent end is
//     the one that could still be serving;
//   - destination and source both serving: the source never stopped, so the
//     move left two live copies of one name — refuse and name both;
//   - destination serving: the move did land, record the commit;
//   - source serving: the move never cut over, restore the previous binding;
//   - source installed but stopped: it is mid-move, so refuse and say so;
//   - neither serving: refuse unless forced, since nothing would answer.
//
// Two running copies are the case this must never guess at: recording the
// destination strands the source, restoring the source strands the destination.
// Only force picks one, and it restores the previous binding.
//
// The token (or force) is required: recovery is the holder's decision, not
// whoever notices the arrow is stale.
func (s *Service) recover(req Request, dev string) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement to recover", req.Service)
	}
	if r.State != Stale {
		return nil, fail(409, "%s is not fenced (state %s)", req.Service, r.State)
	}
	if err := checkToken(r, req, "recover"); err != nil {
		return nil, err
	}
	now := s.cfg.Now().Unix()
	dest, destKnown := s.runsOn(context.Background(), r.Host, r.Service)
	var src ServiceState
	srcKnown := r.Previous == nil
	if r.Previous != nil {
		src, srcKnown = s.runsOn(context.Background(), r.Previous.Host, r.Service)
	}
	if !req.Force && (!destKnown || !srcKnown) {
		// A silent end may still be serving, so the answering one proves nothing
		// about the cutover.
		return nil, fail(409, "%s: cannot tell what the move did (a host did not answer): check both hosts, then force", req.Service)
	}
	if !req.Force && r.Previous != nil && dest.Running() && src.Running() {
		// Both ends serve: the move stopped short of a clean cutover, so either
		// binding would leave the other copy answering on the same name.
		return nil, fail(409, "%s: both %s and %s report it running, so the move did not cut over cleanly: stop one, then recover (force to restore %s)", req.Service, r.Host, r.Previous.Host, r.Previous.Host)
	}
	if !req.Force && dest.Running() {
		// The destination is the only copy serving: the copy is there, which is
		// exactly what commit would have recorded.
		w := s.stage()
		r = w.edit(req.Service)
		r.State, r.Updated, r.ReserveSince, r.Device = Committed, now, 0, dev
		if r.Previous == nil {
			r.Token = ""
		}
		r.HostMissingSince, r.Conflict, r.LastError = 0, "", ""
		r.Revision = w.nextRev()
		return w.commit(r)
	}
	if !req.Force {
		switch {
		case src.Running():
			w := s.stage()
			r = w.edit(req.Service)
			r.Host, r.State, r.Previous, r.Token = r.Previous.Host, Committed, nil, ""
			r.Updated, r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = now, 0, 0, "", ""
			r.Revision = w.nextRev()
			return w.commit(r)
		case src.Installed:
			return nil, fail(409, "%s: the source %s is installed but stopped, so the move is still in flight: let it finish and commit (force to decide anyway)", req.Service, r.Previous.Host)
		case r.Previous != nil:
			return nil, fail(409, "%s: neither %s nor %s reports it: nothing would answer (force to restore %s)", req.Service, r.Host, r.Previous.Host, r.Previous.Host)
		default:
			return nil, fail(409, "%s: %s does not report it, so the first placement never landed: deploy and start it there, then commit (force to record it anyway)", req.Service, r.Host)
		}
	}
	// Forced: restore the prior binding, or commit the destination when the
	// reservation was a first placement with nothing to go back to.
	w := s.stage()
	r = w.edit(req.Service)
	if r.Previous != nil {
		r.Host, r.State, r.Previous, r.Token = r.Previous.Host, Committed, nil, ""
	} else {
		r.State, r.Token = Committed, ""
	}
	r.Updated, r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = now, 0, 0, "", ""
	r.Revision = w.nextRev()
	return w.commit(r)
}

// renew extends the lease on a reservation the caller still holds. A move that
// legitimately runs past ReserveTTL (a large service takes a while to back up,
// transfer and restore) calls this between steps instead of being fenced
// halfway. It changes no placement: only the clock.
func (s *Service) renew(req Request) (*Row, error) {
	r := s.rows[req.Service]
	if r == nil {
		return nil, fail(404, "%s: no placement to renew", req.Service)
	}
	if err := checkToken(r, req, "renew"); err != nil {
		return nil, err
	}
	if req.Token == "" {
		return nil, fail(409, "%s: renew needs the reservation token", req.Service)
	}
	if r.State == Stale {
		// A lapsed lease is not silently re-armed: the fence exists because the
		// move's progress is unknown, so settling it is recover's job. Repeating
		// the reserve with the token re-opens the lease if the move still runs.
		return nil, fail(409, "%s: the reservation expired and is fenced: recover it, or reserve again with its token", req.Service)
	}
	if r.State != Prepared {
		return nil, fail(409, "%s holds no reservation (state %s)", req.Service, r.State)
	}
	now := s.cfg.Now().Unix()
	w := s.stage()
	r = w.edit(req.Service)
	r.ReserveSince, r.Updated = now, now
	r.Revision = w.nextRev()
	return w.commit(r)
}

// importRows adopts observed placements. It is the one-time bootstrap, not a
// deploy path: an existing row is kept unless force. A live reservation is
// honoured too: adopting a row a move owns would strand that move's token, so
// the import is refused unless it carries the token or force.
//
// Only a *serving* copy is adopted. An entry whose host reports the unit
// installed but stopped, or reports nothing at all, is skipped rather than
// imported: a stale copy left behind by an old move must not become the
// binding. That is also what makes "no row and no running copy" mean
// unowned/offline instead of quietly pointing at a dead host.
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
	for _, p := range imp.Placements {
		r, ok := s.rows[p.Service]
		if !ok {
			continue
		}
		if fenced(r) && !imp.Force && imp.Token != r.Token {
			return nil, fail(409, "%s: a move to %s owns the reservation: commit it, roll it back, or --recover it first", p.Service, r.Host)
		}
		if err := checkRevision(r, imp.Revision, imp.Force); err != nil {
			return nil, err
		}
	}
	imported, skipped := []string{}, []string{}
	w := s.stage()
	for _, p := range imp.Placements {
		if r, ok := s.rows[p.Service]; ok && !imp.Force {
			skipped = append(skipped, p.Service+" on "+r.Host)
			continue
		}
		if why := s.adoptable(context.Background(), p); why != "" {
			skipped = append(skipped, p.Service+" on "+p.Host+" ("+why+")")
			continue
		}
		r := w.edit(p.Service)
		if r == nil {
			r = &Row{Service: p.Service, Created: now}
			w.add(r)
		}
		r.Host, r.State, r.Previous = p.Host, Committed, nil
		r.Device, r.User, r.Reason, r.Updated = dev, imp.User, imp.Reason, now
		r.ReserveSince, r.HostMissingSince, r.Conflict, r.LastError = 0, 0, "", ""
		r.Token, r.Revision = "", w.nextRev()
		imported = append(imported, p.Service+" on "+p.Host)
	}
	out := map[string]any{"imported": imported, "skipped": skipped}
	if err := w.persist(); err != nil {
		return nil, err
	}
	return out, nil
}

// adoptable says why an observed placement must not be adopted, or "" when the
// copy is confirmed serving. With no status source there is nothing to ask, and
// the caller's own discovery is the only evidence there is.
func (s *Service) adoptable(ctx context.Context, p Placement) string {
	if s.cfg.Status == nil {
		return ""
	}
	st, known := s.runsOn(ctx, p.Host, p.Service)
	switch {
	case !known:
		return "did not answer"
	case st.Running():
		return ""
	case st.Installed:
		return "installed but not running"
	default:
		return "not installed"
	}
}

// ---------------------------------------------------------------- host status

// statuses asks every host that could matter (all container hosts, plus any
// host a row names) what it has installed and whether it runs. A nil map means
// the host did not answer; an empty one means it answered and has nothing.
func (s *Service) statuses(ctx context.Context, rows []*Row) (map[string]map[string]ServiceState, []string) {
	out := map[string]map[string]ServiceState{}
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

// Sweep reconciles rows with host status: a reservation past its lease is
// fenced as stale (never rolled back), drift and split brain are recorded (never
// auto-resolved), a confirmed uninstall drops the rollback binding. Unreachable
// hosts change nothing.
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
	w := s.stage()
	type note struct{ target, msg string }
	var notes []note
	changed := false
	for _, before := range snap {
		cur, ok := s.rows[before.Service]
		if !ok || cur.Host != before.Host || cur.State != before.State || cur.Token != before.Token {
			continue // changed under us: the mutating request owns it
		}
		r := w.edit(before.Service)
		target := r.Service + "@" + r.Host
		msgs, swept := s.sweepRow(w, r, st, now)
		if !swept {
			continue
		}
		changed = true
		for _, m := range msgs {
			notes = append(notes, note{target, m})
		}
	}
	if !changed {
		return
	}
	if err := w.persist(); err != nil {
		// The batch stays invisible: the rows keep the state a restart would
		// load, and the audit below is not written for changes nobody has.
		log.Printf("placements: sweep: %v", err)
		return
	}
	for _, n := range notes {
		s.logAudit(auditEntry{Host: "h005", Action: "sweep", Target: n.target, Result: "ok", Message: n.msg})
	}
}

// sweepRow reconciles one staged row against host status. The messages it
// returns are audited by the caller, and only once the batch is persisted: a
// sweep that cannot save has observed nothing the registry believes.
func (s *Service) sweepRow(w *stage, r *Row, st map[string]map[string]ServiceState, now time.Time) (msgs []string, changed bool) {
	audit := func(msg string) { msgs = append(msgs, msg) }
	if leaseExpired(r, now.Unix()) {
		// The move outlived its lease. Do not roll back: a slow move stops its
		// source before it restores the destination, so restoring the previous
		// binding here would route the name at a host that is not serving. The
		// row stays fenced (its token still blocks a second move) and claims no
		// effective host; recover settles it by asking both hosts.
		r.State = Stale
		r.Updated, r.Revision = now.Unix(), w.nextRev()
		r.HostMissingSince, r.Conflict, r.LastError = 0, "", ""
		audit("reservation on " + r.Host + " outlived its lease without cutting over; fenced until recover")
		return msgs, true
	}
	if s.cfg.Status == nil {
		return nil, false
	}
	svcs, known := st[r.Host]
	if !known || svcs == nil {
		if msg := "unknown until " + r.Host + " answers"; r.LastError != msg {
			r.LastError = msg
			return msgs, true
		}
		return nil, false
	}
	// Health needs the copy to be serving: installed and active. A stopped copy
	// is a placement that is not up, not an absent one.
	if !svcs[r.Service].Running() {
		if r.HostMissingSince == 0 {
			r.HostMissingSince = now.Unix()
			changed = true
		}
		if msg := "not running on " + r.Host; r.LastError != msg {
			r.LastError = msg
			changed = true
		}
	} else if r.HostMissingSince != 0 || r.LastError != "" {
		r.HostMissingSince, r.LastError = 0, ""
		changed = true
	}
	// Split brain: another host *serving* the service. A move stops its source
	// before it commits, so a source still serving while the destination serves
	// too is not the middle of a healthy move: the cutover never happened and
	// both copies answer on one name. A source that serves alone is the normal
	// mid-move state (the rollback binding is still live), and a copy the
	// previous host has stopped is not splitting anything.
	destRunning := svcs[r.Service].Running()
	conflict := ""
	for h, s2 := range st {
		if h == r.Host || s2 == nil || !s2[r.Service].Running() {
			continue
		}
		if r.Previous != nil && h == r.Previous.Host && !destRunning {
			continue
		}
		conflict = h
		break
	}
	if r.Conflict != conflict {
		r.Conflict = conflict
		changed = true
		if conflict != "" {
			audit("split brain: also running on " + conflict)
		}
	}
	// The source is *uninstalled*: the rollback binding is gone, and with it
	// the move's token, since there is nothing left to undo. A stopped but
	// installed source is exactly the state a move leaves it in before the
	// uninstall, so it must keep the binding.
	// A fenced row is exempt: an uninstalled source there does not prove the
	// move landed, so it waits for recover like everything else about it.
	if r.Previous != nil && r.State != Prepared && r.State != Stale {
		if s2, k := st[r.Previous.Host]; k && s2 != nil && !s2[r.Service].Installed {
			audit("source " + r.Previous.Host + " retired")
			r.Previous, r.State, r.Token = nil, Committed, ""
			r.Revision = w.nextRev()
			r.Updated = now.Unix()
			changed = true
		}
	}
	return msgs, changed
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
	st, errs := s.statuses(ctx, sortedRows(s.rows))
	for _, r := range s.rows {
		if r.State == Stale {
			// Neither host is authoritative: the move stopped short of a
			// commit, so what answers is whatever the hosts report next.
			v.Bound[r.Service] = "stale"
			continue
		}
		if r.State == Prepared && r.Previous != nil {
			v.Bound[r.Service] = "pending"
			continue
		}
		svcs, known := st[r.Host]
		switch {
		case !known || svcs == nil:
			v.Bound[r.Service] = "unreachable"
		case !svcs[r.Service].Running():
			v.Bound[r.Service] = "missing"
		default:
			v.Bound[r.Service] = "ok"
		}
	}
	// Only a *serving* copy somewhere it should not be counts: an installed but
	// stopped unit is a leftover for the operator to uninstall, not a copy that
	// answers on the name. The move's own rollback copy is expected to serve
	// while the destination does not; once both serve it is a stray like any
	// other, which is the same split brain the sweep flags.
	for h, svcs := range st {
		for svc, s2 := range svcs {
			if !s2.Running() {
				continue
			}
			r, ok := s.rows[svc]
			if !ok {
				if _, declared := s.cfg.Inventory.Services[svc]; declared {
					v.Stray[svc] = h
				}
				continue
			}
			if h == r.Host {
				continue
			}
			if r.Previous != nil && h == r.Previous.Host && !st[r.Host][svc].Running() {
				continue
			}
			v.Stray[svc] = h
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
