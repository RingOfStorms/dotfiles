package placements

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// Writers in the rig: oren (the default caller) and lio, with their real
// subs and overlay IPs.
const (
	orenSub  = "364267099884879875"
	orenPeer = "100.64.0.2"
	lioSub   = "344412093056811011"
	lioPeer  = "100.64.0.1"
)

// stubVerifier maps "good-<sub>" to a subject and rejects anything else.
type stubVerifier struct{}

func (stubVerifier) VerifyZitadelToken(raw string) (auth.VerifiedToken, error) {
	sub, ok := strings.CutPrefix(raw, "good-")
	if !ok {
		return auth.VerifiedToken{}, errors.New("bad token")
	}
	return auth.VerifiedToken{Subject: sub}, nil
}

type rig struct {
	t    *testing.T
	s    *Service
	run  map[string]map[string]ServiceState // host -> installed units and whether they run
	down map[string]error                   // host -> fetch error
	now  time.Time
	tok  string // the token of the last reserve, as the CLI keeps it
}

func sp(s string) *string { return &s }

func newRig(t *testing.T) *rig {
	t.Helper()
	r := &rig{t: t, now: time.Unix(1_000_000, 0), run: map[string]map[string]ServiceState{}, down: map[string]error{}}
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"app":  {Name: "app"},
			"web":  {Name: "web"},
			"db":   {Name: "db"},
			"keep": {Name: "keep"},
		},
		Hosts: map[string]inventory.Host{
			"lio":  {OverlayIP: sp(lioPeer)},
			"h001": {OverlayIP: sp("100.64.0.11")},
			"h003": {OverlayIP: sp("100.64.0.13")},
		},
		ContainerHosts: []string{"h001", "h003", "lio"},
	}
	au, err := authority.New(
		map[string]authority.Writer{"oren": {Sub: orenSub, Peer: orenPeer}, "lio": {Sub: lioSub, Peer: lioPeer}},
		stubVerifier{}, func() time.Time { return r.now })
	if err != nil {
		t.Fatal(err)
	}
	s, err := New(Config{Inventory: inv, StateDir: t.TempDir(), Auth: au, Now: func() time.Time { return r.now }})
	if err != nil {
		t.Fatal(err)
	}
	r.s = s
	return r
}

// status is the fake fleet-agent each host answers with.
func (r *rig) status(ctx context.Context, host string) (map[string]ServiceState, error) {
	if err, ok := r.down[host]; ok {
		return nil, err
	}
	out := map[string]ServiceState{}
	for k, v := range r.run[host] {
		out[k] = v
	}
	return out, nil
}

// up makes host run exactly these services: installed and active.
func (r *rig) up(host string, svcs ...string) {
	r.run[host] = map[string]ServiceState{}
	for _, s := range svcs {
		r.run[host][s] = ServiceState{Installed: true, Active: true}
	}
	delete(r.down, host)
}

// stop leaves the units installed but stops them, the state a move puts the
// source in between the switch and the uninstall.
func (r *rig) stop(host string, svcs ...string) {
	for _, s := range svcs {
		r.run[host][s] = ServiceState{Installed: true}
	}
	delete(r.down, host)
}

// gone uninstalls the units on host, leaving it reachable.
func (r *rig) gone(host string) {
	r.run[host] = map[string]ServiceState{}
	delete(r.down, host)
}

// call is a request through nginx (loopback + X-Fleet-Peer) as oren.
func (r *rig) call(method, path string, body any) (int, map[string]any) {
	r.t.Helper()
	return r.callTok(method, path, orenPeer, "good-"+orenSub, body)
}

func (r *rig) callTok(method, path, peer, tok string, body any) (int, map[string]any) {
	r.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(b))
	req.RemoteAddr = "127.0.0.1:5555"
	if peer != "" {
		req.Header.Set("X-Fleet-Peer", peer)
	}
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	w := httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// reserve prepares a placement and keeps the token, as the CLI does, so the
// later steps of the same move can present it.
func (r *rig) reserve(svc, host string, force bool) (int, map[string]any) {
	r.t.Helper()
	c, out := r.call("POST", "/api/placements/reserve", Request{Service: svc, Host: host, Force: force})
	if m, ok := out["row"].(map[string]any); ok {
		r.tok, _ = m["token"].(string)
	}
	return c, out
}

func (r *rig) commit(svc string) (int, map[string]any) {
	r.t.Helper()
	return r.call("POST", "/api/placements/commit", Request{Service: svc, Token: r.tok})
}

// del rolls the placement back, presenting the move's token.
func (r *rig) del(svc string, force bool) (int, map[string]any) {
	r.t.Helper()
	path := "/api/placements/" + svc + "?token=" + r.tok
	if force {
		path += "&force=1"
	}
	return r.call("DELETE", path, nil)
}

// delRev removes a placement on the strength of the revision the caller read,
// the tokenless path an operator takes once the move that made it has ended.
func (r *rig) delRev(svc string, rev int64) (int, map[string]any) {
	r.t.Helper()
	return r.call("DELETE", "/api/placements/"+svc+"?revision="+strconv.FormatInt(rev, 10), nil)
}

func row(t *testing.T, out map[string]any) map[string]any {
	t.Helper()
	m, ok := out["row"].(map[string]any)
	if !ok {
		t.Fatalf("no row in %v", out)
	}
	return m
}

func (r *rig) auditLog() string {
	b, _ := os.ReadFile(filepath.Join(r.s.cfg.StateDir, "placements-audit.log"))
	return string(b)
}

// TestPlacementFirstPlacement is the bootstrap single placement: no previous
// binding, so it becomes live as soon as it is committed.
func TestPlacementFirstPlacement(t *testing.T) {
	r := newRig(t)
	r.up("h001", "app")
	if c, out := r.reserve("app", "h001", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	if got := r.s.export().Host["app"]; got != "" {
		t.Fatalf("prepared first placement is live on %q", got)
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}
	if got := r.s.export().Host["app"]; got != "h001" {
		t.Fatalf("committed host %q", got)
	}
	if m := r.s.rows["app"]; m.Previous != nil || m.State != Committed {
		t.Fatalf("row %+v", m)
	}
	if a := r.auditLog(); !strings.Contains(a, `"host":"oren","sub":"`+orenSub+`"`) || !strings.Contains(a, `"action":"commit"`) {
		t.Errorf("audit lacks host/sub/action:\n%s", a)
	}
}

// TestPlacementMove covers the corrected ordering: reserve before the source
// stops, the source keeps serving and stays the rollback target, commit after
// routing cutover, retire only afterwards.
func TestPlacementMove(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")

	if c, out := r.reserve("app", "h001", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d", c)
	}

	// Reserve the move; the source still serves and still owns DNS.
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve move: %d %v", c, out)
	}
	if got := r.s.export().Host["app"]; got != "h001" {
		t.Fatalf("reserved move already live on %q", got)
	}
	if m := r.s.rows["app"]; m.Previous == nil || m.Previous.Host != "h001" || m.State != Prepared {
		t.Fatalf("row %+v", m)
	}

	// Commit refuses until the destination reports the service.
	if c, out := r.commit("app"); c != 409 || !strings.Contains(out["error"].(string), "does not report app") {
		t.Fatalf("commit without the destination: %d %v", c, out)
	}
	// The move stops the source before it commits (step 3 before step 7), so the
	// source is installed but stopped while the destination takes the name.
	r.stop("h001", "app")
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}
	if got := r.s.export().Host["app"]; got != "h003" {
		t.Fatalf("committed host %q", got)
	}

	// The stopped source still holds the rollback binding and serves nothing, so
	// this is not a split brain.
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Conflict != "" || m.Previous == nil || m.Token == "" {
		t.Fatalf("conflict during a normal move: %+v", m)
	}

	// Retire, then the source stops reporting: the rollback binding drops.
	if c, out := r.call("POST", "/api/placements/retire", Request{Service: "app", Token: r.tok}); c != 200 {
		t.Fatalf("retire: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.State != Retiring {
		t.Fatalf("state %q", m.State)
	}
	r.up("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Previous != nil || m.State != Committed {
		t.Fatalf("retired source still remembered: %+v", m)
	}
}

// TestPlacementRollback restores the prior binding; it never deletes it.
func TestPlacementRollback(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	// Roll a prepared move back: the row returns to the source.
	if c, out := r.del("app", false); c != 200 {
		t.Fatalf("delete prepared: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed || m.Previous != nil {
		t.Fatalf("row %+v", m)
	}

	// Roll a committed move back: same, and the binding survives. The
	// destination is deployed after the reservation, as the CLI does.
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	r.up("h003", "app")
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.del("app", false); c != 200 {
		t.Fatalf("delete committed: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed {
		t.Fatalf("row %+v", m)
	}

	// A retired source refuses a plain rollback: its data was renamed.
	r.up("h003")
	if c, _ := r.reserve("app", "h003", false); c != 200 {
		t.Fatal(c)
	}
	r.up("h003", "app")
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.call("POST", "/api/placements/retire", Request{Service: "app", Token: r.tok}); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.del("app", false); c != 409 || !strings.Contains(out["error"].(string), "retired") {
		t.Fatalf("rollback onto a retired source: %d %v", c, out)
	}
	if c, _ := r.del("app", true); c != 200 {
		t.Fatal(c)
	}
	if m := r.s.rows["app"]; m.Host != "h001" {
		t.Fatalf("forced rollback left %+v", m)
	}

	// A service with no prior binding is simply removed. The commit above ended
	// the move (nothing to retire), so its token is spent: the delete names the
	// revision it read instead.
	r.up("h001", "app", "web")
	if c, _ := r.reserve("web", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("web"); c != 200 {
		t.Fatal(c)
	}
	if m := r.s.rows["web"]; m.Token != "" {
		t.Fatalf("committed single placement kept a token: %+v", m)
	}
	if c, out := r.del("web", false); c != 409 || !strings.Contains(out["error"].(string), "has ended") {
		t.Fatalf("delete with a spent token: %d %v", c, out)
	}
	if _, ok := r.s.rows["web"]; !ok {
		t.Fatal("refused delete removed the row")
	}
	if c, out := r.delRev("web", r.s.rows["web"].Revision); c != 200 {
		t.Fatalf("delete single: %d %v", c, out)
	}
	if _, ok := r.s.rows["web"]; ok {
		t.Fatal("single placement not removed")
	}
}

// TestPlacementConcurrentReserveRefused: the second of two interleaved moves
// is refused while the first still holds the reservation, so the losing client
// never believes it owns a destination it does not.
func TestPlacementConcurrentReserveRefused(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	r.up("lio")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("A reserves: %d %v", c, out)
	}
	a := r.s.rows["app"].Token

	// B, a different writer, tries to move the same service elsewhere.
	c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "lio"})
	if c != 409 || !strings.Contains(out["error"].(string), "reserve refused") {
		t.Fatalf("B's reserve: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h003" || m.State != Prepared || m.Token != a {
		t.Fatalf("B's refused reserve changed the row: %+v", m)
	}

	// Once A's move is finished — committed *and* its source uninstalled, so the
	// rollback binding and the token are gone — B may reserve the next one.
	r.up("h003", "app")
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	r.gone("h001")
	r.s.Sweep(context.Background())
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "lio"}); c != 200 {
		t.Fatalf("B's reserve after the move ended: %d %v", c, out)
	}
}

// TestPlacementStaleTokenAfterTakeover: a forced takeover invalidates the old
// token, so the client that lost cannot commit or roll back the new binding.
func TestPlacementStaleTokenAfterTakeover(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("A reserves: %d %v", c, out)
	}
	stale := r.tok

	// B overrides by hand: an explicit takeover, not a silent one.
	c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h003", Force: true})
	if c != 200 {
		t.Fatalf("B's forced reserve: %d %v", c, out)
	}
	fresh, _ := row(t, out)["token"].(string)
	if fresh == "" || fresh == stale {
		t.Fatalf("takeover token %q (stale %q)", fresh, stale)
	}

	if c, out := r.call("POST", "/api/placements/commit", Request{Service: "app", Token: stale}); c != 409 || !strings.Contains(out["error"].(string), "commit refused") {
		t.Fatalf("stale commit: %d %v", c, out)
	}
	if c, out := r.call("DELETE", "/api/placements/app?token="+stale, nil); c != 409 || !strings.Contains(out["error"].(string), "rollback refused") {
		t.Fatalf("stale rollback: %d %v", c, out)
	}
	// The takeover's destination reports the service, as the CLI awaits before
	// committing.
	r.up("h003", "app")
	if m := r.s.rows["app"]; m.Host != "h003" || m.State != Prepared || m.Token != fresh {
		t.Fatalf("stale token touched the row: %+v", m)
	}
	// The current holder still can.
	if c, out := r.callTok("POST", "/api/placements/commit", lioPeer, "good-"+lioSub, Request{Service: "app", Token: fresh}); c != 200 {
		t.Fatalf("B commits: %d %v", c, out)
	}
}

// TestPlacementTakeoverRollback: B's rollback restores A's committed binding,
// not the destination B itself had reserved.
func TestPlacementTakeoverRollback(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("lio")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	// A moves the service to h003 and commits: h003 is now the live binding.
	r.up("h003")
	if c, _ := r.reserve("app", "h003", false); c != 200 {
		t.Fatal(c)
	}
	r.up("h003", "app")
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	// A's move is finished once h001 no longer has the unit: that drops
	// the rollback binding and the token, so the next move is a plain one.
	r.gone("h001")
	r.s.Sweep(context.Background())
	// B starts another move; the rollback target is the committed binding.
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "lio"}); c != 200 {
		t.Fatalf("B reserves: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Previous == nil || m.Previous.Host != "h003" {
		t.Fatalf("rollback target %+v", m)
	}
	tok := r.s.rows["app"].Token
	if c, out := r.callTok("DELETE", "/api/placements/app?token="+tok, lioPeer, "good-"+lioSub, nil); c != 200 {
		t.Fatalf("B rolls back: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h003" || m.State != Committed || m.Previous != nil || m.Token != "" {
		t.Fatalf("rollback left %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h003" {
		t.Fatalf("exported host %q", h)
	}
}

// TestPlacementRefusals covers the checks that stop a harmful placement.
func TestPlacementRefusals(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003", "app", "db")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	for _, tc := range []struct {
		name, svc, host string
		force           bool
		want            int
		msg             string
	}{
		{name: "unknown service", svc: "nope", host: "h003", want: 404, msg: "unknown service"},
		{name: "unknown host", svc: "app", host: "o002", want: 409, msg: "not a container host"},
		{name: "no host", svc: "app", want: 400, msg: "host is required"},
		{name: "destination holds it", svc: "app", host: "h003", want: 409, msg: "already runs on h003"},
		{name: "already there", svc: "app", host: "h001", want: 409, msg: "already placed on h001"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if c, out := r.reserve(tc.svc, tc.host, tc.force); c != tc.want || !strings.Contains(out["error"].(string), tc.msg) {
				t.Fatalf("got %d %v, want %d %q", c, out, tc.want, tc.msg)
			}
		})
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed {
		t.Fatalf("a refusal moved the row: %+v", m)
	}
	// Commit needs a reservation, and a reservation for the host asked about.
	if c, out := r.commit("db"); c != 404 || !strings.Contains(out["error"].(string), "no placement") {
		t.Fatalf("commit with no row: %d %v", c, out)
	}
	if c, _ := r.reserve("db", "h001", true); c != 200 {
		t.Fatalf("reserve db: %d", c)
	}
	if c, out := r.call("POST", "/api/placements/commit", Request{Service: "db", Host: "h003"}); c != 409 {
		t.Fatalf("commit wrong host: %d %v", c, out)
	}
}

// TestPlacementUnreachableKeepsRow: a host that does not answer changes
// nothing; a split brain is flagged and never resolved.
func TestPlacementUnreachableKeepsRow(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	r.down["h001"] = errors.New("dial tcp: connection refused")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Host != "h001" || !strings.Contains(m.LastError, "unknown until h001 answers") {
		t.Fatalf("row %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h001" {
		t.Fatalf("host %q", h)
	}

	// Two hosts report it: flagged, still bound where it was committed.
	r.up("h001", "app")
	r.up("h003", "app")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Conflict != "h003" {
		t.Fatalf("conflict %q", m.Conflict)
	}
	if c := r.s.export().Conflicts["app"]; c != "h003" {
		t.Fatalf("exported conflict %q", c)
	}
	if h := r.s.export().Host["app"]; h != "h001" {
		t.Fatalf("split brain moved the service to %q", h)
	}

	// The bound host stops reporting it: recorded, not deleted, no grace.
	r.up("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.HostMissingSince == 0 || !strings.Contains(m.LastError, "not running on h001") {
		t.Fatalf("row %+v", m)
	}
	// Reporting again clears both, once the stray copy is gone too.
	r.up("h001", "app")
	r.up("h003")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.HostMissingSince != 0 || m.LastError != "" || m.Conflict != "" {
		t.Fatalf("row %+v", m)
	}
}

// TestPlacementReservationExpires: a reservation that outlives its lease is
// fenced as stale, not rolled back. A move stops its source before it restores
// the destination, so "the reservation expired" does not imply "the source
// still serves" — rolling back on that assumption routes the name at a host
// that may be stopped. The row keeps its token (a second move is still refused)
// and stops claiming an effective host until recover asks.
func TestPlacementReservationExpires(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	m := r.s.rows["app"]
	if m.State != Stale || m.Host != "h003" || m.Previous == nil || m.Previous.Host != "h001" {
		t.Fatalf("expired reservation left %+v", m)
	}
	if m.Token != tok {
		t.Fatalf("fence dropped the token: %q want %q", m.Token, tok)
	}
	// Nothing routes: the destination never committed and the source is only
	// assumed to serve, which is the assumption fencing rejects.
	if h := r.s.export().Host["app"]; h != "" {
		t.Fatalf("fenced row advertises %q", h)
	}
	if a := r.auditLog(); !strings.Contains(a, `"action":"sweep"`) || !strings.Contains(a, "fenced until recover") {
		t.Errorf("audit lacks the fence:\n%s", a)
	}
	// It stays fenced: another client cannot take the binding, and its holder
	// cannot quietly commit or roll it back either.
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001"}); c != 409 || !strings.Contains(out["error"].(string), "owns the reservation") {
		t.Fatalf("second client reserved a fenced row: %d %v", c, out)
	}
	if c, out := r.commit("app"); c != 409 || !strings.Contains(out["error"].(string), "--recover") {
		t.Fatalf("fenced commit: %d %v", c, out)
	}
	if c, out := r.del("app", false); c != 409 || !strings.Contains(out["error"].(string), "recover") {
		t.Fatalf("blind rollback of a fenced row: %d %v", c, out)
	}
	// The source is serving, so recover restores it and ends the move.
	r.up("h001", "app")
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok}); c != 200 {
		t.Fatalf("recover: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed || m.Previous != nil || m.Token != "" || m.ReserveSince != 0 {
		t.Fatalf("recovered row %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h001" {
		t.Fatalf("recovered host %q", h)
	}

	// A first placement that never committed has nowhere to roll back to, and
	// is fenced all the same rather than dropped: dropping it would let the
	// next client reserve over a half-restored host.
	if c, _ := r.reserve("db", "h003", false); c != 200 {
		t.Fatal(c)
	}
	dbTok := r.tok
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	if m, ok := r.s.rows["db"]; !ok || m.State != Stale || m.Token != dbTok || m.Previous != nil {
		t.Fatalf("abandoned first placement: %+v", m)
	}
	if h := r.s.export().Host["db"]; h != "" {
		t.Fatalf("fenced first placement advertises %q", h)
	}
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "db", Host: "h001"}); c != 409 {
		t.Fatalf("second client took a fenced first placement: %d %v", c, out)
	}
	// Nothing answers for it: recover refuses rather than invent a binding.
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "db", Token: dbTok}); c != 409 || !strings.Contains(out["error"].(string), "first placement never landed") {
		t.Fatalf("recover of a lost first placement: %d %v", c, out)
	}
	// Forced: the operator has decided the destination is the answer.
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "db", Token: dbTok, Force: true}); c != 200 {
		t.Fatalf("forced recover: %d %v", c, out)
	}
	if m := r.s.rows["db"]; m.State != Committed || m.Host != "h003" || m.Token != "" {
		t.Fatalf("forced recovery left %+v", m)
	}
}

// TestPlacementImport is the one-time bootstrap: existing rows are kept
// unless force, and a bad entry imports nothing.
func TestPlacementImport(t *testing.T) {
	r := newRig(t)
	imp := Import{User: "josh", Reason: "bootstrap", Placements: []Placement{{Service: "app", Host: "h001"}, {Service: "web", Host: "h003"}}}
	c, out := r.call("POST", "/api/placements/import", imp)
	if c != 200 {
		t.Fatalf("import: %d %v", c, out)
	}
	if got := r.s.export().Host; got["app"] != "h001" || got["web"] != "h003" {
		t.Fatalf("hosts %v", got)
	}
	if m := r.s.rows["app"]; m.User != "josh" || m.State != Committed {
		t.Fatalf("row %+v", m)
	}

	// Without force the existing row wins.
	c, out = r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "app", Host: "h003"}}})
	if c != 200 {
		t.Fatalf("re-import: %d %v", c, out)
	}
	if skipped, _ := out["skipped"].([]any); len(skipped) != 1 {
		t.Fatalf("skipped %v", out["skipped"])
	}
	if m := r.s.rows["app"]; m.Host != "h001" {
		t.Fatalf("import overwrote without force: %+v", m)
	}
	// With force it adopts the observed placement.
	if c, _ := r.call("POST", "/api/placements/import", Import{Force: true, Placements: []Placement{{Service: "app", Host: "h003"}}}); c != 200 {
		t.Fatal(c)
	}
	if m := r.s.rows["app"]; m.Host != "h003" {
		t.Fatalf("forced import: %+v", m)
	}

	// One bad entry rejects the whole import, existing rows untouched.
	for _, tc := range []struct {
		name string
		imp  Import
		want int
	}{
		{"unknown service", Import{Placements: []Placement{{Service: "nope", Host: "h001"}}}, 404},
		{"unknown host", Import{Placements: []Placement{{Service: "keep", Host: "o002"}}}, 409},
		{"duplicate", Import{Placements: []Placement{{Service: "keep", Host: "h001"}, {Service: "keep", Host: "h003"}}}, 400},
		{"empty", Import{}, 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if c, out := r.call("POST", "/api/placements/import", tc.imp); c != tc.want {
				t.Fatalf("got %d %v, want %d", c, out, tc.want)
			}
			if _, ok := r.s.rows["keep"]; ok {
				t.Fatal("a rejected import wrote a row")
			}
		})
	}
}

// TestPlacementAuth: only a listed writer, from its own overlay IP, and the
// loopback export only from loopback without an X-Fleet-Peer override.
func TestPlacementAuth(t *testing.T) {
	r := newRig(t)
	for _, tc := range []struct {
		name, peer, tok string
	}{
		{"unknown sub", orenPeer, "good-111111111111111111"},
		{"bad token", orenPeer, "nope"},
		{"missing token", orenPeer, ""},
		{"wrong source ip", lioPeer, "good-" + orenSub},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if c, _ := r.callTok("POST", "/api/placements/reserve", tc.peer, tc.tok, Request{Service: "app", Host: "h001"}); c != 401 {
				t.Fatalf("got %d, want 401", c)
			}
			if len(r.s.rows) != 0 {
				t.Fatalf("a refused request reserved a row: %v", r.s.rows)
			}
		})
	}
	if a := r.auditLog(); !strings.Contains(a, `"result":"denied"`) {
		t.Errorf("audit lacks the refusals:\n%s", a)
	}

	// lio may write too, and the row records it.
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001"}); c != 200 {
		t.Fatalf("lio: %d %v", c, out)
	}
	if d := r.s.rows["app"].Device; d != "lio" {
		t.Fatalf("device %q", d)
	}

	// The export is loopback-only and rejects a proxied header.
	req := httptest.NewRequest("GET", "/internal/placements.json", nil)
	req.RemoteAddr = "100.64.0.9:1"
	w := httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	if w.Code != 403 {
		t.Fatalf("non-loopback export: %d", w.Code)
	}
	req = httptest.NewRequest("GET", "/internal/placements.json", nil)
	req.RemoteAddr = "127.0.0.1:1"
	req.Header.Set("X-Fleet-Peer", orenPeer)
	w = httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	if w.Code != 403 {
		t.Fatalf("proxied export: %d", w.Code)
	}
	req = httptest.NewRequest("GET", "/internal/placements.json", nil)
	req.RemoteAddr = "127.0.0.1:1"
	w = httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("loopback export: %d", w.Code)
	}
	var ex Export
	if err := json.Unmarshal(w.Body.Bytes(), &ex); err != nil {
		t.Fatal(err)
	}
	if ex.Rows == nil || len(ex.Rows) != 1 {
		t.Fatalf("export %+v", ex)
	}
}

// TestPlacementStatePersists: the registry survives a restart.
func TestPlacementStatePersists(t *testing.T) {
	r := newRig(t)
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	rev := r.s.rows["app"].Revision
	again, err := New(r.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if m := again.rows["app"]; m == nil || m.Host != "h001" || m.State != Prepared {
		t.Fatalf("row %+v", m)
	}
	// The incarnation and the counter behind it are both in the file, so a
	// reader's revision stays valid across a restart and the next write goes
	// above it rather than restarting the numbering.
	if m := again.rows["app"]; m.Revision != rev || again.rev < rev {
		t.Fatalf("revision %d did not survive the reload (row %d, counter %d)", rev, m.Revision, again.rev)
	}
	if fi, err := os.Stat(filepath.Join(r.s.cfg.StateDir, "placements.json")); err != nil {
		t.Fatal(err)
	} else if fi.Mode().Perm() != 0o600 {
		t.Fatalf("state mode %v", fi.Mode().Perm())
	}
}

// TestPlacementStatusFetcher covers kind filtering, the installed/active split
// and an unreachable host.
func TestPlacementStatusFetcher(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Query().Get("bad") != "" {
			http.Error(w, "boom", 500)
			return
		}
		_, _ = w.Write([]byte(`{"host":"h001","services":{
			"app":{"kind":"nixos","active":"active"},
			"pod":{"kind":"podman","active":"active"},
			"old":{"kind":"","active":"inactive"},
			"unit":{"kind":"host","active":"active"}}}`))
	}))
	defer srv.Close()
	get := HTTPHostServices(func(host string) (string, bool) {
		if host == "h003" {
			return "", false
		}
		return srv.URL + "/status.json", true
	})
	svcs, err := get(context.Background(), "h001")
	if err != nil {
		t.Fatal(err)
	}
	if len(svcs) != 3 {
		t.Fatalf("services %v", svcs)
	}
	if !svcs["app"].Running() || !svcs["pod"].Running() {
		t.Fatalf("active copies %v", svcs)
	}
	// Installed but stopped: the state a move leaves the source in.
	if s := svcs["old"]; !s.Installed || s.Active || s.Running() {
		t.Fatalf("stopped copy %+v", s)
	}
	if _, ok := svcs["unit"]; ok {
		t.Fatal("host unit read as a container")
	}
	if _, err := get(context.Background(), "h003"); err == nil {
		t.Fatal("host without a url reported success")
	}
}

// TestPlacementStoppedSourceKeepsBinding: a move stops the source before it
// uninstalls it. The sweep must read that as "not serving" for health and as
// "still installed" for the rollback binding, otherwise it drops the way back
// while the source's data is still the only copy.
func TestPlacementStoppedSourceKeepsBinding(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}

	// The source is stopped for the switch but still installed, and the copy on
	// it is not serving: no split brain either.
	r.stop("h001", "app")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Previous == nil || m.Previous.Host != "h001" {
		t.Fatalf("stopped source dropped its binding: %+v", m)
	}
	if m := r.s.rows["app"]; m.Conflict != "" {
		t.Fatalf("stopped copy read as a split brain: %q", m.Conflict)
	}
	if v := r.s.verify(context.Background()); v.Bound["app"] != "ok" || len(v.Stray) != 0 {
		t.Fatalf("verify %+v", v)
	}

	// Uninstalled: now the binding goes, and with it the token.
	r.gone("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Previous != nil || m.State != Committed || m.Token != "" {
		t.Fatalf("uninstalled source kept the binding: %+v", m)
	}
}

// TestPlacementImportSkipsStoppedCopy: the import adopts only a *serving*
// copy. A stale unit that is installed but stopped is not a placement, and the
// service stays unplaced (the registry's "unowned/offline").
func TestPlacementImportSkipsStoppedCopy(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.run["h003"] = map[string]ServiceState{"web": {Installed: true}} // stopped
	r.down["lio"] = errors.New("dial tcp: connection refused")

	c, out := r.call("POST", "/api/placements/import", Import{Placements: []Placement{
		{Service: "app", Host: "h001"}, // active: adopted
		{Service: "web", Host: "h003"}, // installed but stopped: skipped
		{Service: "db", Host: "lio"},   // unreachable: skipped, not guessed
	}})
	if c != 200 {
		t.Fatalf("import: %d %v", c, out)
	}
	if got := r.s.export().Host; got["app"] != "h001" || got["web"] != "" || got["db"] != "" {
		t.Fatalf("hosts %v", got)
	}
	skipped, _ := out["skipped"].([]any)
	if len(skipped) != 2 {
		t.Fatalf("skipped %v", out["skipped"])
	}
	if _, ok := r.s.rows["web"]; ok {
		t.Fatal("stopped copy imported")
	}
	if _, ok := r.s.rows["db"]; ok {
		t.Fatal("unreachable host imported on a guess")
	}

	// Once it actually serves, the import adopts it.
	r.up("h003", "web")
	if c, out := r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "web", Host: "h003"}}}); c != 200 {
		t.Fatalf("import after start: %d %v", c, out)
	}
	if got := r.s.export().Host["web"]; got != "h003" {
		t.Fatalf("web host %q", got)
	}
}

// TestPlacementMoveOutlivesReserveTTL: a large service takes longer than the
// lease to back up, transfer and restore. Mid-move the source is stopped and
// the destination is not serving yet, which is exactly the state a rollback
// would get wrong. The row fences instead of routing anywhere, and the move's
// own holder can still finish it by renewing the lease.
func TestPlacementMoveOutlivesReserveTTL(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok

	// The move is in flight: the source is stopped for the switch, the new copy
	// is not up, and the clock passes the lease.
	r.stop("h001", "app")
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	m := r.s.rows["app"]
	if m.State != Stale || m.Host != "h003" || m.Previous == nil {
		t.Fatalf("long move: %+v", m)
	}
	// The one thing fencing must guarantee: the name is not pointed at the
	// stopped source by an automatic rollback.
	if h := r.s.export().Host["app"]; h != "" {
		t.Fatalf("fenced middle of a move routed to %q", h)
	}
	if v := r.s.verify(context.Background()); v.Bound["app"] != "stale" {
		t.Fatalf("verify %v", v)
	}

	// Renewing does not un-fence: the lease is evidence of nothing. The holder
	// re-reserves on the same host with its token to re-open the lease.
	if c, out := r.call("POST", "/api/placements/renew", Request{Service: "app", Token: tok}); c != 409 || !strings.Contains(out["error"].(string), "fenced") {
		t.Fatalf("renew of a fenced row: %d %v", c, out)
	}
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h003", Token: tok}); c != 200 {
		t.Fatalf("re-reserve: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.State != Prepared || m.Token != tok || m.Previous == nil || m.Previous.Host != "h001" {
		t.Fatalf("re-reserve left %+v", m)
	}
	// Renewal keeps a long move inside its lease: past the old deadline but
	// inside a fresh one, the sweep leaves it alone.
	r.now = r.now.Add(ReserveTTL - time.Minute)
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.State != Prepared {
		t.Fatalf("renewed lease was swept: %+v", m)
	}
	if c, out := r.call("POST", "/api/placements/renew", Request{Service: "app", Token: tok}); c != 200 {
		t.Fatalf("renew: %d %v", c, out)
	}

	// The move lands: commit with the token still works, and the source is
	// retired once it is actually uninstalled.
	r.up("h003", "app")
	if c, out := r.call("POST", "/api/placements/commit", Request{Service: "app", Token: tok}); c != 200 {
		t.Fatalf("commit after a long move: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.State != Committed || m.Host != "h003" || m.ReserveSince != 0 {
		t.Fatalf("committed long move: %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h003" {
		t.Fatalf("host %q", h)
	}
	r.gone("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Previous != nil || m.Token != "" {
		t.Fatalf("retired source kept %+v", m)
	}
}

// TestPlacementMoveAbandonedRecover: the same long move, but the client never
// comes back. Recovery is explicit and asks the hosts first: a source that is
// stopped but installed is still mid-move, so nothing is decided; once the move
// is known to have failed, the source is restored.
func TestPlacementMoveAbandonedRecover(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok
	r.stop("h001", "app")
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.State != Stale {
		t.Fatalf("row %+v", m)
	}

	// A recover by someone who does not hold the reservation is refused: the
	// fence is the holder's to release.
	if c, out := r.callTok("POST", "/api/placements/recover", lioPeer, "good-"+lioSub, Request{Service: "app"}); c != 409 {
		t.Fatalf("foreign recover: %d %v", c, out)
	}
	// Source stopped but installed, destination not running: still in flight.
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok}); c != 409 || !strings.Contains(out["error"].(string), "installed but stopped") {
		t.Fatalf("recover mid-move: %d %v", c, out)
	}
	// When the move is truly dead (nothing restored the destination, the source
	// came back up), recovery restores the prior binding even without force.
	r.up("h001", "app")
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok}); c != 200 {
		t.Fatalf("recover: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed || m.Previous != nil || m.Token != "" {
		t.Fatalf("recovered row %+v", m)
	}
	// The abandoned destination is not a stray: it was never serving.
	if m := r.s.rows["app"]; m.Conflict != "" {
		t.Fatalf("conflict %q", m.Conflict)
	}
	if v := r.s.verify(context.Background()); v.Bound["app"] != "ok" {
		t.Fatalf("verify %+v", v)
	}
}

// TestPlacementInterleavedClients: two writers moving the same service must not
// be able to interleave into a binding neither of them chose. The first reserve
// holds the token; the second is refused; a forced takeover invalidates the
// first client's handle, so its commit and its rollback both lose.
func TestPlacementInterleavedClients(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	// oren opens a move to h003 and holds its token.
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	orenTok := r.tok
	// lio tries to move the same service elsewhere: refused outright, because a
	// live reservation is not a hint that the binding is free.
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001"}); c != 409 || !strings.Contains(out["error"].(string), "owns the reservation") {
		t.Fatalf("overlapping reserve: %d %v", c, out)
	}
	// lio forces the takeover; the row now belongs to lio, who reserves h001
	// (a move back over the unchanged destination).
	c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001", Force: true})
	if c != 200 {
		t.Fatalf("forced takeover: %d %v", c, out)
	}
	lioTok, _ := row(t, out)["token"].(string)
	if lioTok == "" || lioTok == orenTok {
		t.Fatalf("takeover handle %q (old %q)", lioTok, orenTok)
	}
	// oren's now-stale handle cannot finish, retire or undo lio's move.
	if c, out := r.callTok("POST", "/api/placements/commit", orenPeer, "good-"+orenSub, Request{Service: "app", Token: orenTok}); c != 409 || !strings.Contains(out["error"].(string), "refused") {
		t.Fatalf("stale commit: %d %v", c, out)
	}
	if c, out := r.callTok("POST", "/api/placements/retire", orenPeer, "good-"+orenSub, Request{Service: "app", Token: orenTok}); c != 409 {
		t.Fatalf("stale retire: %d %v", c, out)
	}
	if c, out := r.callTok("DELETE", "/api/placements/app?token="+orenTok, orenPeer, "good-"+orenSub, nil); c != 409 {
		t.Fatalf("stale rollback: %d %v", c, out)
	}
	// lio finishes its own move; only then does the binding change hands.
	if c, out := r.callTok("POST", "/api/placements/commit", lioPeer, "good-"+lioSub, Request{Service: "app", Token: lioTok}); c != 200 {
		t.Fatalf("owner commit: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed {
		t.Fatalf("row %+v", m)
	}
}

// TestPlacementRevisionCAS: a write that carries no token (force, import) still
// cannot clobber a decision made since the caller read the row.
func TestPlacementRevisionCAS(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003", "app")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	rev := r.s.rows["app"].Revision
	// Someone else changes the row in the meantime (an import is tokenless, so
	// the only thing between it and a newer decision is the revision).
	if c, out := r.call("POST", "/api/placements/import", Import{Force: true, Placements: []Placement{{Service: "app", Host: "h003"}}}); c != 200 {
		t.Fatalf("forced import: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h003" || m.Revision == rev {
		t.Fatalf("forced import did not bump: %+v", m)
	}
	// A stale revision is refused rather than overwriting that decision.
	if c, out := r.call("POST", "/api/placements/import", Import{Revision: rev, Placements: []Placement{{Service: "app", Host: "h001"}}}); c != 409 || !strings.Contains(out["error"].(string), "changed since revision") {
		t.Fatalf("stale import: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h003" {
		t.Fatalf("stale import clobbered %+v", m)
	}
	// Echoing the current revision is accepted, even for a move that
	// overwrites an existing row (which otherwise needs force).
	cur := r.s.rows["app"].Revision
	if c, out := r.call("POST", "/api/placements/import", Import{Force: true, Revision: cur, Placements: []Placement{{Service: "app", Host: "h001"}}}); c != 200 {
		t.Fatalf("current-revision import: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed {
		t.Fatalf("revision-matched import left %+v", m)
	}
	// With the row moved on again, that same revision is now stale. (The CAS
	// runs before force is consulted, so it refuses a tokenless replayed write
	// either way; force is the documented way out of it.)
	if c, out := r.call("POST", "/api/placements/import", Import{Revision: cur, Placements: []Placement{{Service: "app", Host: "h003"}}}); c != 409 || !strings.Contains(out["error"].(string), "changed since revision") {
		t.Fatalf("replayed revision: %d %v", c, out)
	}
}

// TestPlacementReserveAfterLeaseLapses: the fence is the token, not the clock.
// A Prepared row whose lease ran out is still owned by its holder even before
// the sweep has marked it stale, so a second client cannot reserve over it — it
// would otherwise take a destination the running move may already be restoring.
func TestPlacementReserveAfterLeaseLapses(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, out := r.reserve("app", "h001", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok
	// Past the lease, with no sweep in between: the row is still Prepared.
	r.now = r.now.Add(ReserveTTL + time.Minute)
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h003"}); c != 409 || !strings.Contains(out["error"].(string), "owns the reservation") {
		t.Fatalf("second client reserved an expired but un-swept row: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Prepared || m.Token != tok {
		t.Fatalf("refused reserve still changed the row: %+v", m)
	}
	// The holder can still present its token: that is a renewal, which re-opens
	// the lease rather than starting a new move.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001", Token: tok}); c != 200 {
		t.Fatalf("holder renewal: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Token != tok || m.State != Prepared || m.ReserveSince != r.now.Unix() {
		t.Fatalf("renewal left %+v", m)
	}
}

// TestPlacementReserveWhileMoveCanStillRollBack: a committed move whose source
// is still installed has a token, so the binding is not free. Letting a second
// client reserve here abandons a rollback that still exists — the new row would
// take over the destination of a move in flight and orphan the old source.
func TestPlacementReserveWhileMoveCanStillRollBack(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("first reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("first commit: %d %v", c, out)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("move reserve: %d %v", c, out)
	}
	tok := r.tok
	// The move cut over: the destination serves, the source is stopped but
	// still installed, so the rollback binding and the token both remain.
	r.stop("h001", "app")
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.State != Committed || m.Token != tok || m.Previous == nil {
		t.Fatalf("committed move lost its token: %+v", m)
	}
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001"}); c != 409 || !strings.Contains(out["error"].(string), "owns the reservation") {
		t.Fatalf("second client reserved over a live move: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h003" || m.State != Committed || m.Token != tok || m.Previous.Host != "h001" {
		t.Fatalf("refused reserve still changed the row: %+v", m)
	}
	// The source is uninstalled: the move is over, so the sweep clears the token
	// and the next reserve is a plain one again.
	r.gone("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Token != "" || m.Previous != nil {
		t.Fatalf("sweep did not clear the finished move: %+v", m)
	}
	if c, out := r.callTok("POST", "/api/placements/reserve", lioPeer, "good-"+lioSub, Request{Service: "app", Host: "h001"}); c != 200 {
		t.Fatalf("reserve after the move ended: %d %v", c, out)
	}
}

// TestPlacementStaleTokenAfterMoveEnds: once the sweep clears the token because
// the source was uninstalled, a late DELETE from the client that made the move
// must not be read as "no token, so nobody reserved": the row still names the
// binding that move established, and with no Previous a delete would drop it.
func TestPlacementStaleTokenAfterMoveEnds(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("first reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("first commit: %d %v", c, out)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("move reserve: %d %v", c, out)
	}
	stale := r.tok
	r.stop("h001", "app")
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("move commit: %d %v", c, out)
	}
	if c, out := r.call("POST", "/api/placements/retire", Request{Service: "app", Token: stale}); c != 200 {
		t.Fatalf("retire: %d %v", c, out)
	}
	// The source is uninstalled: the move is over, and the sweep clears both the
	// rollback binding and the token, leaving the row a plain committed one.
	r.gone("h001")
	r.s.Sweep(context.Background())
	m := r.s.rows["app"]
	if m.State != Committed || m.Host != "h003" || m.Token != "" || m.Previous != nil {
		t.Fatalf("move did not end cleanly: %+v", m)
	}
	// The late DELETE carries the token the move was made with. It matches no
	// live reservation, so it is refused rather than treated as absent.
	if c, out := r.call("DELETE", "/api/placements/app?token="+stale, nil); c != 409 || !strings.Contains(out["error"].(string), "has ended") {
		t.Fatalf("stale delete after the move ended: %d %v", c, out)
	}
	if got := r.s.rows["app"]; got.Host != "h003" || got.State != Committed || got.Token != "" || got.Previous != nil {
		t.Fatalf("stale delete changed the row: %+v", got)
	}
	if h := r.s.export().Host["app"]; h != "h003" {
		t.Fatalf("stale delete dropped the binding: export %q", h)
	}

	// A bare DELETE is refused the same way: with no token, the caller must say
	// which revision it read, so the delete can only drop the row it saw.
	if c, out := r.call("DELETE", "/api/placements/app", nil); c != 409 || !strings.Contains(out["error"].(string), "revision") {
		t.Fatalf("unconditional delete: %d %v", c, out)
	}
	if _, ok := r.s.rows["app"]; !ok {
		t.Fatal("unconditional delete removed the row")
	}
	// A revision from before the move is a stale read: the row changed under it.
	if c, out := r.call("DELETE", "/api/placements/app?revision=1", nil); c != 409 || !strings.Contains(out["error"].(string), "changed since revision 1") {
		t.Fatalf("stale revision delete: %d %v", c, out)
	}
	if h := r.s.export().Host["app"]; h != "h003" {
		t.Fatalf("stale revision dropped the binding: export %q", h)
	}
	if c, out := r.call("DELETE", "/api/placements/app?revision=nope", nil); c != 400 {
		t.Fatalf("unparsable revision: %d %v", c, out)
	}
	// The revision it did read still ends the placement: that is the operator's
	// deliberate act, and it is the only tokenless way to do it.
	if c, out := r.delRev("app", m.Revision); c != 200 {
		t.Fatalf("delete at the current revision: %d %v", c, out)
	}
	if _, ok := r.s.rows["app"]; ok {
		t.Fatal("delete at the current revision left the row")
	}
	if h := r.s.export().Host["app"]; h != "" {
		t.Fatalf("deleted placement still advertises %q", h)
	}
}

// TestPlacementDelayedReserveAfterMoveEnds: a reserve is fenced by the move it
// names, not only by a token the row still carries. Once the sweep has cleared
// the token (the source was uninstalled) a replay carrying the old handle — or
// the revision it read — must be refused rather than start a new move against a
// binding it never reserved. Without the token check the replay looks like a
// fresh request, and the stale revision is what the row's counter has left
// behind.
func TestPlacementDelayedReserveAfterMoveEnds(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("first reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("first commit: %d %v", c, out)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("move reserve: %d %v", c, out)
	}
	stale := r.tok
	r.stop("h001", "app")
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("move commit: %d %v", c, out)
	}
	// The revision the delayed reserve would have been composed against.
	rev := r.s.rows["app"].Revision
	if c, out := r.call("POST", "/api/placements/retire", Request{Service: "app", Token: stale}); c != 200 {
		t.Fatalf("retire: %d %v", c, out)
	}
	r.gone("h001")
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.State != Committed || m.Host != "h003" || m.Token != "" {
		t.Fatalf("move did not end cleanly: %+v", m)
	}
	before := snapshot(r)
	// The old handle: the reservation it belongs to has ended.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001", Token: stale}); c != 409 || !strings.Contains(out["error"].(string), "has ended") {
		t.Fatalf("delayed reserve with the old token: %d %v", c, out)
	}
	before.check(t, r, "stale-token reserve")
	// The old revision: the row has been written since.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001", Revision: rev}); c != 409 || !strings.Contains(out["error"].(string), "changed since revision") {
		t.Fatalf("delayed reserve with the old revision: %d %v", c, out)
	}
	before.check(t, r, "stale-revision reserve")
	// Neither handle: a fresh request for the next move, which is allowed.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001"}); c != 200 {
		t.Fatalf("reserve after the refused replays: %d %v", c, out)
	}
}

// TestPlacementReserveCannotResurrect: a reserve that names a move on a service
// with no row at all can only belong to a placement that has since been
// deleted. Honouring it would resurrect the row the delete removed — with the
// caller's destination, and a fresh token minted for it. A first placement is
// composed with no handle, so refusing one is not a loss.
func TestPlacementReserveCannotResurrect(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}
	stale := r.tok
	rev := r.s.rows["app"].Revision
	if c, out := r.delRev("app", rev); c != 200 {
		t.Fatalf("delete: %d %v", c, out)
	}
	if _, ok := r.s.rows["app"]; ok {
		t.Fatal("delete left the row")
	}
	before := snapshot(r)
	// The old handle: it names a move on a placement that no longer exists.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001", Token: stale}); c != 409 || !strings.Contains(out["error"].(string), "was removed") {
		t.Fatalf("replay with the old token: %d %v", c, out)
	}
	before.check(t, r, "stale-token replay")
	if _, ok := r.s.rows["app"]; ok {
		t.Fatal("a refused replay created the row")
	}
	// The old revision, likewise: no row has it, and none should be minted.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001", Revision: rev}); c != 409 || !strings.Contains(out["error"].(string), "was removed") {
		t.Fatalf("replay with the old revision: %d %v", c, out)
	}
	before.check(t, r, "stale-revision replay")
	if _, ok := r.s.rows["app"]; ok {
		t.Fatal("a refused replay created the row")
	}
	// A first placement carries no handle, and still works.
	if c, out := r.call("POST", "/api/placements/reserve", Request{Service: "app", Host: "h001"}); c != 200 {
		t.Fatalf("unguarded first placement: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m == nil || m.State != Prepared || m.Host != "h001" {
		t.Fatalf("unguarded reserve did not place it: %+v", m)
	}
}

// TestPlacementDeleteCannotCrossIncarnation: the revision a tokenless DELETE
// names comes from a counter that outlives the row. Destroying a placement and
// redeploying it issues a new revision, so a delayed DELETE composed against the
// destroyed placement is stale rather than equal — it cannot delete its
// replacement.
func TestPlacementDeleteCannotCrossIncarnation(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("first reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("first commit: %d %v", c, out)
	}
	rev := r.s.rows["app"].Revision
	// The operator ends the placement on the strength of the revision it read.
	if c, out := r.delRev("app", rev); c != 200 {
		t.Fatalf("delete: %d %v", c, out)
	}
	if _, ok := r.s.rows["app"]; ok {
		t.Fatal("delete left the row")
	}
	// A restart must not restart the numbering either: the counter is in the
	// state file, not in the rows it outlives.
	again, err := New(r.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	r.s = again
	// The service is deployed again from nothing: a fresh row, so the number
	// the destroyed one held must not come back with it.
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal("redeploy reserve")
	}
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("redeploy commit: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Revision <= rev {
		t.Fatalf("replacement reused revision %d: %+v", rev, m)
	}
	// The delayed DELETE from the destroyed deployment arrives now.
	if c, out := r.delRev("app", rev); c != 409 || !strings.Contains(out["error"].(string), "changed since revision") {
		t.Fatalf("replayed delete: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m == nil || m.Host != "h001" || m.State != Committed {
		t.Fatalf("replayed delete damaged the replacement: %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h001" {
		t.Fatalf("replayed delete unbound the service: export %q", h)
	}
}

// TestPlacementRecoverSplitBrain: both copies of a fenced move report the
// service. Neither end is authoritative, so a non-forced recover refuses and
// names both hosts rather than picking one and stranding the other; the row
// keeps its fence until an operator stops a copy or forces a choice.
func TestPlacementRecoverSplitBrain(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok

	// The move stopped short: the source never stopped, the destination already
	// answers, and the reservation expires.
	r.up("h001", "app")
	r.up("h003", "app")
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	before := *r.s.rows["app"]
	if before.State != Stale {
		t.Fatalf("row %+v", before)
	}

	c, out := r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok})
	if c != 409 {
		t.Fatalf("split-brain recover: %d %v", c, out)
	}
	msg, _ := out["error"].(string)
	if !strings.Contains(msg, "h001") || !strings.Contains(msg, "h003") {
		t.Fatalf("refusal names neither copy: %q", msg)
	}
	if m := r.s.rows["app"]; m.State != Stale || m.Host != "h003" || m.Previous == nil || m.Previous.Host != "h001" || m.Revision != before.Revision || m.Token != tok || m.Effective() != "" {
		t.Fatalf("refused recover changed the row: %+v", m)
	}

	// A silent host proves nothing either, even with the other end serving: the
	// quiet one is the copy that could still answer.
	r.down["h001"] = errors.New("dial tcp: connection refused")
	c, out = r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok})
	if c != 409 || !strings.Contains(out["error"].(string), "did not answer") {
		t.Fatalf("recover with a silent source: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.State != Stale || m.Host != "h003" || m.Revision != before.Revision {
		t.Fatalf("silent-source recover changed the row: %+v", m)
	}

	// Force is the operator's decision. With a previous binding to go back to it
	// restores that one, so the source copy is the one they have chosen to keep.
	if c, out := r.call("POST", "/api/placements/recover", Request{Service: "app", Token: tok, Force: true}); c != 200 {
		t.Fatalf("forced recover: %d %v", c, out)
	}
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed || m.Previous != nil || m.Token != "" {
		t.Fatalf("forced recovery left %+v", m)
	}
	if h := r.s.export().Host["app"]; h != "h001" {
		t.Fatalf("forced recovery advertised %q", h)
	}
}

// TestPlacementSweepSplitBrainPrevious: the source comes back up after the move
// committed. Both copies now serve the name, and the sweep must say so instead
// of treating the previous host as expected company — without retiring it,
// since nothing has been resolved.
func TestPlacementSweepSplitBrainPrevious(t *testing.T) {
	r := newRig(t)
	r.s.cfg.Status = r.status
	r.up("h001", "app")
	r.up("h003")
	if c, _ := r.reserve("app", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("app"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.reserve("app", "h003", false); c != 200 {
		t.Fatalf("reserve: %d %v", c, out)
	}
	tok := r.tok
	r.stop("h001", "app")
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}

	// A stopped-but-installed source is the normal post-commit state.
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Conflict != "" {
		t.Fatalf("conflict before the source returned: %+v", m)
	}

	// The source is back up beside the committed destination.
	r.up("h001", "app")
	r.s.Sweep(context.Background())
	m := r.s.rows["app"]
	if m.Conflict != "h001" {
		t.Fatalf("sweep missed the split brain: %+v", m)
	}
	if got := r.s.export().Conflicts["app"]; got != "h001" {
		t.Fatalf("exported conflict %q", got)
	}
	if m.Host != "h003" || m.Previous == nil || m.Previous.Host != "h001" || m.Token != tok || m.State != Committed {
		t.Fatalf("conflict resolved the move: %+v", m)
	}
	if got := r.s.export().Host["app"]; got != "h003" {
		t.Fatalf("conflict moved the binding to %q", got)
	}
	// verify agrees: the destination answers and the source is the stray copy.
	if v := r.s.verify(context.Background()); v.Bound["app"] != "ok" || v.Stray["app"] != "h001" {
		t.Fatalf("verify %+v", v)
	}

	// Stopping the source clears the flag; the rollback binding stays put.
	r.stop("h001", "app")
	r.s.Sweep(context.Background())
	m = r.s.rows["app"]
	if m.Conflict != "" {
		t.Fatalf("conflict survived the source stopping: %+v", m)
	}
	if m.Previous == nil || m.Previous.Host != "h001" {
		t.Fatalf("rollback binding lost: %+v", m)
	}
}

// fingerprint is the state a failed write must leave alone: everything the
// export shows and the revision counter behind it.
type fingerprint struct {
	exp Export
	rev int64
}

func snapshot(r *rig) fingerprint { return fingerprint{exp: r.s.export(), rev: r.s.rev} }

// broke makes the state writes fail, as a full or read-only state dir would,
// and returns a function that puts the real one back.
func (r *rig) broke() func() {
	r.s.write = func(string, []byte, os.FileMode) error {
		return errors.New("injected: state dir read-only")
	}
	return func() { r.s.write = os.WriteFile }
}

// check asserts that a request which could not save changed nothing: not the
// export, not the counter, and not what a restart would load.
func (f fingerprint) check(t *testing.T, r *rig, what string) {
	t.Helper()
	if got := r.s.export(); !reflect.DeepEqual(got, f.exp) {
		t.Fatalf("%s: a write that could not be saved still changed memory:\n got %+v\nwant %+v", what, got, f.exp)
	}
	if r.s.rev != f.rev {
		t.Fatalf("%s: counter advanced to %d on a failed write, want %d", what, r.s.rev, f.rev)
	}
	again, err := New(r.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.export(); !reflect.DeepEqual(got, f.exp) {
		t.Fatalf("%s: a restart loaded %+v, want %+v", what, got, f.exp)
	}
	if again.rev != f.rev {
		t.Fatalf("%s: a restart loaded counter %d, want %d", what, again.rev, f.rev)
	}
}

// TestPlacementSaveFailureLeavesStateUntouched: a write is persisted before it
// is visible. When the state cannot be written the request is a 500 and the
// registry keeps exactly the state a restart would restore — no binding only
// this process believes in, and no revision spent on a write nobody has.
func TestPlacementSaveFailureLeavesStateUntouched(t *testing.T) {
	t.Run("reserve", func(t *testing.T) {
		r := newRig(t)
		r.s.cfg.Status = r.status
		r.up("h001", "app")
		before := snapshot(r)
		restore := r.broke()
		c, out := r.reserve("app", "h001", false)
		restore()
		if c != 500 {
			t.Fatalf("reserve with an unwritable state dir: %d %v", c, out)
		}
		// A failed write hands back no row: the revision in it would name a
		// binding nothing holds, and a client would CAS on it.
		if out["row"] != nil {
			t.Fatalf("a failed reserve reported a row: %v", out["row"])
		}
		before.check(t, r, "reserve")
		if r.s.rows["app"] != nil {
			t.Fatalf("a failed reserve left the row behind: %+v", r.s.rows["app"])
		}
	})

	t.Run("commit", func(t *testing.T) {
		r := newRig(t)
		r.s.cfg.Status = r.status
		r.up("h001", "app")
		if c, out := r.reserve("app", "h001", false); c != 200 {
			t.Fatalf("reserve: %d %v", c, out)
		}
		tok := r.tok
		before := snapshot(r)
		restore := r.broke()
		if c, out := r.commit("app"); c != 500 {
			t.Fatalf("commit with an unwritable state dir: %d %v", c, out)
		}
		restore()
		before.check(t, r, "commit")
		if m := r.s.rows["app"]; m == nil || m.State != Prepared || m.Token != tok {
			t.Fatalf("a failed commit moved the placement: %+v", m)
		}
		// The move is exactly where it was, token and all, so it still commits.
		if c, out := r.commit("app"); c != 200 {
			t.Fatalf("commit after the state dir came back: %d %v", c, out)
		}
	})

	t.Run("rollback", func(t *testing.T) {
		r := newRig(t)
		r.s.cfg.Status = r.status
		r.up("h001", "app")
		r.up("h003", "app")
		if c, _ := r.reserve("app", "h001", false); c != 200 {
			t.Fatal(c)
		}
		if c, out := r.commit("app"); c != 200 {
			t.Fatalf("commit: %d %v", c, out)
		}
		if c, out := r.reserve("app", "h003", true); c != 200 {
			t.Fatalf("reserve: %d %v", c, out)
		}
		if c, out := r.commit("app"); c != 200 {
			t.Fatalf("commit: %d %v", c, out)
		}
		before := snapshot(r)
		restore := r.broke()
		if c, out := r.del("app", false); c != 500 {
			t.Fatalf("rollback with an unwritable state dir: %d %v", c, out)
		}
		restore()
		before.check(t, r, "rollback")
		if m := r.s.rows["app"]; m == nil || m.Host != "h003" || m.Previous == nil {
			t.Fatalf("a failed rollback restored the previous binding: %+v", m)
		}
	})

	t.Run("drop", func(t *testing.T) {
		r := newRig(t)
		r.s.cfg.Status = r.status
		r.up("h001", "web")
		if c, _ := r.reserve("web", "h001", false); c != 200 {
			t.Fatal(c)
		}
		if c, out := r.commit("web"); c != 200 {
			t.Fatalf("commit: %d %v", c, out)
		}
		rev := r.s.rows["web"].Revision
		before := snapshot(r)
		restore := r.broke()
		if c, out := r.delRev("web", rev); c != 500 {
			t.Fatalf("delete with an unwritable state dir: %d %v", c, out)
		}
		restore()
		before.check(t, r, "delete")
		if m := r.s.rows["web"]; m == nil || m.Host != "h001" {
			t.Fatalf("a failed delete dropped the row from memory: %+v", m)
		}
	})

	t.Run("sweep", func(t *testing.T) {
		r := newRig(t)
		r.s.cfg.Status = r.status
		r.up("h001", "app")
		if c, _ := r.reserve("app", "h001", false); c != 200 {
			t.Fatal(c)
		}
		// Let the reservation lapse: the sweep would fence it stale, and that
		// batch has to be persisted whole or dropped whole.
		r.now = r.now.Add(ReserveTTL + 1)
		before := snapshot(r)
		restore := r.broke()
		r.s.Sweep(context.Background())
		restore()
		before.check(t, r, "sweep")
		if m := r.s.rows["app"]; m == nil || m.State != Prepared {
			t.Fatalf("a sweep that could not save still fenced the row: %+v", m)
		}
		if log := r.auditLog(); strings.Contains(log, "outlived its lease") {
			t.Fatalf("the audit log recorded a change nobody persisted:\n%s", log)
		}
		r.s.Sweep(context.Background())
		if m := r.s.rows["app"]; m == nil || m.State != Stale {
			t.Fatalf("sweep after the state dir came back: %+v", m)
		}
	})
}
