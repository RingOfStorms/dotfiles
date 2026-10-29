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
	run  map[string]map[string]bool // host -> services it reports
	down map[string]error           // host -> fetch error
	now  time.Time
}

func sp(s string) *string { return &s }

func newRig(t *testing.T) *rig {
	t.Helper()
	r := &rig{t: t, now: time.Unix(1_000_000, 0), run: map[string]map[string]bool{}, down: map[string]error{}}
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
func (r *rig) status(ctx context.Context, host string) (map[string]bool, error) {
	if err, ok := r.down[host]; ok {
		return nil, err
	}
	out := map[string]bool{}
	for k, v := range r.run[host] {
		out[k] = v
	}
	return out, nil
}

// up makes host report exactly these services.
func (r *rig) up(host string, svcs ...string) {
	r.run[host] = map[string]bool{}
	for _, s := range svcs {
		r.run[host][s] = true
	}
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

func (r *rig) reserve(svc, host string, force bool) (int, map[string]any) {
	r.t.Helper()
	return r.call("POST", "/api/placements/reserve", Request{Service: svc, Host: host, Force: force})
}

func (r *rig) commit(svc string) (int, map[string]any) {
	r.t.Helper()
	return r.call("POST", "/api/placements/commit", Request{Service: svc})
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
	r.up("h003", "app")
	if c, out := r.commit("app"); c != 200 {
		t.Fatalf("commit: %d %v", c, out)
	}
	if got := r.s.export().Host["app"]; got != "h003" {
		t.Fatalf("committed host %q", got)
	}

	// Both report it: expected until retire, so this is not a split brain.
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Conflict != "" {
		t.Fatalf("conflict during a normal move: %q", m.Conflict)
	}

	// Retire, then the source stops reporting: the rollback binding drops.
	if c, out := r.call("POST", "/api/placements/retire", Request{Service: "app"}); c != 200 {
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
	if c, out := r.call("DELETE", "/api/placements/app", nil); c != 200 {
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
	if c, out := r.call("DELETE", "/api/placements/app", nil); c != 200 {
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
	if c, _ := r.call("POST", "/api/placements/retire", Request{Service: "app"}); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.call("DELETE", "/api/placements/app", nil); c != 409 || !strings.Contains(out["error"].(string), "retired") {
		t.Fatalf("rollback onto a retired source: %d %v", c, out)
	}
	if c, _ := r.call("DELETE", "/api/placements/app?force=1", nil); c != 200 {
		t.Fatal(c)
	}
	if m := r.s.rows["app"]; m.Host != "h001" {
		t.Fatalf("forced rollback left %+v", m)
	}

	// A service with no prior binding is simply removed.
	r.up("h001", "app", "web")
	if c, _ := r.reserve("web", "h001", false); c != 200 {
		t.Fatal(c)
	}
	if c, _ := r.commit("web"); c != 200 {
		t.Fatal(c)
	}
	if c, out := r.call("DELETE", "/api/placements/web", nil); c != 200 {
		t.Fatalf("delete single: %d %v", c, out)
	}
	if _, ok := r.s.rows["web"]; ok {
		t.Fatal("single placement not removed")
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

// TestPlacementReservationExpires: a reservation that never cut over rolls
// back, because the source was left serving.
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
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	if m := r.s.rows["app"]; m.Host != "h001" || m.State != Committed || m.Previous != nil || m.ReserveSince != 0 {
		t.Fatalf("expired reservation left %+v", m)
	}
	if a := r.auditLog(); !strings.Contains(a, `"action":"sweep"`) || !strings.Contains(a, "expired") {
		t.Errorf("audit lacks the expiry:\n%s", a)
	}

	// A first placement that never committed has nowhere to roll back to.
	if c, _ := r.reserve("db", "h003", false); c != 200 {
		t.Fatal(c)
	}
	r.now = r.now.Add(ReserveTTL + time.Minute)
	r.s.Sweep(context.Background())
	if _, ok := r.s.rows["db"]; ok {
		t.Fatal("abandoned first placement kept")
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
	again, err := New(r.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if m := again.rows["app"]; m == nil || m.Host != "h001" || m.State != Prepared {
		t.Fatalf("row %+v", m)
	}
	if fi, err := os.Stat(filepath.Join(r.s.cfg.StateDir, "placements.json")); err != nil {
		t.Fatal(err)
	} else if fi.Mode().Perm() != 0o600 {
		t.Fatalf("state mode %v", fi.Mode().Perm())
	}
}

// TestPlacementStatusFetcher covers kind filtering and an unreachable host.
func TestPlacementStatusFetcher(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Query().Get("bad") != "" {
			http.Error(w, "boom", 500)
			return
		}
		_, _ = w.Write([]byte(`{"host":"h001","services":{
			"app":{"kind":"nixos"},"pod":{"kind":"podman"},"old":{"kind":""},"unit":{"kind":"host"}}}`))
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
	if len(svcs) != 3 || !svcs["app"] || !svcs["pod"] || !svcs["old"] || svcs["unit"] {
		t.Fatalf("services %v", svcs)
	}
	if _, err := get(context.Background(), "h003"); err == nil {
		t.Fatal("host without a url reported success")
	}
}
