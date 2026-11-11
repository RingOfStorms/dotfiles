// Package backup is h005's backup policy authority (containers/BACKUP-PLAN.md
// §2.3, P2): per-subject policy rows, target registration and stats, and
// queued *clear* requests that only the holding target executes.
//
// Three allowlists (internal/authority, each a sub and overlay-IP pair):
//   - writers: PUT policy, PUT target enable, POST clear, GET everything;
//   - targets: POST their own record (heartbeat), GET everything (prune
//     needs every repo's preset);
//   - readers: GET /api/backup/<subject> for subjects placed on them (or
//     declared as their host subjects) only.
//
// State lives in backup.json and backup-targets.json (0600, atomic) next to
// placements; every request is one backup-audit.log line. fleet-edge never
// runs restic.
package backup

import (
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
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
)

// StaleAfter is how old a target heartbeat may be before the target cannot
// be selected.
const StaleAfter = time.Hour

// None is the target of a turned-off subject.
const None = "none"

// Default is the fallback policy row's subject.
const Default = "default"

// Presets are the `restic forget` arguments per retention preset (§2.3).
var Presets = map[string][]string{
	"short":    {"--keep-daily", "3", "--keep-weekly", "2", "--keep-monthly", "1"},
	"standard": {"--keep-daily", "7", "--keep-weekly", "5", "--keep-monthly", "12", "--keep-yearly", "3"},
	"long":     {"--keep-daily", "14", "--keep-weekly", "8", "--keep-monthly", "24", "--keep-yearly", "5"},
}

var subjectRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

// Stats is a target's view of one subject repo. Pointers: absent is not 0.
type Stats struct {
	LocalBytes *int64 `json:"localBytes,omitempty"`
	B2Bytes    *int64 `json:"b2Bytes,omitempty"`
	LastBackup int64  `json:"lastBackup,omitempty"`
	LastCopied int64  `json:"lastCopied,omitempty"`
	Complete   *bool  `json:"complete,omitempty"`
	At         int64  `json:"at,omitempty"`
	WrittenBy  string `json:"writtenBy,omitempty"`
}

// Target is one registered backup target.
type Target struct {
	ID         string           `json:"id"`
	URL        string           `json:"url"`
	Pusher     bool             `json:"pusher"`
	Enabled    bool             `json:"enabled"`
	DeclaredBy string           `json:"declaredBy"`
	Seen       int64            `json:"seen"`
	Stats      map[string]Stats `json:"stats,omitempty"`
	// Applied is the REST password revision per subject this target reports
	// it has rendered into its htpasswd.
	Applied map[string]int64 `json:"applied,omitempty"`
}

// Stale reports whether the last heartbeat is older than StaleAfter.
func (t *Target) Stale(now time.Time) bool { return now.Sub(time.Unix(t.Seen, 0)) > StaleAfter }

// Clear is a queued repo deletion, executed by the holding target.
type Clear struct {
	Scope       string `json:"scope"`
	Target      string `json:"target"`
	By          string `json:"by"`
	RequestedAt int64  `json:"requestedAt"`
	// Done lists scopes the target reported finished ("local", "b2").
	Done []string `json:"done,omitempty"`
}

// Row is one subject's policy.
type Row struct {
	Subject        string `json:"subject"`
	Target         string `json:"target"`
	Offsite        bool   `json:"offsite"`
	RetentionLocal string `json:"retentionLocal"`
	RetentionB2    string `json:"retentionB2"`
	Revision       int64  `json:"revision"`
	By             string `json:"by,omitempty"`
	At             int64  `json:"at,omitempty"`
	Clear          *Clear `json:"clear,omitempty"`
}

func defaultRow() *Row {
	return &Row{Subject: Default, Target: None, RetentionLocal: "standard", RetentionB2: "local"}
}

// Config wires the service.
type Config struct {
	StateDir string
	Writers  *authority.Auth
	Targets  *authority.Auth
	Readers  *authority.Auth
	// Subjects lists the valid subject names (services and host subjects).
	Subjects func() []string
	// Owns reports whether host may read subject (placement or host subject).
	Owns func(host, subject string) bool
	// Placement is the live binding of subject: the committed host (or the
	// owning host of a host subject) and the destination of an in-flight
	// move ("" for none). It gates credential fetches and, on change of the
	// committed host, rotates the REST password.
	Placement func(subject string) (host, pending string)
	Now       func() time.Time
}

// Service is the authority.
type Service struct {
	cfg     Config
	mu      sync.Mutex
	rows    map[string]*Row
	targets map[string]*Target
	rev     int64
	audit   *os.File
	// auditNote is extra text for the current request's audit line (mu held).
	auditNote string
	creds     *credsFile
}

type rowsFile struct {
	Revision int64  `json:"revision"`
	Rows     []*Row `json:"rows"`
}

// New loads state and opens the audit log.
func New(cfg Config) (*Service, error) {
	if cfg.Writers == nil || cfg.Targets == nil || cfg.Readers == nil {
		return nil, errors.New("backup: writers, targets and readers are required")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Subjects == nil {
		cfg.Subjects = func() []string { return nil }
	}
	if cfg.Owns == nil {
		cfg.Owns = func(string, string) bool { return false }
	}
	if cfg.Placement == nil {
		cfg.Placement = func(string) (string, string) { return "", "" }
	}
	s := &Service{cfg: cfg, rows: map[string]*Row{}, targets: map[string]*Target{}, creds: &credsFile{}}
	var rf rowsFile
	if err := readJSON(filepath.Join(cfg.StateDir, "backup.json"), &rf); err != nil {
		return nil, err
	}
	s.rev = rf.Revision
	for _, r := range rf.Rows {
		s.rows[r.Subject] = r
	}
	if s.rows[Default] == nil {
		s.rows[Default] = defaultRow()
	}
	var ts []*Target
	if err := readJSON(filepath.Join(cfg.StateDir, "backup-targets.json"), &ts); err != nil {
		return nil, err
	}
	for _, t := range ts {
		s.targets[t.ID] = t
	}
	if err := readJSON(s.credsPath(), s.creds); err != nil {
		return nil, err
	}
	if s.creds.Creds == nil {
		s.creds.Creds = map[string]*Cred{}
	}
	var err error
	s.audit, err = os.OpenFile(filepath.Join(cfg.StateDir, "backup-audit.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func writeAtomic(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".backup-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
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
	return os.Rename(tmp.Name(), path)
}

func (s *Service) sortedRows() []*Row {
	out := make([]*Row, 0, len(s.rows))
	for _, r := range s.rows {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Subject < out[j].Subject })
	return out
}

func (s *Service) sortedTargets() []*Target {
	out := make([]*Target, 0, len(s.targets))
	for _, t := range s.targets {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (s *Service) saveRows() error {
	return writeAtomic(filepath.Join(s.cfg.StateDir, "backup.json"), rowsFile{Revision: s.rev, Rows: s.sortedRows()})
}

func (s *Service) saveTargets() error {
	return writeAtomic(filepath.Join(s.cfg.StateDir, "backup-targets.json"), s.sortedTargets())
}

// TargetView is a target as exported, with staleness computed.
type TargetView struct {
	Target
	Stale bool `json:"stale"`
}

// Export is the full view (writers, targets, loopback dashboard).
type Export struct {
	Now      int64               `json:"now"`
	Rows     []*Row              `json:"rows"`
	Targets  []TargetView        `json:"targets"`
	Presets  map[string][]string `json:"presets"`
	Subjects []string            `json:"subjects"`
}

func (s *Service) export() Export {
	now := s.cfg.Now()
	e := Export{Now: now.Unix(), Rows: s.sortedRows(), Presets: Presets}
	for _, t := range s.sortedTargets() {
		e.Targets = append(e.Targets, TargetView{Target: *t, Stale: t.Stale(now)})
	}
	subs := append([]string(nil), s.cfg.Subjects()...)
	sort.Strings(subs)
	e.Subjects = subs
	return e
}

// Snapshot is the full view, for in-process callers.
func (s *Service) Snapshot() Export {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.export()
}

// effective is subject's row or the default row (with Subject set).
func (s *Service) effective(subject string) Row {
	if r := s.rows[subject]; r != nil {
		return *r
	}
	r := *s.rows[Default]
	r.Subject, r.Revision, r.Clear = subject, 0, nil
	return r
}

// Resolved is what a client reads for one subject; it never carries offsite.
type Resolved struct {
	Subject        string `json:"subject"`
	Target         string `json:"target"`
	URL            string `json:"url,omitempty"`
	Repo           string `json:"repo,omitempty"`
	RetentionLocal string `json:"retentionLocal"`
	Revision       int64  `json:"revision"`
	// Unavailable explains a target that cannot be used now (unknown,
	// disabled or stale); the client then falls back to its cache.
	Unavailable string `json:"unavailable,omitempty"`
}

func (s *Service) resolve(subject string) Resolved {
	r := s.effective(subject)
	out := Resolved{Subject: subject, Target: r.Target, RetentionLocal: r.RetentionLocal, Revision: r.Revision}
	if r.Target == None {
		return out
	}
	t := s.targets[r.Target]
	switch {
	case t == nil:
		out.Unavailable = "unknown target"
		return out
	case !t.Enabled:
		out.Unavailable = "target disabled"
	case t.Stale(s.cfg.Now()):
		out.Unavailable = "target stale"
	}
	out.URL = t.URL
	out.Repo = strings.TrimRight(t.URL, "/") + "/svc-" + subject + "/"
	return out
}

type auditEntry struct {
	TS      string `json:"ts"`
	Host    string `json:"host,omitempty"`
	Role    string `json:"role,omitempty"`
	Sub     string `json:"sub,omitempty"`
	User    string `json:"user,omitempty"`
	Peer    string `json:"peer,omitempty"`
	Action  string `json:"action"`
	Code    int    `json:"code"`
	Message string `json:"message,omitempty"`
}

func (s *Service) logAudit(e auditEntry) {
	e.TS = s.cfg.Now().UTC().Format(time.RFC3339)
	b, _ := json.Marshal(e)
	log.Printf("backup audit %s", b)
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

// Handler serves /api/backup* (behind h005 nginx) and the loopback-only
// /internal/backup.json export.
func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/backup.json", s.handleExport)
	mux.HandleFunc("/api/backup", s.handleAPI)
	mux.HandleFunc("/api/backup/", s.handleAPI)
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

// Roles, in precedence order.
const (
	roleWriter = "writer"
	roleTarget = "target"
	roleReader = "reader"
)

func (s *Service) authenticate(r *http.Request) (authority.Caller, string, error) {
	var first error
	for _, a := range []struct {
		role string
		au   *authority.Auth
	}{{roleWriter, s.cfg.Writers}, {roleTarget, s.cfg.Targets}, {roleReader, s.cfg.Readers}} {
		c, err := a.au.Authenticate(r)
		if err == nil {
			return c, a.role, nil
		}
		if first == nil {
			first = err
		}
		// A token used from the wrong peer is refused outright, never
		// retried against a lesser list.
		if c.Host != "" {
			return c, "", err
		}
	}
	return authority.Caller{}, "", first
}

func decode(w http.ResponseWriter, r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return fail(400, "bad body: %v", err)
	}
	return nil
}

func (s *Service) handleAPI(w http.ResponseWriter, r *http.Request) {
	c, role, err := s.authenticate(r)
	act := r.Method + " " + r.URL.Path
	if err != nil {
		s.logAudit(auditEntry{Host: c.Host, Sub: c.Sub, Peer: c.Peer, Action: act, Code: 401, Message: err.Error()})
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.auditNote = ""
	out, err := s.route(r, w, c, role)
	e := auditEntry{Host: c.Host, Role: role, Sub: c.Sub, Peer: c.Peer, Action: act, Code: 200, Message: s.auditNote}
	if err != nil {
		var he *httpErr
		if !errors.As(err, &he) {
			he = &httpErr{500, err.Error()}
		}
		e.Code, e.Message = he.code, he.msg
		s.logAudit(e)
		writeJSON(w, he.code, map[string]any{"error": he.msg})
		return
	}
	s.logAudit(e)
	writeJSON(w, 200, out)
}

func (s *Service) knownSubject(name string) bool {
	if name == Default {
		return true
	}
	for _, n := range s.cfg.Subjects() {
		if n == name {
			return true
		}
	}
	return false
}

func (s *Service) route(r *http.Request, w http.ResponseWriter, c authority.Caller, role string) (any, error) {
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/backup"), "/")
	parts := strings.Split(rest, "/")
	if rest == "" {
		parts = nil
	}
	s.syncBindings()
	full := role == roleWriter || role == roleTarget
	switch {
	case len(parts) == 0:
		if r.Method != http.MethodGet {
			return nil, fail(405, "method not allowed")
		}
		if !full {
			return nil, fail(403, "readers get /api/backup/<subject> for their own subjects only")
		}
		return s.export(), nil
	case parts[0] == "targets" && len(parts) == 3 && parts[2] == "repo-keys":
		if r.Method != http.MethodGet {
			return nil, fail(405, "method not allowed")
		}
		if role != roleTarget || c.Host != parts[1] {
			return nil, fail(403, "%s may not read repo keys of target %s", c.Host, parts[1])
		}
		keys, err := s.repoKeys(parts[1])
		if err != nil {
			return nil, err
		}
		s.auditNote = "repo keys: " + strings.Join(sortedKeys(keys), " ")
		return map[string]any{"repoKeys": keys}, nil
	case parts[0] == "targets" && len(parts) == 2:
		id := parts[1]
		switch r.Method {
		case http.MethodPost:
			if role != roleTarget || c.Host != id {
				return nil, fail(403, "%s may not register target %s", c.Host, id)
			}
			var hb Heartbeat
			if err := decode(w, r, &hb); err != nil {
				return nil, err
			}
			return s.heartbeat(c.Host, id, hb)
		case http.MethodPut:
			if role != roleWriter {
				return nil, fail(403, "only writers change targets")
			}
			var req struct {
				Enabled bool `json:"enabled"`
			}
			if err := decode(w, r, &req); err != nil {
				return nil, err
			}
			t := s.targets[id]
			if t == nil {
				return nil, fail(409, "unknown target %s", id)
			}
			t.Enabled = req.Enabled
			if err := s.saveTargets(); err != nil {
				return nil, err
			}
			return t, nil
		}
		return nil, fail(405, "method not allowed")
	}
	subject := parts[0]
	if !subjectRe.MatchString(subject) || !s.knownSubject(subject) {
		return nil, fail(404, "unknown subject %q", subject)
	}
	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		if !full && (subject == Default || !s.cfg.Owns(c.Host, subject)) {
			return nil, fail(403, "%s may not read %s", c.Host, subject)
		}
		if full {
			row := s.effective(subject)
			return map[string]any{"row": row, "resolved": s.resolve(subject)}, nil
		}
		return s.resolve(subject), nil
	case len(parts) == 1 && r.Method == http.MethodPut:
		if role != roleWriter {
			return nil, fail(403, "only writers change policy")
		}
		var req PolicyRequest
		if err := decode(w, r, &req); err != nil {
			return nil, err
		}
		return s.put(c.Host, subject, req)
	case len(parts) == 2 && parts[1] == "credentials" && r.Method == http.MethodGet:
		if subject == Default || !s.mayFetch(c.Host, subject) {
			return nil, fail(403, "%s is neither placed nor moving to %s: no credentials", subject, c.Host)
		}
		cc, err := s.clientCred(subject)
		if err != nil {
			return nil, err
		}
		s.auditNote = fmt.Sprintf("credentials fetched, restRevision %d", cc.RestRevision)
		return cc, nil
	case len(parts) == 2 && parts[1] == "rotate" && r.Method == http.MethodPost:
		if role != roleWriter {
			return nil, fail(403, "only writers rotate")
		}
		if subject == Default {
			return nil, fail(400, "the default row has no credentials")
		}
		if _, err := s.ensureCred(subject); err != nil {
			return nil, err
		}
		cr, err := s.rotate(subject, "manual ("+c.Host+")", "")
		if err != nil {
			return nil, err
		}
		return map[string]any{"subject": subject, "restRevision": cr.RestRevision}, nil
	case len(parts) == 2 && parts[1] == "clear" && r.Method == http.MethodPost:
		if role != roleWriter {
			return nil, fail(403, "only writers clear")
		}
		var req ClearRequest
		if err := decode(w, r, &req); err != nil {
			return nil, err
		}
		return s.clear(c.Host, subject, req)
	}
	return nil, fail(405, "method not allowed")
}

// PolicyRequest is a PUT body. Nil fields keep the current value.
type PolicyRequest struct {
	Target         *string `json:"target,omitempty"`
	Offsite        *bool   `json:"offsite,omitempty"`
	RetentionLocal *string `json:"retentionLocal,omitempty"`
	RetentionB2    *string `json:"retentionB2,omitempty"`
	// Revision is the row revision the caller read (0: the row must not
	// exist yet, i.e. it still follows the default).
	Revision int64  `json:"revision"`
	User     string `json:"user,omitempty"`
}

func (s *Service) put(host, subject string, req PolicyRequest) (*Row, error) {
	cur := s.rows[subject]
	curRev := int64(0)
	if cur != nil {
		curRev = cur.Revision
	}
	if req.Revision != curRev {
		return nil, fail(409, "%s: changed since revision %d (now %d): re-read and retry", subject, req.Revision, curRev)
	}
	next := s.effective(subject)
	if cur != nil {
		next = *cur
	}
	if req.Target != nil {
		next.Target = *req.Target
	}
	if req.Offsite != nil {
		next.Offsite = *req.Offsite
	}
	if req.RetentionLocal != nil {
		next.RetentionLocal = *req.RetentionLocal
	}
	if req.RetentionB2 != nil {
		next.RetentionB2 = *req.RetentionB2
	}
	if _, ok := Presets[next.RetentionLocal]; !ok {
		return nil, fail(409, "unknown preset %q", next.RetentionLocal)
	}
	if _, ok := Presets[next.RetentionB2]; !ok && next.RetentionB2 != "local" {
		return nil, fail(409, "unknown B2 preset %q", next.RetentionB2)
	}
	if next.Target == None {
		// Turn off: offsite stays as set (nothing is deleted), but a new
		// offsite=true without a target is refused below.
		if req.Offsite != nil && *req.Offsite {
			return nil, fail(409, "offsite needs a pusher target")
		}
	} else {
		t := s.targets[next.Target]
		changing := req.Target != nil
		switch {
		case t == nil:
			return nil, fail(409, "unknown target %q", next.Target)
		case changing && !t.Enabled:
			return nil, fail(409, "target %s is disabled", t.ID)
		case changing && t.Stale(s.cfg.Now()):
			return nil, fail(409, "target %s is stale (last heartbeat %s)", t.ID, time.Unix(t.Seen, 0).UTC().Format(time.RFC3339))
		}
		if next.Offsite && !t.Pusher && (req.Offsite != nil || changing) {
			return nil, fail(409, "offsite: target %s is not a pusher", t.ID)
		}
	}
	s.rev++
	next.Subject, next.Revision, next.By, next.At = subject, s.rev, host+userSuffix(req.User), s.cfg.Now().Unix()
	s.rows[subject] = &next
	if err := s.saveRows(); err != nil {
		s.rows[subject] = cur
		return nil, err
	}
	return &next, nil
}

func userSuffix(u string) string {
	if u == "" {
		return ""
	}
	return " (" + u + ")"
}

// ClearRequest is a POST …/clear body.
type ClearRequest struct {
	Scope   string `json:"scope"`
	Confirm string `json:"confirm"`
	User    string `json:"user,omitempty"`
}

// Scopes are the valid clear scopes.
var Scopes = []string{"local", "b2", "both"}

func (s *Service) clear(host, subject string, req ClearRequest) (*Row, error) {
	switch req.Scope {
	case "local", "b2", "both":
	default:
		return nil, fail(400, "scope must be local, b2 or both")
	}
	if subject == Default {
		return nil, fail(400, "the default row has no repo")
	}
	if want := "clear svc-" + subject + " " + req.Scope; req.Confirm != want {
		return nil, fail(400, "confirm must be %q", want)
	}
	row := s.effective(subject)
	// The holder is the target whose stats list the repo.
	var holder *Target
	for _, t := range s.sortedTargets() {
		if _, ok := t.Stats[subject]; ok && (holder == nil || t.ID == row.Target) {
			holder = t
		}
	}
	if holder == nil {
		return nil, fail(409, "no target reports a repo for %s", subject)
	}
	st := holder.Stats[subject]
	if (req.Scope == "local" || req.Scope == "both") && st.LocalBytes == nil {
		return nil, fail(409, "%s does not hold a local repo for %s", holder.ID, subject)
	}
	if (req.Scope == "b2" || req.Scope == "both") && (st.B2Bytes == nil || !holder.Pusher) {
		return nil, fail(409, "%s has no offsite repo", subject)
	}
	if row.Clear != nil && len(row.Clear.Done) == 0 {
		return nil, fail(409, "a clear (%s) is already queued", row.Clear.Scope)
	}
	s.rev++
	row.Revision, row.By, row.At = s.rev, host+userSuffix(req.User), s.cfg.Now().Unix()
	row.Clear = &Clear{Scope: req.Scope, Target: holder.ID, By: row.By, RequestedAt: row.At}
	if req.Scope != "local" {
		row.Offsite = false
	}
	s.rows[subject] = &row
	if err := s.saveRows(); err != nil {
		return nil, err
	}
	return &row, nil
}

// Heartbeat is a target's POST body.
type Heartbeat struct {
	URL    string           `json:"url"`
	Pusher bool             `json:"pusher"`
	Stats  map[string]Stats `json:"stats"`
	// Cleared reports finished clears: subject -> scopes done.
	Cleared map[string][]string `json:"cleared,omitempty"`
	// Applied reports the REST password revision rendered per subject.
	Applied map[string]int64 `json:"applied,omitempty"`
}

// HeartbeatReply tells a target its retention per repo and pending clears.
type HeartbeatReply struct {
	Retention   map[string]string `json:"retention"`
	RetentionB2 map[string]string `json:"retentionB2"`
	Offsite     []string          `json:"offsite"`
	// Local: subjects whose policy target is this target (a cleared local
	// repo is re-initialised only for these).
	Local   []string            `json:"local"`
	Clears  map[string]string   `json:"clears"`
	Presets map[string][]string `json:"presets"`
	// Credentials: every subject's HTTP login for htpasswd. Never the repo
	// password (that is /repo-keys, per held repo).
	Credentials map[string]RestCred `json:"credentials"`
}

func (s *Service) heartbeat(host, id string, hb Heartbeat) (HeartbeatReply, error) {
	if !strings.HasPrefix(hb.URL, "rest:http") {
		return HeartbeatReply{}, fail(400, "url must be rest:http(s)://…")
	}
	for name := range hb.Stats {
		if !subjectRe.MatchString(name) {
			return HeartbeatReply{}, fail(400, "bad subject %q in stats", name)
		}
	}
	now := s.cfg.Now()
	t := s.targets[id]
	if t == nil {
		t = &Target{ID: id, Enabled: true}
		s.targets[id] = t
	}
	t.URL, t.Pusher, t.DeclaredBy, t.Seen = hb.URL, hb.Pusher, host, now.Unix()
	if hb.Stats != nil {
		t.Stats = hb.Stats
	}
	if hb.Applied != nil {
		t.Applied = hb.Applied
	}
	rowsDirty := false
	for subject, done := range hb.Cleared {
		r := s.rows[subject]
		if r == nil || r.Clear == nil || r.Clear.Target != id {
			continue
		}
		r.Clear.Done = append(r.Clear.Done, done...)
		rowsDirty = true
	}
	for _, n := range s.cfg.Subjects() {
		if subjectRe.MatchString(n) {
			if _, err := s.ensureCred(n); err != nil {
				return HeartbeatReply{}, err
			}
		}
	}
	if err := s.saveTargets(); err != nil {
		return HeartbeatReply{}, err
	}
	if rowsDirty {
		if err := s.saveRows(); err != nil {
			return HeartbeatReply{}, err
		}
	}
	rep := HeartbeatReply{Retention: map[string]string{}, RetentionB2: map[string]string{}, Clears: map[string]string{}, Presets: Presets, Credentials: s.restFeed()}
	// Every known subject gets an entry, not only the ones with an explicit row
	// or a stats line: a subject without a row inherits the default row (§2.3),
	// and the target's pruner reads this map per repo. Leaving inherited
	// subjects out made the pruner fall back to its own preset, and a freshly
	// seeded target (default row only, stats not measured yet) got an empty map.
	names := map[string]bool{}
	for _, n := range s.cfg.Subjects() {
		names[n] = true
	}
	for n := range t.Stats {
		names[n] = true
	}
	for n := range s.rows {
		if n != Default {
			names[n] = true
		}
	}
	for n := range names {
		r := s.effective(n)
		rep.Retention[n] = r.RetentionLocal
		b2 := r.RetentionB2
		if b2 == "local" {
			b2 = r.RetentionLocal
		}
		rep.RetentionB2[n] = b2
		if r.Target == id {
			rep.Local = append(rep.Local, n)
		}
		if r.Target == id && r.Offsite && t.Pusher {
			rep.Offsite = append(rep.Offsite, n)
		}
		if r.Clear != nil && r.Clear.Target == id && pendingScope(r.Clear) != "" {
			rep.Clears[n] = pendingScope(r.Clear)
		}
	}
	sort.Strings(rep.Offsite)
	sort.Strings(rep.Local)
	return rep, nil
}

// Pending is the scope of c still to run ("" once finished). A finished
// clear stays on the row as the audit record; views show only pending ones.
func (c *Clear) Pending() string { return pendingScope(c) }

// pendingScope is what remains of a clear: "local" first, then "b2".
func pendingScope(c *Clear) string {
	done := map[string]bool{}
	for _, d := range c.Done {
		done[d] = true
	}
	need := []string{c.Scope}
	if c.Scope == "both" {
		need = []string{"local", "b2"}
	}
	for _, n := range need {
		if !done[n] {
			return n
		}
	}
	return ""
}

// UI is the in-process write path for the dashboard editor
// (internal/backupui). It runs the same put/clear and revision rules as the
// API under the same lock; the caller authenticates and audits.
const uiHost = "ui"

// PutAs applies req to subject as dashboard user user.
func (s *Service) PutAs(user, subject string, req PolicyRequest) (*Row, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !subjectRe.MatchString(subject) || !s.knownSubject(subject) {
		return nil, fail(404, "unknown subject %q", subject)
	}
	req.User = user
	return s.put(uiHost, subject, req)
}

// ClearAs queues a clear of subject as dashboard user user.
func (s *Service) ClearAs(user, subject string, req ClearRequest) (*Row, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !subjectRe.MatchString(subject) || !s.knownSubject(subject) {
		return nil, fail(404, "unknown subject %q", subject)
	}
	req.User = user
	return s.clear(uiHost, subject, req)
}

// ErrCode is err's HTTP status (500 for errors not from the store).
func ErrCode(err error) int {
	var he *httpErr
	if errors.As(err, &he) {
		return he.code
	}
	return 500
}

// AuditUI writes one audit line for a dashboard request.
func (s *Service) AuditUI(user, peer, action string, code int, msg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.logAudit(auditEntry{Host: uiHost, Role: "ui", User: user, Peer: peer, Action: action, Code: code, Message: msg})
}
