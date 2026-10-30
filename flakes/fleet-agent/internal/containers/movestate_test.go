package containers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// moveRegistry is a stateful stand-in for fleet-edge's placement registry: one
// row for svc, the token a reserve mints, and the previous binding that makes a
// rollback free until the source is retired. The handlers mirror
// placements.Service for the writes a move makes (reserve, renew, commit,
// retire) and for its rollback (DELETE), 409s included, because the point of
// moveState is who holds the token.
type moveRegistry struct {
	srv *httptest.Server

	mu       sync.Mutex
	rows     map[string]placementRow
	sent     []regCall
	rev, tok int64
	takeover bool // the next commit answers as if another client had reserved the row
	// stealOn, once that file exists, makes the next request find svc reserved
	// by another client (a new token on the same row), as if a second device
	// had taken the placement over while a host step ran.
	stealOn string
	stolen  bool
	// down answers retires and reads with a 500, as a registry outage
	// that starts right after the commit would.
	down bool
	// downAfterCommit turns down on once a commit lands.
	downAfterCommit bool
	// lostCommitReply lets a commit land, then answers it with a 500, as a
	// connection that drops after the write would.
	lostCommitReply bool
	// renewLost answers renews with a 500, and the next reserve that presents
	// a token finds the row taken over (a new token) and answers 409: an
	// outage that hid a takeover from the renew.
	renewLost bool
}

// regCall is one request a move sent: the method, the act (the placement verb,
// or the service name for a rollback), the decoded body and the query (a
// rollback carries its token there).
type regCall struct {
	verb  string
	act   string
	req   placementReq
	query url.Values
}

func newMoveRegistry(t *testing.T) *moveRegistry {
	t.Helper()
	m := &moveRegistry{
		rows: map[string]placementRow{"svc": {Service: "svc", Host: "src", State: placementCommitted, Revision: 1}},
		rev:  1,
	}
	m.srv = httptest.NewServer(http.HandlerFunc(m.serve))
	t.Cleanup(m.srv.Close)
	return m
}

// armTakeover makes the next commit answer like a registry whose row another
// client has reserved in the meantime: it mints a new token first, so the
// move's re-read finds a handle that is not its own.
func (m *moveRegistry) armTakeover() {
	m.mu.Lock()
	m.takeover = true
	m.mu.Unlock()
}

// hold puts svc's row in the state a move in flight leaves it: prepared on
// host with src as the rollback binding, held by tok.
func (m *moveRegistry) hold(host, tok string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store(placementRow{Service: "svc", Host: host, State: placementPrepared,
		Previous: &placementBinding{Host: "src"}, User: "someone", Reason: "cnt move", Token: tok})
}

// view is what placementNow answers with: the rows and the effective host of
// each, which is what resolveHost routes on.
func (m *moveRegistry) view() *placementView {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshot()
}

// snapshot builds the read view; the caller holds the lock.
func (m *moveRegistry) snapshot() *placementView {
	v := &placementView{Rows: map[string]placementRow{}, Host: map[string]string{}}
	for n, r := range m.rows {
		v.Rows[n] = r
		if h := r.effective(); h != "" {
			v.Host[n] = h
		}
	}
	return v
}

func (m *moveRegistry) rowNow(svc string) placementRow {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.rows[svc]
}

func (m *moveRegistry) calls() []regCall {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]regCall(nil), m.sent...)
}

func (m *moveRegistry) newToken() string {
	m.tok++
	return fmt.Sprintf("tok-%d", m.tok)
}

// store writes row back, bumping its revision as every real write does.
func (m *moveRegistry) store(row placementRow) {
	m.rev++
	row.Revision = m.rev
	m.rows[row.Service] = row
}

func (m *moveRegistry) serve(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stealOn != "" && !m.stolen && exists(m.stealOn) {
		m.stolen = true
		row := m.rows["svc"]
		row.Token = m.newToken()
		m.store(row)
	}
	act := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/api/placements"), "/")
	c := regCall{verb: r.Method, act: act, query: r.URL.Query()}
	if r.Method == http.MethodPost {
		_ = json.NewDecoder(r.Body).Decode(&c.req)
	}
	m.sent = append(m.sent, c)
	if m.down && (r.Method == http.MethodGet || act == "retire") {
		regFail(w, http.StatusInternalServerError, "registry is down")
		return
	}
	switch r.Method {
	case http.MethodGet:
		v := m.snapshot()
		rows := make([]placementRow, 0, len(v.Rows))
		for _, row := range v.Rows {
			rows = append(rows, row)
		}
		regReply(w, map[string]any{"rows": rows, "host": v.Host})
	case http.MethodPost:
		m.post(w, act, c.req)
	case http.MethodDelete:
		m.remove(w, act, c.query)
	default:
		regFail(w, http.StatusMethodNotAllowed, "unsupported request")
	}
}

func (m *moveRegistry) post(w http.ResponseWriter, act string, req placementReq) {
	row, ok := m.rows[req.Service]
	reply := func() { regReply(w, map[string]any{"row": m.rows[req.Service]}) }
	switch act {
	case "reserve":
		if !ok {
			if !req.Force && (req.Token != "" || req.Revision != 0) {
				regFail(w, http.StatusConflict, req.Service+": no placement; this request belongs to one that was removed")
				return
			}
			row = placementRow{Service: req.Service, Host: req.Host, State: placementPrepared,
				User: req.User, Reason: req.Reason, Token: m.newToken()}
			m.store(row)
			reply()
			return
		}
		if m.renewLost && req.Token != "" && req.Token == row.Token {
			row.Token = m.newToken()
			m.store(row)
		}
		if !req.Force && req.Token != row.Token {
			regFail(w, http.StatusConflict, req.Service+": reserve refused: another device's move owns the reservation")
			return
		}
		if row.Host == req.Host {
			if row.State != placementPrepared && row.State != placementStale {
				regFail(w, http.StatusConflict, req.Service+" is already placed on "+row.Host)
				return
			}
			// A retried reserve from the holder keeps the token; a takeover mints one.
			if req.Token != row.Token {
				row.Token = m.newToken()
			}
			row.State, row.User, row.Reason = placementPrepared, req.User, req.Reason
			m.store(row)
			reply()
			return
		}
		prev := row.Previous
		if row.State != placementPrepared && row.State != placementStale {
			prev = &placementBinding{Host: row.Host}
		}
		m.store(placementRow{Service: req.Service, Host: req.Host, State: placementPrepared, Previous: prev,
			User: req.User, Reason: req.Reason, Token: m.newToken()})
		reply()
	case "renew":
		if m.renewLost {
			regFail(w, http.StatusInternalServerError, "registry is down")
			return
		}
		if !ok {
			regFail(w, http.StatusNotFound, req.Service+": no placement to renew")
			return
		}
		if !req.Force && req.Token != row.Token {
			regFail(w, http.StatusConflict, req.Service+": renew refused: another device's move owns the reservation")
			return
		}
		if req.Token == "" || row.State != placementPrepared {
			regFail(w, http.StatusConflict, req.Service+" is not prepared (state "+row.State+")")
			return
		}
		m.store(row)
		reply()
	case "commit":
		if !ok {
			regFail(w, http.StatusNotFound, req.Service+": no placement to commit")
			return
		}
		if m.takeover {
			row.Token = m.newToken()
			m.store(row)
			regFail(w, http.StatusConflict, req.Service+": commit refused: another device's move owns the reservation")
			return
		}
		if row.State != placementPrepared && row.State != placementStale {
			regFail(w, http.StatusConflict, req.Service+" is not prepared (state "+row.State+")")
			return
		}
		if req.Host != "" && req.Host != row.Host {
			regFail(w, http.StatusConflict, req.Service+" is reserved for "+row.Host+", not "+req.Host)
			return
		}
		if !req.Force && req.Token != row.Token {
			regFail(w, http.StatusConflict, req.Service+": commit refused: another device's move owns the reservation")
			return
		}
		row.State = placementCommitted
		if row.Previous == nil {
			row.Token = "" // nothing left to retire or roll back
		}
		m.store(row)
		if m.downAfterCommit {
			m.down = true
		}
		if m.lostCommitReply {
			regFail(w, http.StatusInternalServerError, "connection reset after the write")
			return
		}
		reply()
	case "retire":
		if !ok {
			regFail(w, http.StatusNotFound, req.Service+": no placement")
			return
		}
		if !req.Force && req.Token != row.Token {
			regFail(w, http.StatusConflict, req.Service+": retire refused: another device's move owns the reservation")
			return
		}
		switch row.State {
		case placementStale:
			regFail(w, http.StatusConflict, req.Service+": the reservation expired and is fenced")
			return
		case placementPrepared:
			regFail(w, http.StatusConflict, req.Service+" is still prepared: commit the move first")
			return
		}
		if row.Previous != nil {
			row.State = placementRetiring
			m.store(row)
		}
		reply()
	default:
		regFail(w, http.StatusBadRequest, "unknown placement act "+act)
	}
}

// remove is the rollback: it drops the reservation and puts the name back on
// the previous binding, or deletes the row when there is none.
func (m *moveRegistry) remove(w http.ResponseWriter, svc string, q url.Values) {
	row, ok := m.rows[svc]
	if !ok {
		regReply(w, map[string]any{"row": nil})
		return
	}
	force := q.Get("force") != ""
	if !force && q.Get("token") != row.Token {
		regFail(w, http.StatusConflict, svc+": rollback refused: another device's move owns the reservation")
		return
	}
	if rev := q.Get("revision"); rev != "" && rev != fmt.Sprint(row.Revision) {
		regFail(w, http.StatusConflict, svc+": revision "+rev+" is stale (now "+fmt.Sprint(row.Revision)+")")
		return
	}
	if !force && row.State == placementStale {
		regFail(w, http.StatusConflict, svc+": the reservation expired and is fenced: recover it")
		return
	}
	if !force && row.Previous != nil && row.State == placementRetiring {
		regFail(w, http.StatusConflict, svc+"'s source was retired: force to record it anyway")
		return
	}
	if row.Previous == nil {
		delete(m.rows, svc)
		regReply(w, map[string]any{"row": nil})
		return
	}
	m.store(placementRow{Service: svc, Host: row.Previous.Host, State: placementCommitted})
	regReply(w, map[string]any{"row": nil})
}

func regReply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func regFail(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// regFirst is the index of the first call for act, -1 when the move never made
// it. Call order is the assertion: reserve, then commit, then retire.
func regFirst(cs []regCall, act string) int {
	for i, c := range cs {
		if c.act == act {
			return i
		}
	}
	return -1
}

// moveOnRegistry wires a move rig to the fake registry: the move both writes to
// it and resolves from it.
func moveOnRegistry(t *testing.T) (*moveRig, *moveRegistry) {
	t.Helper()
	m := newMoveRig(t)
	reg := newMoveRegistry(t)
	placementNow = func(bool) *placementView { return reg.view() }
	usePlacementServer(t, reg.srv)
	t.Cleanup(func() { registryCache = nil })
	return m, reg
}

// A completed move records reserve -> commit -> retire, each presenting the
// reserve's token and nothing forced, and the binding it publishes is what the
// next command routes on: a deploy with no --host lands on the destination even
// though discovery reports a copy on both hosts.
func TestMoveThenDeployFollowsTheRegistry(t *testing.T) {
	m, reg := moveOnRegistry(t)
	if err := runMove(t); err != nil {
		t.Fatalf("move: %v\n%s", err, m.calls())
	}
	cs := reg.calls()
	ri, ci, ti := regFirst(cs, "reserve"), regFirst(cs, "commit"), regFirst(cs, "retire")
	if ri < 0 || ci < 0 || ti < 0 || ri >= ci || ci >= ti {
		t.Fatalf("registry writes out of order (reserve %d, commit %d, retire %d): %+v", ri, ci, ti, cs)
	}
	if c := cs[ri]; c.req.Token != "" {
		t.Errorf("the first reserve presented token %q, want none (it mints the handle)", c.req.Token)
	}
	for _, i := range []int{ci, ti} {
		c := cs[i]
		if c.req.Token != "tok-1" {
			t.Errorf("%s presented token %q, want the reserve's tok-1", c.act, c.req.Token)
		}
		if c.req.Force {
			t.Errorf("%s forced; only the first reserve may: %+v", c.act, c)
		}
	}
	for _, c := range cs {
		if c.verb == http.MethodDelete {
			t.Errorf("the completed move rolled its reservation back: %+v", c)
		}
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementRetiring ||
		row.Previous == nil || row.Previous.Host != "src" {
		t.Fatalf("row = %+v, want dst retiring with src as the rollback binding", row)
	}
	// Discovery now reports a copy on both hosts, which is what a move's
	// leftovers look like: only the binding can choose between them.
	fleetProbe = fakeFleet(map[string][]string{"src": {"svc+"}, "dst": {"svc+"}})
	registryCache = nil
	before := m.calls()
	if err := cmdDeploy([]string{"svc"}); err != nil {
		t.Fatalf("deploy after the move: %v", err)
	}
	after := strings.TrimPrefix(m.calls(), before)
	if !strings.Contains(after, "ssh dst:") || strings.Contains(after, "ssh src:") {
		t.Fatalf("the deploy did not follow the registry to dst:\n%s", after)
	}
}

// A failure before the commit leaves nothing to recover by hand: the
// destination is rolled back, the source restarted, and the reservation the
// move took dropped with its own token, so routing is back on the source.
func TestMoveFailureReleasesTheReservation(t *testing.T) {
	m, reg := moveOnRegistry(t)
	must(t, os.WriteFile(filepath.Join(m.root, "svc/data/app.db"), []byte("SQLite format 3\x00LIVE CORRUPT"), 0o644))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "restore check") {
		t.Fatalf("expected the restore check to fail the move, got %v\n%s", err, m.calls())
	}
	m.assertSourceIntact(t)
	m.assertTargetClean(t)
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) != 1 {
		t.Errorf("target data moved aside %d times, want once: %v", len(g), g)
	}
	cs := reg.calls()
	if ci := regFirst(cs, "commit"); ci >= 0 {
		t.Fatalf("a move that failed at the restore check committed: %+v", cs[ci])
	}
	dropped := -1
	for i, c := range cs {
		if c.verb != http.MethodDelete {
			continue
		}
		dropped = i
		if c.act != "svc" {
			t.Errorf("rollback aimed at %q", c.act)
		}
		if got := c.query.Get("token"); got != "tok-1" {
			t.Errorf("rollback presented token %q, want the reserve's tok-1", got)
		}
		if c.query.Get("force") != "" {
			t.Errorf("rollback forced: %v", c.query)
		}
	}
	if dropped < 0 {
		t.Fatalf("the reservation was not released: %+v", cs)
	}
	if row := reg.rowNow("svc"); row.Host != "src" || row.State != placementCommitted ||
		row.Previous != nil || row.Token != "" {
		t.Fatalf("row = %+v, want the name back on src, committed, with no reservation left", row)
	}
}

// A row another client has taken over stops the move where it is: the source
// really was stopped in step 2, so it is NOT restarted (the other client may be
// serving from either host), the destination keeps the copy the deploy just
// installed, and the source is not uninstalled.
func TestMoveTakeoverStopsBeforeTheSwitch(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.armTakeover()
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "the move was taken over") {
		t.Fatalf("expected the takeover to stop the move, got %v\n%s", err, m.calls())
	}
	if !strings.Contains(err.Error(), "nothing was destroyed") {
		t.Errorf("the error does not say both hosts were left as they were: %v", err)
	}
	if regFirst(reg.calls(), "retire") >= 0 {
		t.Fatalf("a taken-over move retired the source: %+v", reg.calls())
	}
	// The source keeps its data and its marker, and stays stopped.
	if !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatal("the source data was touched")
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) > 0 {
		t.Fatalf("the source was retired: %v", g)
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("the taken-over move started the source; another client may be serving it")
	}
	if !exists(m.srcState() + "/vlfc/move-svc.was-running") {
		t.Error("the was-running marker is gone, so a re-run would not know to start the source again")
	}
	if strings.Contains(m.calls(), "svc.moved-") {
		t.Fatal("the switch ran on a taken-over move")
	}
	// Rollback is skipped on purpose, so the destination keeps the copy the
	// deploy left there instead of being demolished under another client.
	if !exists(m.dstState()+"/active-fleet-svc.service") || !exists(filepath.Join(m.dst, "svc")) {
		t.Fatalf("the destination was rolled back on a takeover:\n%s", m.calls())
	}
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) > 0 {
		t.Fatalf("target data was moved aside on a takeover: %v", g)
	}
	if row := reg.rowNow("svc"); row.Token == "tok-1" || row.State != placementPrepared || row.Host != "dst" {
		t.Fatalf("row = %+v, want the foreign reservation left in place", row)
	}
}

// onlyFreshReserve fails the test on any registry write other than a reserve
// that presents no token: a refused move asks for a fresh reservation and
// never adopts, renews, commits or rolls back anything.
func onlyFreshReserve(t *testing.T, cs []regCall) {
	t.Helper()
	for _, c := range cs {
		switch {
		case c.verb == http.MethodGet:
		case c.verb == http.MethodPost && c.act == "reserve":
			if c.req.Token != "" || c.req.Force {
				t.Errorf("the reserve presented token %q (force %v), want a fresh unforced one", c.req.Token, c.req.Force)
			}
		default:
			t.Errorf("unexpected registry call %+v", c)
		}
	}
}

// A second move to the same destination while the first holds the reservation
// asks for a fresh one instead of adopting the first move's token, is refused,
// and never reaches a host.
func TestMoveRefusedWhileAnotherMoveHoldsTheDestination(t *testing.T) {
	for _, state := range []string{placementPrepared, placementStale} {
		t.Run(state, func(t *testing.T) {
			m, reg := moveOnRegistry(t)
			reg.hold("dst", "tok-first")
			reg.mu.Lock()
			row := reg.rows["svc"]
			row.State = state
			reg.rows["svc"] = row
			reg.mu.Unlock()
			err := runMove(t)
			if err == nil || !strings.Contains(err.Error(), "another device's move owns the reservation") {
				t.Fatalf("expected the held reservation to refuse the move, got %v", err)
			}
			if c := m.calls(); c != "" {
				t.Fatalf("a refused move made remote calls:\n%s", c)
			}
			onlyFreshReserve(t, reg.calls())
			if row := reg.rowNow("svc"); row.Token != "tok-first" || row.Host != "dst" {
				t.Fatalf("row = %+v, want the first move's reservation untouched", row)
			}
			if exists(moveStatePath("svc")) {
				t.Error("a refused move saved a token")
			}
		})
	}
}

// A re-run that holds the token of its own interrupted move (saved in the local
// move-state file, or passed with --resume-token) presents it, keeps it, and
// finishes the move; the file is gone once the registry records the move.
func TestMoveResumesWithTheHeldToken(t *testing.T) {
	for _, via := range []string{"file", "flag"} {
		t.Run(via, func(t *testing.T) {
			m, reg := moveOnRegistry(t)
			reg.hold("dst", "tok-held")
			args := []string{"svc", "--to", "dst", "--from", "src"}
			if via == "file" {
				p := moveStatePath("svc")
				must(t, os.MkdirAll(filepath.Dir(p), 0o700))
				must(t, os.WriteFile(p, []byte(`{"service":"svc","from":"src","to":"dst","token":"tok-held"}`), 0o600))
			} else {
				args = append(args, "--resume-token", "tok-held")
			}
			if err := cmdMove(args); err != nil {
				t.Fatalf("resumed move: %v\n%s", err, m.calls())
			}
			cs := reg.calls()
			for _, act := range []string{"reserve", "commit", "retire"} {
				i := regFirst(cs, act)
				if i < 0 {
					t.Fatalf("no %s: %+v", act, cs)
				}
				if c := cs[i]; c.req.Token != "tok-held" || c.req.Force {
					t.Errorf("%s presented token %q (force %v), want the held tok-held", act, c.req.Token, c.req.Force)
				}
			}
			if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementRetiring {
				t.Fatalf("row = %+v, want dst retiring", row)
			}
			if exists(moveStatePath("svc")) {
				t.Error("the move-state file outlived the recorded move")
			}
		})
	}
}

// A registry that is configured but does not answer refuses the move of a
// service it has a row for, before any host is touched.
func TestMoveRefusedWhenTheRegistryIsDown(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.srv.Close()
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "refusing to move without recording it") {
		t.Fatalf("expected an unreachable registry to refuse the move, got %v", err)
	}
	if c := m.calls(); c != "" {
		t.Fatalf("the refused move made remote calls:\n%s", c)
	}
	if !exists(m.srcState()+"/active-fleet-svc.service") || !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatal("the source was touched")
	}
	if exists(filepath.Join(m.dst, "svc")) {
		t.Fatal("the destination was touched")
	}
}

// Another client takes the placement over mid-move, and then the deploy fails
// with an ordinary error: the undo asks the registry with its token first,
// finds the row is not ours, and neither rolls the destination back nor
// restarts the source.
func TestMoveTakeoverThenDeployFailureLeavesBothHosts(t *testing.T) {
	m, reg := moveOnRegistry(t)
	flag := filepath.Join(t.TempDir(), "taken-over")
	reg.mu.Lock()
	reg.stealOn = flag
	reg.mu.Unlock()
	out := filepath.Join(filepath.Dir(m.root), "out")
	writeExe(t, filepath.Join(m.bin, "nix"), "#!/bin/sh\nif [ \"$1\" = build ]; then touch "+flag+"; echo 'error: build failed' >&2; exit 1; fi\necho "+out+"\n")
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "deploy on dst") {
		t.Fatalf("expected the deploy to fail the move, got %v\n%s", err, m.calls())
	}
	if !strings.Contains(err.Error(), "the move was taken over") || !strings.Contains(err.Error(), "nothing was destroyed") {
		t.Errorf("the error does not say the move lost the placement and left both hosts: %v", err)
	}
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) > 0 || !exists(filepath.Join(m.dst, "svc")) {
		t.Fatalf("the destination was rolled back after the takeover (%v):\n%s", g, m.calls())
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("the source was restarted after the takeover")
	}
	if !exists(m.srcState() + "/vlfc/move-svc.was-running") {
		t.Error("the was-running marker is gone")
	}
	for _, c := range reg.calls() {
		if c.verb == http.MethodDelete {
			t.Errorf("the reservation was rolled back under another client: %+v", c)
		}
	}
	if row := reg.rowNow("svc"); row.Token == "tok-1" || row.Host != "dst" || row.State != placementPrepared {
		t.Fatalf("row = %+v, want the other client's reservation left in place", row)
	}
}

// The registry goes down right after the commit: the retire fails, its retry
// fails, and the re-read that could confirm the row is ours and retiring fails
// too. The move stops before the switch: the source stays installed and
// stopped, the destination keeps serving, and the error says how to finish.
// A re-run with the held token then redoes only the retire and the switch.
func TestMoveUnconfirmedRetireStopsBeforeTheSwitch(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.mu.Lock()
	reg.downAfterCommit = true
	reg.mu.Unlock()
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "was not confirmed by the registry") {
		t.Fatalf("expected the unconfirmed retire to stop the move, got %v\n%s", err, m.calls())
	}
	for _, want := range []string{"stopped before the switch", "nothing was destroyed",
		"Re-run `cnt move svc --to dst --from src`", "cnt place svc --recover"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not say %q: %v", want, err)
		}
	}
	if strings.Contains(m.calls(), "svc.moved-") {
		t.Fatalf("the switch ran on the source after an unconfirmed retire:\n%s", m.calls())
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) > 0 || !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatalf("the source data was renamed (%v)", g)
	}
	if !exists(m.srcState() + "/installed-fleet-svc.service") {
		t.Fatal("the source was uninstalled")
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("the source was started again; the destination serves")
	}
	if !exists(m.dstState() + "/active-fleet-svc.service") {
		t.Fatal("the destination does not serve")
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementCommitted || row.Token != "tok-1" {
		t.Fatalf("row = %+v, want dst committed, still held by tok-1", row)
	}
	if heldToken("svc", "dst") != "tok-1" {
		t.Fatal("the held token was dropped, so a re-run could not resume")
	}

	reg.mu.Lock()
	reg.down, reg.downAfterCommit = false, false
	n := len(reg.sent)
	reg.mu.Unlock()
	if err := runMove(t); err != nil {
		t.Fatalf("resumed move: %v\n%s", err, m.calls())
	}
	cs := reg.calls()[n:]
	for _, act := range []string{"reserve", "renew", "commit"} {
		if i := regFirst(cs, act); i >= 0 {
			t.Errorf("the resumed move sent a %s: %+v", act, cs[i])
		}
	}
	if i := regFirst(cs, "retire"); i < 0 || cs[i].req.Token != "tok-1" || cs[i].req.Force {
		t.Fatalf("the resumed move did not retire with tok-1: %+v", cs)
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementRetiring {
		t.Fatalf("row = %+v, want dst retiring", row)
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) != 1 {
		t.Fatalf("the resumed switch did not retire the source data: %v", g)
	}
	if !exists(m.dstState() + "/active-fleet-svc.service") {
		t.Fatal("the destination stopped serving")
	}
	if exists(moveStatePath("svc")) {
		t.Error("the move-state file outlived the recorded move")
	}
}

// noUndo fails the test if the move rolled the destination back, restarted
// the source, or sent the registry a rollback.
func noUndo(t *testing.T, m *moveRig, reg *moveRegistry) {
	t.Helper()
	for _, c := range reg.calls() {
		if c.verb == http.MethodDelete {
			t.Fatalf("the move rolled the reservation back: %+v", c)
		}
	}
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) > 0 || !exists(m.dstState()+"/active-fleet-svc.service") {
		t.Fatalf("the destination was rolled back (%v):\n%s", g, m.calls())
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("the source was started again; the destination is the binding")
	}
}

// A commit that lands but whose answer is lost (a 500 after the write) is
// recognised by the re-read: the row is committed with this move's token, so
// the move goes on to retire and switch instead of undoing a binding.
func TestMoveLostCommitReplyGoesOn(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.mu.Lock()
	reg.lostCommitReply = true
	reg.mu.Unlock()
	if err := runMove(t); err != nil {
		t.Fatalf("move: %v\n%s", err, m.calls())
	}
	noUndo(t, m, reg)
	cs := reg.calls()
	if i := regFirst(cs, "retire"); i < 0 || cs[i].req.Token != "tok-1" || cs[i].req.Force {
		t.Fatalf("the move did not retire with tok-1: %+v", cs)
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementRetiring || row.Token != "tok-1" {
		t.Fatalf("row = %+v, want dst retiring, held by tok-1", row)
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) != 1 {
		t.Fatalf("the switch did not retire the source data: %v", g)
	}
}

// A commit that lands but whose answer is lost, with the registry unreadable
// right after: the move cannot tell whether it committed, so it stops with
// both hosts as they are and the token kept. A re-run then finds the commit
// with the held token and redoes only the retire and the switch.
func TestMoveLostCommitReplyUnreadableStopsThenResumes(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.mu.Lock()
	reg.lostCommitReply, reg.downAfterCommit = true, true
	reg.mu.Unlock()
	err := runMove(t)
	if err == nil || !errors.Is(err, errCommitUnconfirmed) {
		t.Fatalf("expected the unconfirmed commit to stop the move, got %v\n%s", err, m.calls())
	}
	for _, want := range []string{"neither host was rolled back or restarted", "the held token was kept",
		"Re-run `cnt move svc --to dst --from src`"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not say %q: %v", want, err)
		}
	}
	noUndo(t, m, reg)
	if regFirst(reg.calls(), "retire") >= 0 {
		t.Fatalf("an unconfirmed commit retired the source: %+v", reg.calls())
	}
	if !exists(m.srcState()+"/installed-fleet-svc.service") || !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatal("the source was uninstalled or its data touched")
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementCommitted || row.Token != "tok-1" {
		t.Fatalf("row = %+v, want dst committed, still held by tok-1", row)
	}
	if heldToken("svc", "dst") != "tok-1" {
		t.Fatal("the held token was dropped, so a re-run could not resume")
	}

	reg.mu.Lock()
	reg.down, reg.downAfterCommit, reg.lostCommitReply = false, false, false
	n := len(reg.sent)
	reg.mu.Unlock()
	if err := runMove(t); err != nil {
		t.Fatalf("resumed move: %v\n%s", err, m.calls())
	}
	cs := reg.calls()[n:]
	for _, act := range []string{"reserve", "renew", "commit"} {
		if i := regFirst(cs, act); i >= 0 {
			t.Errorf("the resumed move sent a %s: %+v", act, cs[i])
		}
	}
	if i := regFirst(cs, "retire"); i < 0 || cs[i].req.Token != "tok-1" || cs[i].req.Force {
		t.Fatalf("the resumed move did not retire with tok-1: %+v", cs)
	}
	if row := reg.rowNow("svc"); row.Host != "dst" || row.State != placementRetiring {
		t.Fatalf("row = %+v, want dst retiring", row)
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) != 1 {
		t.Fatalf("the resumed switch did not retire the source data: %v", g)
	}
	if exists(moveStatePath("svc")) {
		t.Error("the move-state file outlived the recorded move")
	}
}

// owned on a row committed with this move's token: renew and reserve both
// answer 409 (as the registry does for a committed row), which is not a
// takeover. The token file stays and the error is not errMoveCanceled.
func TestOwnedKeepsTheTokenOnACommittedRow(t *testing.T) {
	_, reg := moveOnRegistry(t)
	reg.mu.Lock()
	reg.store(placementRow{Service: "svc", Host: "dst", State: placementCommitted,
		Previous: &placementBinding{Host: "src"}, Token: "tok-1"})
	reg.mu.Unlock()
	c, err := edgeClientFor()
	if err != nil {
		t.Fatal(err)
	}
	st := &moveState{c: c, svc: "svc", from: "src", to: "dst", tok: "tok-1"}
	st.save()
	err = st.owned()
	if err == nil || errors.Is(err, errMoveCanceled) {
		t.Fatalf("owned() = %v, want a non-takeover error", err)
	}
	cs := reg.calls()
	if regFirst(cs, "renew") < 0 || regFirst(cs, "reserve") < 0 {
		t.Fatalf("owned did not try renew and reserve: %+v", cs)
	}
	if heldToken("svc", "dst") != "tok-1" {
		t.Fatal("owned dropped the held token of a committed move")
	}
}

// A renew lost to an outage (500) is retried as a reserve with the token, and
// that one answers 409: another client took the placement over. The move stops
// there with errMoveCanceled, before the final backup: no host is changed and
// the registry gets no further write.
func TestMoveRenewTakeoverStopsTheMove(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.mu.Lock()
	reg.renewLost = true
	reg.mu.Unlock()
	err := runMove(t)
	if !errors.Is(err, errMoveCanceled) {
		t.Fatalf("expected the takeover to cancel the move, got %v\n%s", err, m.calls())
	}
	// Only the read-only calls before the first renew ran: the override
	// fetch and the two preflights. Nothing stopped, started or backed up.
	calls := m.calls()
	ssh := 0
	for _, l := range strings.Split(calls, "\n") {
		if strings.HasPrefix(l, "ssh ") {
			ssh++
		}
		if strings.HasPrefix(l, "systemctl stop") || strings.HasPrefix(l, "systemctl start") {
			t.Errorf("a unit was changed after the takeover: %s", l)
		}
	}
	if ssh != 3 || strings.Contains(calls, "fleet-backup-svc@") {
		t.Fatalf("remote calls after the takeover (want the override fetch and two preflights):\n%s", calls)
	}
	if !exists(m.srcState()+"/active-fleet-svc.service") || !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatal("the source was touched")
	}
	if exists(filepath.Join(m.dst, "svc")) || exists(m.dstState()+"/active-fleet-svc.service") {
		t.Fatal("the destination was touched")
	}
	cs := reg.calls()
	if i := regFirst(cs, "renew"); i < 0 {
		t.Fatalf("no renew: %+v", cs)
	}
	for _, c := range cs {
		if c.verb == http.MethodDelete || c.act == "commit" || c.act == "retire" {
			t.Errorf("registry write after the takeover: %+v", c)
		}
	}
	if row := reg.rowNow("svc"); row.Token == "tok-1" || row.Host != "dst" || row.State != placementPrepared {
		t.Fatalf("row = %+v, want the other client's reservation left in place", row)
	}
	if exists(moveStatePath("svc")) {
		t.Error("the token of a taken-over move was kept")
	}
}

// A second `cnt move` of the same service on this machine, while the first
// holds the move lock, is refused before it reads the saved token: no remote
// call, no registry call, the token file as the first move left it. The lock
// is free again once its holder lets go.
func TestSecondMoveRefusedWhileTheFirstRuns(t *testing.T) {
	m, reg := moveOnRegistry(t)
	reg.hold("dst", "tok-held")
	p := moveStatePath("svc")
	held := `{"service":"svc","from":"src","to":"dst","token":"tok-held"}`
	must(t, os.MkdirAll(filepath.Dir(p), 0o700))
	must(t, os.WriteFile(p, []byte(held), 0o600))
	unlock, err := lockMove("svc")
	must(t, err)
	err = runMove(t)
	if err == nil || !strings.Contains(err.Error(), "another `cnt move svc` is running on this machine") {
		unlock()
		t.Fatalf("expected the held lock to refuse the move, got %v", err)
	}
	if c := m.calls(); c != "" {
		t.Errorf("the refused move made remote calls:\n%s", c)
	}
	if cs := reg.calls(); len(cs) != 0 {
		t.Errorf("the refused move reached the registry: %+v", cs)
	}
	if got := readFile(t, p); got != held {
		t.Errorf("token file = %q, want it untouched", got)
	}
	if row := reg.rowNow("svc"); row.Token != "tok-held" {
		t.Errorf("row = %+v, want the first move's reservation untouched", row)
	}
	unlock()
	again, err := lockMove("svc")
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	again()
}
