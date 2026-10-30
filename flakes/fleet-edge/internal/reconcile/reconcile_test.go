package reconcile

import (
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

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgevhost"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
)

func sp(s string) *string { return &s }

type fakeEdge struct {
	files     map[string]edgevhost.Request
	log       []string
	fail      error            // every call
	addEr     map[string]error // add of one fqdn
	afterList func()           // runs after each list (a writer racing the reconciler)
}

func entry(fq string, v edgevhost.Request) edgevhost.Entry {
	return edgevhost.Entry{FQDN: fq, Host: v.Host, Until: v.Until, Kind: v.Kind}
}

// Do mimics the receiver, including its owner fences (edgevhost.Handle).
func (f *fakeEdge) Do(_ context.Context, r edgevhost.Request) ([]byte, error) {
	if f.fail != nil {
		return nil, f.fail
	}
	f.log = append(f.log, r.Op+" "+r.FQDN)
	cur, have := f.files[r.FQDN]
	switch r.Op {
	case "add":
		if err := f.addEr[r.FQDN]; err != nil {
			return nil, err
		}
		if have && r.Kind == edgevhost.KindPlacement && entry(r.FQDN, cur).LiveExpose(time.Now()) {
			return []byte(edgevhost.KeptPrefix + "expose on " + cur.Host + "\nok add " + r.FQDN + "\n"), nil
		}
		f.files[r.FQDN] = r
	case "remove":
		if have && (cur.Kind != r.Kind || (r.Host != "" && cur.Host != r.Host)) {
			return []byte(edgevhost.KeptPrefix + edgevhost.KindName(cur.Kind) + " on " + cur.Host + "\n"), nil
		}
		delete(f.files, r.FQDN)
	case "list":
		l := []edgevhost.Entry{}
		for k, v := range f.files {
			l = append(l, entry(k, v))
		}
		if f.afterList != nil {
			f.afterList()
		}
		return json.Marshal(l)
	}
	return nil, nil
}

func (f *fakeEdge) ops(op string) int {
	n := 0
	for _, l := range f.log {
		if strings.HasPrefix(l, op+" ") {
			n++
		}
	}
	return n
}

type rig struct {
	t        *testing.T
	r        *Reconciler
	edge     *fakeEdge
	tail     string
	lan      string
	exp      placements.Export
	srcErr   error
	resolved map[string][]string // server/fqdn -> answer
}

func newRig(t *testing.T) *rig {
	t.Helper()
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"immich": {Name: "immich", Routes: map[string]inventory.Route{
				"web": {FQDN: sp("photos.example.com"), Proto: "http", Exposure: "public", Via: []string{"edge"},
					MaxBody: "50000m", Timeouts: "600s", Websockets: true},
			}},
			"arr": {Name: "arr", Routes: map[string]inventory.Route{
				"sonarr": {FQDN: sp("sonarr.example.com"), Proto: "http", Exposure: "tailnet"},
				"jelly":  {FQDN: sp("jellyfin.example.com"), Proto: "http", Exposure: "lan"},
				"own":    {FQDN: sp("arr.example.com"), Proto: "http", Exposure: "local"},
			}},
			"minecraft": {Name: "minecraft", Routes: map[string]inventory.Route{
				"game": {FQDN: sp("minecraft.example.com"), Proto: "tcp", Exposure: "public", Via: []string{"router"}},
			}},
		},
		Hosts: map[string]inventory.Host{
			"h001": {OverlayIP: sp("100.64.0.13"), LanIP: sp("10.12.14.10")},
			"h003": {OverlayIP: sp("100.64.0.20"), LanIP: sp("10.12.14.30")},
			"lio":  {OverlayIP: sp("100.64.0.4")},
		},
	}
	rg := &rig{t: t, edge: &fakeEdge{files: map[string]edgevhost.Request{}}, tail: t.TempDir(), lan: t.TempDir(),
		exp: placements.Export{Host: map[string]string{}}, resolved: map[string][]string{}}
	r, err := New(Config{Inventory: inv, TailnetDir: rg.tail, LANDir: rg.lan, Edge: rg.edge,
		TailnetServer: "100.64.0.3:53", LANServer: "127.0.0.1:9053",
		Source: func() (placements.Export, error) { return rg.exp, rg.srcErr },
		Lookup: func(_ context.Context, server, fq string) ([]string, error) {
			return rg.resolved[server+"/"+fq], nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	rg.r = r
	return rg
}

func (rg *rig) place(svc, host, state string) {
	rg.exp.Rows = append(rg.exp.Rows, &placements.Row{Service: svc, Host: host, State: state})
	rows := rg.exp.Rows
	rg.exp = placements.Export{Rows: rows, Host: map[string]string{}}
	for _, r := range rows {
		if h := r.Effective(); h != "" {
			rg.exp.Host[r.Service] = h
		}
	}
}

func (rg *rig) unplace(svc string) {
	var rows []*placements.Row
	for _, r := range rg.exp.Rows {
		if r.Service != svc {
			rows = append(rows, r)
		}
	}
	rg.exp.Rows = nil
	for _, r := range rows {
		rg.place(r.Service, r.Host, r.State)
	}
	if len(rows) == 0 {
		rg.exp = placements.Export{Host: map[string]string{}}
	}
}

func (rg *rig) file(dir, fq string) string {
	b, err := os.ReadFile(filepath.Join(dir, fq))
	if err != nil {
		return ""
	}
	return string(b)
}

func (rg *rig) pass() Report {
	rep := rg.r.Pass(context.Background())
	return rep
}

func TestPassWritesBothHostsdirsAndTheEdge(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.place("arr", "lio", placements.Committed)
	rep := rg.pass()
	if len(rep.Errors) != 1 || !strings.Contains(rep.Errors[0], "no LAN IP") {
		t.Fatalf("errors %v", rep.Errors)
	}
	if got := rg.file(rg.tail, "photos.example.com"); got != "100.64.0.13 photos.example.com\n" {
		t.Errorf("tailnet photos %q", got)
	}
	if got := rg.file(rg.lan, "photos.example.com"); got != "10.12.14.10 photos.example.com\n" {
		t.Errorf("lan photos %q", got)
	}
	if got := rg.file(rg.tail, "sonarr.example.com"); got != "100.64.0.4 sonarr.example.com\n" {
		t.Errorf("tailnet sonarr %q", got)
	}
	// tailnet-only route: no LAN record; lan route on a host without a LAN IP: none either.
	for _, fq := range []string{"sonarr.example.com", "jellyfin.example.com"} {
		if rg.file(rg.lan, fq) != "" {
			t.Errorf("lan %s written", fq)
		}
	}
	if rg.file(rg.tail, "arr.example.com") != "" || rg.file(rg.tail, "minecraft.example.com") != "" {
		t.Error("local route or unplaced service got a name")
	}
	fi, err := os.Stat(filepath.Join(rg.tail, "photos.example.com"))
	if err != nil || fi.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v %v", fi, err)
	}
	v := rg.edge.files["photos.example.com"]
	if v.Kind != edgevhost.KindPlacement || v.Host != "h001" || v.Until != 0 || v.MaxBody != "50000m" || !v.RequestBuffering || !v.Websockets {
		t.Fatalf("vhost %+v", v)
	}
	if len(rg.edge.files) != 1 {
		t.Fatalf("edge %v", rg.edge.files)
	}
	// Steady state: nothing rewritten, nothing pushed, only the list.
	rg.edge.log = nil
	if rep := rg.pass(); len(rep.Changes) != 0 || rg.edge.ops("add") != 0 {
		t.Fatalf("second pass %v %v", rep.Changes, rg.edge.log)
	}
}

// The first pass after a start pushes every wanted vhost (route settings only
// change with a rebuild); later passes push only what o002 lacks.
func TestFirstPassPushesEveryVhost(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.edge.files["photos.example.com"] = edgevhost.Request{Kind: edgevhost.KindPlacement, FQDN: "photos.example.com", Host: "h001", MaxBody: "1m"}
	rg.pass()
	if rg.edge.ops("add") != 1 || rg.edge.files["photos.example.com"].MaxBody != "50000m" {
		t.Fatalf("log %v files %v", rg.edge.log, rg.edge.files)
	}
	// o002 rebooted (its dir is not persisted): re-pushed.
	delete(rg.edge.files, "photos.example.com")
	rg.edge.log = nil
	rg.pass()
	if rg.edge.ops("add") != 1 {
		t.Fatalf("re-push %v", rg.edge.log)
	}
}

// A move: the new answer lands, and the unplaced service's names go only after.
func TestMoveAndUnplace(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.pass()
	rg.unplace("immich")
	rg.place("immich", "h003", placements.Committed)
	rg.pass()
	if got := rg.file(rg.tail, "photos.example.com"); got != "100.64.0.20 photos.example.com\n" {
		t.Errorf("moved %q", got)
	}
	if rg.edge.files["photos.example.com"].Host != "h003" {
		t.Errorf("edge %+v", rg.edge.files)
	}
	rg.unplace("immich")
	rg.edge.log = nil
	rg.pass()
	if rg.file(rg.tail, "photos.example.com") != "" || rg.file(rg.lan, "photos.example.com") != "" {
		t.Error("unplaced name still answered")
	}
	if _, ok := rg.edge.files["photos.example.com"]; ok || rg.edge.ops("remove") != 1 {
		t.Errorf("edge %v log %v", rg.edge.files, rg.edge.log)
	}
}

// A prepared move keeps answering with the source; a first placement that has
// not committed has no name yet.
func TestPreparedRows(t *testing.T) {
	rg := newRig(t)
	rg.exp = placements.Export{Rows: []*placements.Row{
		{Service: "immich", Host: "h003", State: placements.Prepared, Previous: &placements.Binding{Host: "h001"}},
		{Service: "arr", Host: "lio", State: placements.Prepared},
	}, Host: map[string]string{"immich": "h001"}}
	rg.pass()
	if got := rg.file(rg.tail, "photos.example.com"); got != "100.64.0.13 photos.example.com\n" {
		t.Errorf("prepared move %q", got)
	}
	if rg.file(rg.tail, "sonarr.example.com") != "" {
		t.Error("uncommitted first placement answered")
	}
}

// A fenced row keeps whatever answers now, on every layer.
func TestStaleRowKeepsTheLastAnswer(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.pass()
	rg.exp = placements.Export{Rows: []*placements.Row{{Service: "immich", Host: "h003", State: placements.Stale}}, Host: map[string]string{}}
	rep := rg.pass()
	if got := rg.file(rg.tail, "photos.example.com"); got != "100.64.0.13 photos.example.com\n" {
		t.Errorf("stale dropped tailnet %q (%v)", got, rep.Changes)
	}
	if rg.file(rg.lan, "photos.example.com") == "" || rg.edge.files["photos.example.com"].Host != "h001" {
		t.Errorf("stale dropped lan/edge %v", rg.edge.files)
	}
	v := rg.r.Verify(context.Background())
	kept := 0
	for _, c := range v.Checks {
		if c.Status == Kept {
			kept++
		}
	}
	if kept != 3 {
		t.Errorf("verify %+v", v.Checks)
	}
}

// An unreadable registry, an unreachable o002 or a host with no address
// change nothing.
func TestFailClosed(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.place("arr", "lio", placements.Committed)
	rg.pass()
	good := rg.exp
	rg.srcErr = errors.New("boom")
	rg.exp = placements.Export{Host: map[string]string{}}
	if rep := rg.pass(); len(rep.Errors) == 0 || len(rep.Changes) != 0 {
		t.Fatalf("registry down %+v", rep)
	}
	if rg.file(rg.tail, "photos.example.com") == "" || len(rg.edge.files) != 1 {
		t.Fatal("registry down removed names")
	}
	rg.srcErr = nil
	rg.exp = good
	rg.edge.fail = errors.New("ssh: connect timeout")
	if rep := rg.pass(); len(rep.Errors) == 0 {
		t.Fatalf("o002 down %+v", rep)
	}
	rg.edge.fail = nil
	if len(rg.edge.files) != 1 {
		t.Fatal("o002 down changed the edge")
	}
	// Host gone from the inventory: its names stand, and it is reported.
	rg.place("immich", "ghost", placements.Committed)
	rg.exp.Host["immich"] = "ghost"
	rep := rg.pass()
	if rg.file(rg.tail, "photos.example.com") != "100.64.0.13 photos.example.com\n" || rg.edge.files["photos.example.com"].Host != "h001" {
		t.Fatalf("unaddressable host changed answers %v", rep)
	}
	if len(rep.Errors) == 0 || !strings.Contains(strings.Join(rep.Errors, ";"), "ghost") {
		t.Fatalf("errors %v", rep.Errors)
	}
}

// Adds land before removals, and a failed add holds that layer's removals.
func TestAddBeforeRemove(t *testing.T) {
	rg := newRig(t)
	rg.edge.files["old.example.com"] = edgevhost.Request{Kind: edgevhost.KindPlacement, FQDN: "old.example.com", Host: "h001"}
	rg.edge.files["shared.example.com"] = edgevhost.Request{FQDN: "shared.example.com", Host: "h001", Until: 99}
	rg.place("immich", "h001", placements.Committed)
	rg.edge.addEr = map[string]error{"photos.example.com": errors.New("already served by this edge's own config")}
	rg.pass()
	if _, ok := rg.edge.files["old.example.com"]; !ok {
		t.Fatal("removed before the add landed")
	}
	rg.edge.addEr = nil
	rg.edge.log = nil
	rg.pass()
	if len(rg.edge.log) < 3 || rg.edge.log[1] != "add photos.example.com" || rg.edge.log[2] != "remove old.example.com" {
		t.Fatalf("order %v", rg.edge.log)
	}
	if _, ok := rg.edge.files["shared.example.com"]; !ok {
		t.Fatal("an expose override was removed")
	}
}

// A live expose override on a placed public name wins for its lifetime: the
// placement add is skipped (or kept by the receiver when the expose lands
// after the list), the audit calls it kept, and the placement vhost returns
// on the first pass after the expose is gone.
func TestLiveExposeWinsOverPlacement(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	edgeChanges := func(rep Report) string {
		var out []string
		for _, c := range rep.Changes {
			if strings.HasPrefix(c, "o002: ") {
				out = append(out, c)
			}
		}
		return strings.Join(out, ";")
	}
	expose := edgevhost.Request{FQDN: "photos.example.com", Host: "h003", Until: time.Now().Add(time.Hour).Unix()}
	rg.edge.files["photos.example.com"] = expose
	rep := rg.pass()
	if rg.edge.ops("add") != 0 || rg.edge.files["photos.example.com"] != expose {
		t.Fatalf("placement add over a live expose: log %v files %v", rg.edge.log, rg.edge.files)
	}
	if got := edgeChanges(rep); got != "o002: photos.example.com kept: expose on h003" {
		t.Fatalf("changes %v", rep.Changes)
	}
	v := rg.r.Verify(context.Background())
	kept := 0
	for _, c := range v.Checks {
		if c.Layer == Edge && c.FQDN == "photos.example.com" && c.Status == Kept {
			kept++
		}
	}
	if kept != 1 {
		t.Errorf("audit %+v", v.Checks)
	}

	// Expired: the placement takes the name back.
	expired := expose
	expired.Until = time.Now().Add(-time.Minute).Unix()
	rg.edge.files["photos.example.com"] = expired
	rg.pass()
	if f := rg.edge.files["photos.example.com"]; f.Kind != edgevhost.KindPlacement || f.Host != "h001" {
		t.Fatalf("expired expose not replaced: %+v", f)
	}

	// An expose that lands between the list and the add is kept by the
	// receiver, and the pass reports it rather than a change.
	delete(rg.edge.files, "photos.example.com")
	rg.edge.afterList = func() { rg.edge.files["photos.example.com"] = expose }
	rep = rg.pass()
	if rg.edge.files["photos.example.com"] != expose {
		t.Fatalf("racing expose overwritten: %+v", rg.edge.files["photos.example.com"])
	}
	if got := edgeChanges(rep); got != "o002: photos.example.com kept: expose on h003" {
		t.Fatalf("changes %v", rep.Changes)
	}
}

// The hostsdir must exist (dnsmasq only watches one present at start); temp
// files left by a crash are cleared, and unknown names are removed.
func TestHostsdirHygiene(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	_ = os.WriteFile(filepath.Join(rg.tail, "photos.example.com.new"), []byte("1.2.3.4 photos.example.com\n"), 0o644)
	_ = os.WriteFile(filepath.Join(rg.tail, "gone.example.com"), []byte("1.2.3.4 gone.example.com\n"), 0o644)
	rg.pass()
	ents, _ := os.ReadDir(rg.tail)
	if len(ents) != 1 || ents[0].Name() != "photos.example.com" {
		t.Fatalf("dir %v", ents)
	}
	_ = os.RemoveAll(rg.lan)
	if rep := rg.pass(); !strings.Contains(strings.Join(rep.Errors, ";"), "missing") {
		t.Fatalf("missing dir %v", rep.Errors)
	}
	if _, err := os.Stat(rg.lan); !os.IsNotExist(err) {
		t.Fatal("hostsdir created by the reconciler")
	}
}

func TestVerify(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.pass()
	rg.resolved["100.64.0.3:53/photos.example.com"] = []string{"100.64.0.13"}
	rg.resolved["127.0.0.1:9053/photos.example.com"] = []string{"10.12.14.99"}
	_ = os.WriteFile(filepath.Join(rg.tail, "stray.example.com"), []byte("1.2.3.4 stray.example.com\n"), 0o644)
	rg.edge.files["photos.example.com"] = edgevhost.Request{Kind: edgevhost.KindPlacement, FQDN: "photos.example.com", Host: "h003"}
	got := map[string]string{}
	for _, c := range rg.r.Verify(context.Background()).Checks {
		got[c.Layer+" "+c.FQDN] = c.Status
	}
	want := map[string]string{
		"tailnet photos.example.com":    OK,
		"lan photos.example.com":        Wrong, // dnsmasq answers something else
		"tailnet stray.example.com":     Extra,
		"edge photos.example.com":       Wrong,
		"tailnet sonarr.example.com":    OK,
		"lan sonarr.example.com":        OK,
		"tailnet jellyfin.example.com":  OK,
		"lan jellyfin.example.com":      OK,
		"tailnet minecraft.example.com": OK,
		"lan minecraft.example.com":     OK,
	}
	for k, s := range want {
		if got[k] != s {
			t.Errorf("%s: %q want %q", k, got[k], s)
		}
	}
	if len(got) != len(want) {
		t.Errorf("checks %v", got)
	}
	// Verify writes nothing.
	if rg.file(rg.tail, "stray.example.com") == "" || rg.edge.files["photos.example.com"].Host != "h003" {
		t.Fatal("verify changed state")
	}
}

type denyAll struct{ ok bool }

func (d denyAll) Authenticate(*http.Request) (authority.Caller, error) {
	if d.ok {
		return authority.Caller{Host: "oren"}, nil
	}
	return authority.Caller{}, errors.New("no token")
}

func TestHandlerNeedsAWriter(t *testing.T) {
	rg := newRig(t)
	w := httptest.NewRecorder()
	rg.r.Handler(denyAll{}).ServeHTTP(w, httptest.NewRequest("GET", "/api/placements/routing", nil))
	if w.Code != 401 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	rg.r.Handler(denyAll{ok: true}).ServeHTTP(w, httptest.NewRequest("GET", "/api/placements/routing", nil))
	var v Verify
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &v) != nil {
		t.Fatal(w.Code, w.Body.String())
	}
}

func TestMissingIPKeepsOldLANFile(t *testing.T) {
	rg := newRig(t)
	rg.place("immich", "h001", placements.Committed)
	rg.pass()
	rg.exp.Host["immich"] = "lio"
	rg.pass()
	if got := rg.file(rg.lan, "photos.example.com"); got != "10.12.14.10 photos.example.com\n" {
		t.Fatal(got)
	}
}

func TestPendingReloadChangesNoEdgeFiles(t *testing.T) {
	rg := newRig(t)
	rg.edge.files["old.example.com"] = edgevhost.Request{Kind: edgevhost.KindPlacement, Host: "h001"}
	rg.place("immich", "h001", placements.Committed)
	rg.edge.fail = errors.New("reload pending")
	rg.pass()
	if len(rg.edge.files) != 1 || rg.edge.files["old.example.com"].Host != "h001" {
		t.Fatal(rg.edge.files)
	}
	v := rg.r.Verify(context.Background())
	found := false
	for _, c := range v.Checks {
		if c.Layer == Edge && c.Status == Pending {
			found = true
		}
	}
	if !found {
		t.Fatal(v)
	}
}

func TestAuditDetectsAnswerWithoutFile(t *testing.T) {
	rg := newRig(t)
	rg.resolved["100.64.0.3:53/photos.example.com"] = []string{"100.64.0.13"}
	for _, c := range rg.r.Verify(context.Background()).Checks {
		if c.Layer == Tailnet && c.FQDN == "photos.example.com" {
			if c.Status != Wrong {
				t.Fatal(c)
			}
			return
		}
	}
	t.Fatal("unplaced route was not checked")
}
