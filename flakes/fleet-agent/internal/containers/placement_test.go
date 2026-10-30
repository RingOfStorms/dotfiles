package containers

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// ------------------------------------------------------------ resolution

// resolutionRig pins everything resolveHost reads: the registry view (nil when
// the registry has no row), the discovery probe and the dry-run switch. rows
// carry the reservation tokens the host map alone cannot express. The returned
// counter says how many hosts were probed, so a path that must not probe can
// assert that.
func resolutionRig(t *testing.T, bound map[string]string, rows map[string]placementRow, installed map[string][]string, down ...string) *atomic.Int64 {
	t.Helper()
	oldInv, oldDry, oldLocal, oldProbe, oldNow := inv, dryRun, localHost, fleetProbe, placementNow
	t.Cleanup(func() {
		inv, dryRun, localHost, fleetProbe, placementNow = oldInv, oldDry, oldLocal, oldProbe, oldNow
		registryCache = nil
	})
	inv = &Inventory{
		Services:       map[string]Service{"svc": {Name: "svc", Dir: "svc", Kind: "podman", Host: "src"}},
		Hosts:          map[string]Host{"src": {User: "root"}, "dst": {User: "root"}},
		ContainerHosts: []string{"src", "dst"},
	}
	localHost = "not-a-fleet-host"
	dryRun = false
	var probes atomic.Int64
	fp := fakeFleet(installed, down...)
	fleetProbe = func(ctx context.Context, h string) ([]row, error) {
		probes.Add(1)
		return fp(ctx, h)
	}
	placementNow = func(bool) *placementView {
		if bound == nil {
			return nil
		}
		return &placementView{Host: bound, Rows: rows}
	}
	registryCache = nil
	return &probes
}

// TestResolveHostMatrix is the resolution rule in one table: the registry row
// wins, discovery decides when there is no row, --host only fills a gap, and
// nothing is guessed from silence or from two copies. `probes` counts the
// discovery probes, so "must not touch the fleet" is an assertion too: every
// container host is probed once per locate (two hosts here).
func TestResolveHostMatrix(t *testing.T) {
	cases := []struct {
		name      string
		bound     map[string]string
		rows      map[string]placementRow
		installed map[string][]string
		down      []string
		host      string // --host
		noDecl    bool   // service.nix declares no host
		dry       bool
		wantHost  string
		wantRec   bool
		wantErr   string // substring; "" = must succeed
		probes    int64
	}{
		// A fenced row that names no host is refused before --host or
		// discovery: the move owns the name, and the registry's host map is
		// empty for it, so these are the cases where a second copy used to
		// be placed ahead of any write that could refuse it.
		{name: "fenced stale row", bound: map[string]string{}, probes: 0,
			rows:    map[string]placementRow{"svc": {Service: "svc", State: placementStale, Host: "dst", Token: "t1", Device: "h005", Previous: &placementBinding{Host: "src"}}},
			wantErr: "is fenced: a move to dst is still open, held by h005 (state stale with a rollback binding on src)"},
		{name: "fenced stale row, --host names the destination", host: "dst", bound: map[string]string{},
			rows:    map[string]placementRow{"svc": {Service: "svc", State: placementStale, Host: "dst", Token: "t1", Device: "h005"}},
			wantErr: "is fenced"},
		{name: "fenced stale row, --host names another host", host: "src", bound: map[string]string{},
			rows:    map[string]placementRow{"svc": {Service: "svc", State: placementStale, Host: "dst", Token: "t1", Device: "h005"}},
			wantErr: "is fenced"},
		{name: "fenced first placement", bound: map[string]string{},
			rows:    map[string]placementRow{"svc": {Service: "svc", State: placementPrepared, Host: "dst", Token: "t1", Device: "h005"}},
			wantErr: "is fenced: a move to dst is still open, held by h005 (state prepared)"},
		{name: "fenced first placement, --host", host: "dst", bound: map[string]string{},
			rows:    map[string]placementRow{"svc": {Service: "svc", State: placementPrepared, Host: "dst", Token: "t1"}},
			wantErr: "is fenced"},
		// A move in flight keeps its token but still names a host: refusing it
		// would refuse the ordinary case.
		{name: "committed after a move, token still set", bound: map[string]string{"svc": "dst"},
			rows:      map[string]placementRow{"svc": {Service: "svc", State: placementCommitted, Host: "dst", Token: "t9", Previous: &placementBinding{Host: "src"}}},
			installed: map[string][]string{"dst": {"svc+"}}, wantHost: "dst", probes: 2},
		{name: "bound and running", bound: map[string]string{"svc": "dst"},
			installed: map[string][]string{"dst": {"svc+"}}, wantHost: "dst", probes: 2},
		{name: "bound but unreachable", bound: map[string]string{"svc": "dst"},
			down: []string{"dst"}, wantErr: "is placed on dst, which did not answer", probes: 2},
		{name: "no row, one copy", installed: map[string][]string{"src": {"svc"}},
			wantHost: "src", wantRec: true, probes: 2},
		{name: "no row, two copies", installed: map[string][]string{"src": {"svc"}, "dst": {"svc+"}},
			wantErr: "is installed on dst, src but the registry has no row", probes: 2},
		{name: "no row, nowhere", wantErr: "placed on no host and installed on no host", probes: 2},
		{name: "no row, a host silent", down: []string{"dst"},
			wantErr: "cannot confirm where svc is installed", probes: 2},
		{name: "no row, --host", host: "dst", wantHost: "dst", wantRec: true},
		{name: "--host differs from the binding", bound: map[string]string{"svc": "dst"}, host: "src",
			wantErr: "--host cannot override a live binding"},
		{name: "--host matches the binding", bound: map[string]string{"svc": "dst"}, host: "dst",
			wantHost: "dst"},
		{name: "dry-run --host", host: "dst", dry: true, wantHost: "dst"},
		{name: "dry-run declared host", dry: true, wantHost: "src"},
		{name: "dry-run with nothing to plan against", dry: true, noDecl: true,
			wantErr: "no --host; nothing to plan against"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			probes := resolutionRig(t, c.bound, c.rows, c.installed, c.down...)
			s := inv.Services["svc"]
			if c.noDecl {
				s.Host = ""
			}
			if c.dry {
				dryRun = true
			}
			f := flags{vals: map[string]string{}}
			if c.host != "" {
				f.vals["host"] = c.host
			}
			h, rec, err := resolveHost(s, f)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
			} else if err != nil {
				t.Fatalf("unexpected refusal: %v", err)
			}
			if h != c.wantHost || rec != c.wantRec {
				t.Errorf("got (%q, %v), want (%q, %v)", h, rec, c.wantHost, c.wantRec)
			}
			// A refusal on a dead binding must name both escape hatches: the
			// registry cannot be re-read from the host that went away.
			if c.wantErr == "is placed on dst, which did not answer" {
				for _, want := range []string{"cnt place svc --set <host> --force", "cnt place svc --recover --force"} {
					if !strings.Contains(err.Error(), want) {
						t.Errorf("refusal does not name %q: %v", want, err)
					}
				}
			}
			// A fence is settled on the registry, not on a host: the refusal
			// has to name the holder, the destination and both settles.
			if strings.Contains(c.wantErr, "is fenced") {
				for _, want := range []string{"cnt place svc --recover", "--force", "cnt place svc --set <host> --force", "dst"} {
					if !strings.Contains(err.Error(), want) {
						t.Errorf("refusal does not name %q: %v", want, err)
					}
				}
			}
			if got := probes.Load(); got != c.probes {
				t.Errorf("probed %d hosts, want %d", got, c.probes)
			}
		})
	}
}

// ------------------------------------------------------- split-brain start

// TestCmdUnitRefusesLocalCopyPlacedElsewhere is the leftover-copy lockout:
// this machine still has the unit of a service the registry binds elsewhere,
// so a plain `cnt start` (or restart) here would answer the same name from two
// hosts. stop stays allowed -- removing a stray is exactly what it is for.
func TestCmdUnitRefusesLocalCopyPlacedElsewhere(t *testing.T) {
	r := newRig(t)
	// euid is not 0 in a test run: hostCmd runs root work through sudo.
	writeExe(t, filepath.Join(r.bin, "sudo"), "#!/bin/sh\nexec \"$@\"\n")
	writeExe(t, filepath.Join(r.bin, "systemctl"), "#!/bin/sh\necho \"systemctl $*\" >> "+r.log+"\nexit 0\n")
	oldM, oldG, oldL := mutableUnits, gcroots, localHost
	oldNow, oldProbe := placementNow, fleetProbe
	t.Cleanup(func() {
		mutableUnits, gcroots, localHost = oldM, oldG, oldL
		placementNow, fleetProbe = oldNow, oldProbe
		registryCache = nil
	})
	localHost, mutableUnits, gcroots = "src", t.TempDir(), t.TempDir()
	// The leftover copy of the podman service, as a CLI install leaves it.
	must(t, os.WriteFile(filepath.Join(gcroots, "svc"), nil, 0o644))
	fleetProbe = fakeFleet(map[string][]string{"src": {"svc+"}})
	bind := func(h string) {
		placementNow = func(bool) *placementView { return &placementView{Host: map[string]string{"svc": h}} }
		registryCache = nil
	}
	reset := func() { must(t, os.WriteFile(r.log, nil, 0o644)) }

	bind("dst")
	for _, verb := range []string{"start", "restart"} {
		reset()
		err := cmdUnit(verb, []string{"svc"})
		if err == nil || !strings.Contains(err.Error(), "a copy is installed here (src)") {
			t.Fatalf("%s: err = %v, want the split-brain refusal", verb, err)
		}
		if !strings.Contains(err.Error(), "cnt place svc --set src") {
			t.Errorf("%s: refusal names no escape: %v", verb, err)
		}
		if c := r.calls(); strings.Contains(c, "systemctl start fleet-svc.service") {
			t.Fatalf("%s started the leftover copy:\n%s", verb, c)
		}
	}
	// stop is still allowed, and it targets the copy that is here: that only
	// removes the stray, which is what makes the lockout recoverable.
	reset()
	if err := cmdUnit("stop", []string{"svc"}); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if _, err := os.Stat(filepath.Join(holdDir, "svc")); err != nil {
		t.Errorf("stop left no hold marker: %v", err)
	}
	if c := r.calls(); !strings.Contains(c, "systemctl stop fleet-svc.service") {
		t.Errorf("stop did not reach the local copy:\n%s", c)
	}

	// The registry binding to this host is the normal case: start proceeds.
	bind("src")
	reset()
	if err := cmdUnit("start", []string{"svc"}); err != nil {
		t.Fatalf("start on the bound host: %v", err)
	}
	if c := r.calls(); !strings.Contains(c, "systemctl start fleet-svc.service") {
		t.Errorf("start on the bound host did not run:\n%s", c)
	}
}

// TestFencedRowRefusesBeforeActing is the gap that let a deploy or a start
// place a second copy: a fenced row (a move owns the name) whose row names no
// host -- stale, or a first placement that never committed -- used to fall
// through to --host and discovery, so the command ran on a host the move may
// have stranded and only a later registry write could object. Nothing may run
// remotely, and the row is left exactly as it was for --recover to settle.
func TestFencedRowRefusesBeforeActing(t *testing.T) {
	fenced := map[string]struct {
		row placementRow
		why string
	}{
		"stale": {row: placementRow{Service: "svc", State: placementStale, Host: "dst", Token: "t1", Device: "h005",
			Previous: &placementBinding{Host: "src"}}, why: "state stale with a rollback binding on src"},
		"first prepared": {row: placementRow{Service: "svc", State: placementPrepared, Host: "dst", Token: "t1", Device: "h005"},
			why: "state prepared"},
	}
	for name, f := range fenced {
		t.Run(name, func(t *testing.T) {
			r := newRig(t)
			// Recording the placement after a deploy would be a write the fence
			// has to pre-empt: any registry client is a test failure.
			oldClient := edgeClientFor
			t.Cleanup(func() { edgeClientFor = oldClient })
			edgeClientFor = func() (*edgeClient, error) {
				t.Fatalf("%s: a fenced row must not reach the registry client", name)
				return nil, nil
			}
			old := placementNow
			t.Cleanup(func() { placementNow = old; registryCache = nil })
			row := f.row
			placementNow = func(bool) *placementView {
				// The registry's host map carries only effective hosts, so a
				// fenced row that names none is simply absent from it.
				return &placementView{Host: map[string]string{}, Rows: map[string]placementRow{"svc": row}}
			}
			reset := func() { must(t, os.WriteFile(r.log, nil, 0o644)) }
			for _, args := range [][]string{{"svc", "--host", "dst"}, {"svc", "--host", "src"}, {"svc"}} {
				reset()
				err := cmdDeploy(args)
				if err == nil || !strings.Contains(err.Error(), "is fenced") {
					t.Fatalf("deploy %v: err = %v, want the fence refusal", args, err)
				}
				if !strings.Contains(err.Error(), f.why) {
					t.Errorf("deploy %v: refusal does not name the row (%s): %v", args, f.why, err)
				}
				if !strings.Contains(err.Error(), "cnt place svc --recover") {
					t.Errorf("deploy %v: refusal names no settle: %v", args, err)
				}
				if c := r.calls(); c != "" {
					t.Fatalf("deploy %v reached a host:\n%s", args, c)
				}
			}
			for _, verb := range []string{"start", "restart"} {
				reset()
				if err := cmdUnit(verb, []string{"svc"}); err == nil || !strings.Contains(err.Error(), "is fenced") {
					t.Fatalf("%s: err = %v, want the fence refusal", verb, err)
				}
				if c := r.calls(); c != "" {
					t.Fatalf("%s on a fenced row reached a host:\n%s", verb, c)
				}
			}
		})
	}
}

// ------------------------------------------------------ recording a deploy

type placementCall struct {
	path string
	body map[string]any
}

// placementServer stands in for fleet-edge. failReserve answers the reserve
// with a 500, as a registry outage would.
func placementServer(t *testing.T, failReserve bool) (*httptest.Server, func() []placementCall) {
	t.Helper()
	var mu sync.Mutex
	var calls []placementCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		calls = append(calls, placementCall{path: r.URL.Path, body: body})
		mu.Unlock()
		if failReserve && r.URL.Path == "/api/placements/reserve" {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "registry is down"})
			return
		}
		row := map[string]any{"service": "svc", "host": "dst", "state": "committed", "revision": 7}
		if r.URL.Path == "/api/placements/reserve" {
			row["state"] = "prepared"
			row["token"] = "tok-1"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"row": row})
	}))
	t.Cleanup(srv.Close)
	return srv, func() []placementCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]placementCall(nil), calls...)
	}
}

// usePlacementServer points the deploy path at the fake registry.
func usePlacementServer(t *testing.T, srv *httptest.Server) {
	t.Helper()
	old := edgeClientFor
	t.Cleanup(func() { edgeClientFor = old })
	edgeClientFor = func() (*edgeClient, error) {
		// A token already in hand keeps do() from fetching a Zitadel one.
		return &edgeClient{base: srv.URL, http: srv.Client(), token: "machine-token"}, nil
	}
}

// assertRecorded checks the write shape every recording shares: the reserve
// carries force only when the caller asked for it (the deploy never does), and
// the commit presents only the token the reserve returned.
func assertRecorded(t *testing.T, cs []placementCall, force bool) {
	t.Helper()
	if len(cs) != 2 {
		t.Fatalf("calls = %+v, want a reserve then a commit", cs)
	}
	res, com := cs[0], cs[1]
	if res.path != "/api/placements/reserve" {
		t.Fatalf("calls = %+v, want a reserve then a commit", cs)
	}
	_, forced := res.body["force"]
	if forced != force {
		t.Errorf("reserve=%+v, want force=%v (the key is omitted, not false)", res.body, force)
	}
	if res.body["service"] != "svc" || res.body["host"] != "dst" {
		t.Errorf("reserve = %+v, want svc on dst", res)
	}
	if com.path != "/api/placements/commit" || com.body["token"] != "tok-1" {
		t.Errorf("commit = %+v, want the reserve's token", com)
	}
	if _, forced := com.body["force"]; forced {
		t.Errorf("commit must not force: %+v", com.body)
	}
}

// TestDeployRecordsPlacement: the first deploy with --host leaves the registry
// binding that host, so the next command resolves it without discovery.
func TestDeployRecordsPlacement(t *testing.T) {
	m := newMoveRig(t)
	srv, calls := placementServer(t, false)
	usePlacementServer(t, srv)
	if err := cmdDeploy([]string{"svc", "--host", "dst"}); err != nil {
		t.Fatalf("deploy: %v", err)
	}
	assertRecorded(t, calls(), false)
	if c := m.calls(); !strings.Contains(c, "fleet-install") {
		t.Errorf("the deploy itself did not run:\n%s", c)
	}
}

// TestDeployPlacementFailureWarns: a registry failure never undoes a deploy
// that worked. It says so loudly and names the exact command to fix it.
func TestDeployPlacementFailureWarns(t *testing.T) {
	m := newMoveRig(t)
	srv, calls := placementServer(t, true)
	usePlacementServer(t, srv)
	var err error
	out := captureStderr(t, func() { err = cmdDeploy([]string{"svc", "--host", "dst"}) })
	if err != nil {
		t.Fatalf("a registry failure must not undo the deploy: %v", err)
	}
	for _, want := range []string{
		"WARNING: svc is running on dst but its placement was not recorded",
		"WARNING: record it before anything else starts it: containers place svc --set dst",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// The failed reserve is the only call: there is nothing of ours to roll
	// back, so no delete follows it.
	if cs := calls(); len(cs) != 1 || cs[0].path != "/api/placements/reserve" {
		t.Errorf("calls = %+v, want the failed reserve alone", cs)
	}
	if c := m.calls(); !strings.Contains(c, "fleet-install") {
		t.Errorf("the deploy itself did not run:\n%s", c)
	}
}

// TestDeployLeavesAForeignReservation is the race the deploy path must lose
// gracefully: a deploy runs for minutes, a move reserves its row before it
// deploys, so by the time the deploy records itself another client owns the
// row. The reserve is refused unforced, the reservation is left exactly as the
// move left it, and the warning names the move to settle first — forcing here
// would mint a token that stops that move from committing what it reserved.
func TestDeployLeavesAForeignReservation(t *testing.T) {
	m := newMoveRig(t)
	// A move reserved svc for dst while this deploy was running: the row carries
	// its token, and src is still the binding that serves the name.
	foreign := placementRow{Service: "svc", Host: "dst", State: placementPrepared,
		Device: "h005", Token: "other", Revision: 3, Previous: &placementBinding{Host: "src"}}
	var mu sync.Mutex
	var calls []placementCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		calls = append(calls, placementCall{path: r.URL.Path, body: body})
		if body["force"] != nil {
			// What a forced reserve does: the row becomes the forcer's, and the
			// move that was running can no longer commit what it reserved.
			foreign = placementRow{Service: "svc", Host: "dst", State: placementPrepared,
				Device: "h005", Token: "stolen", Revision: 4, Previous: &placementBinding{Host: "src"}}
			_ = json.NewEncoder(w).Encode(map[string]any{"row": foreign})
			return
		}
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error": "svc: reserve refused: h005's move to dst owns the reservation (present its token, or force)"})
	}))
	t.Cleanup(srv.Close)
	usePlacementServer(t, srv)

	var err error
	out := captureStderr(t, func() { err = cmdDeploy([]string{"svc", "--host", "dst"}) })
	if err != nil {
		t.Fatalf("a reservation another client holds must not undo the deploy: %v", err)
	}
	if c := m.calls(); !strings.Contains(c, "fleet-install") {
		t.Errorf("the deploy itself did not run:\n%s", c)
	}
	mu.Lock()
	after, cs := foreign, append([]placementCall(nil), calls...)
	mu.Unlock()
	// The refusal ends the recording: no commit, and no rollback of a row that
	// was never ours.
	if len(cs) != 1 || cs[0].path != "/api/placements/reserve" {
		t.Fatalf("calls = %+v, want the refused reserve alone", cs)
	}
	if _, forced := cs[0].body["force"]; forced {
		t.Errorf("the deploy forced the reserve: %+v", cs[0].body)
	}
	if after.Token != "other" || after.State != placementPrepared || after.Host != "dst" ||
		after.Device != "h005" || after.Revision != 3 {
		t.Errorf("the foreign reservation was rewritten: %+v", after)
	}
	for _, want := range []string{
		"WARNING: svc is running on dst but its placement was not recorded",
		"WARNING: record it before anything else starts it: containers place svc --set dst",
		"WARNING: h005's move to dst owns the row now; the deploy left that reservation untouched (nothing forced)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

// TestPlaceSetForcesTheReserveOnly is the escape hatch's wire shape, which has
// to work while the bound host is unreachable: --set never probes the fleet, so
// the dead host cannot veto the move.
func TestPlaceSetForcesTheReserveOnly(t *testing.T) {
	var probes atomic.Int64
	old := fleetProbe
	t.Cleanup(func() { fleetProbe = old })
	fleetProbe = func(context.Context, string) ([]row, error) {
		probes.Add(1)
		return nil, errors.New("ssh: connect to host dst: No route to host")
	}
	srv, calls := placementServer(t, false)
	c := &edgeClient{base: srv.URL, http: srv.Client(), token: "machine-token"}
	if err := placeSet(c, "svc", "dst", true); err != nil {
		t.Fatalf("place --set --force: %v", err)
	}
	assertRecorded(t, calls(), true)
	if n := probes.Load(); n != 0 {
		t.Errorf("place --set probed the fleet %d time(s); a dead host must not veto the move", n)
	}
}

// TestCmdPlaceDispatcher proves the command path, not just placeSet: the
// escape hatches an operator types (`place <svc> --set <h> --force`,
// `place <svc> --recover --force`) reach the registry with --force attached.
func TestCmdPlaceDispatcher(t *testing.T) {
	old := dryRun
	t.Cleanup(func() { dryRun = old })
	dryRun = false

	srv, calls := placementServer(t, false)
	usePlacementServer(t, srv)
	if err := cmdPlace([]string{"svc", "--set", "dst", "--force"}); err != nil {
		t.Fatalf("place --set: %v", err)
	}
	assertRecorded(t, calls(), true)

	srv, calls = placementServer(t, false)
	usePlacementServer(t, srv)
	if err := cmdPlace([]string{"svc", "--recover", "--force"}); err != nil {
		t.Fatalf("place --recover: %v", err)
	}
	cs := calls()
	if len(cs) != 1 || cs[0].path != "/api/placements/recover" || cs[0].body["force"] != true || cs[0].body["service"] != "svc" {
		t.Fatalf("recover calls = %+v, want one forced recover for svc", cs)
	}
}

// TestDispatchPlaceHelp guards the top-level switch: `fleet containers place`
// once fell through to the top-level usage because cmdPlace was never wired
// in. Help must come from place itself and list every form it accepts.
func TestDispatchPlaceHelp(t *testing.T) {
	var buf strings.Builder
	old := usageOut
	usageOut = &buf
	t.Cleanup(func() { usageOut = old })

	known, err := dispatch("place", []string{"--help"})
	if !known || err != nil {
		t.Fatalf("dispatch(place --help) = known %v, err %v; want a known command and no error", known, err)
	}
	out := buf.String()
	if strings.Contains(out, "fleet containers - floating services") {
		t.Fatalf("place --help printed the top-level usage:\n%s", out)
	}
	for _, want := range []string{"place [--verify]", "--host h", "--set h", "--adopt", "--recover", "--token T", "place --import"} {
		if !strings.Contains(out, want) {
			t.Errorf("place --help is missing %q:\n%s", want, out)
		}
	}
}

// ------------------------------------------------- registry not consulted

// registryWarnRig resets the once-per-process "not consulted" warning and
// captures it.
func registryWarnRig(t *testing.T) *strings.Builder {
	t.Helper()
	var buf strings.Builder
	reset := func(out io.Writer) {
		registryMu.Lock()
		registryWarnOut, registryWarned, registrySkipped = out, false, nil
		registryMu.Unlock()
	}
	old := registryWarnOut
	reset(&buf)
	t.Cleanup(func() { reset(old) })
	return &buf
}

// No key file at all (a dev box): nil, and nothing said about it.
func TestReadPlacementsNoKeyIsQuiet(t *testing.T) {
	buf := registryWarnRig(t)
	t.Setenv("SEC_MACHINE_KEY", filepath.Join(t.TempDir(), "absent.json"))
	if v := readPlacements(newEdgeClient, false); v != nil {
		t.Fatalf("view = %+v, want nil", v)
	}
	if buf.Len() != 0 || registryUnconsulted() != nil {
		t.Fatalf("a missing key warned: %q (%v)", buf.String(), registryUnconsulted())
	}
}

// A key this user may not read (not root): nil, one warning naming sudo, no
// matter how often the registry is asked.
func TestReadPlacementsUnreadableKeyWarnsOnce(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-0 file")
	}
	buf := registryWarnRig(t)
	key := filepath.Join(t.TempDir(), "machine-key.json")
	must(t, os.WriteFile(key, []byte("{}"), 0o000))
	t.Setenv("SEC_MACHINE_KEY", key)
	for range 3 {
		if v := readPlacements(newEdgeClient, false); v != nil {
			t.Fatalf("view = %+v, want nil", v)
		}
	}
	out := buf.String()
	if n := strings.Count(out, "warning:"); n != 1 {
		t.Fatalf("%d warnings, want one: %q", n, out)
	}
	for _, want := range []string{"placement registry not consulted", "cannot read the machine key " + key + ": permission denied", "run as root (sudo) on an allowlisted host"} {
		if !strings.Contains(out, want) {
			t.Errorf("warning does not say %q: %q", want, out)
		}
	}
}

// A registry that fails the request: one warning, the read-only path keeps
// the declared host, and a discovery fallthrough in resolveHost says why.
func TestReadPlacementsRequestFailureWarnsAndFallsBack(t *testing.T) {
	resolutionRig(t, nil, nil, map[string][]string{"src": {"svc"}})
	buf := registryWarnRig(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		regFail(w, http.StatusInternalServerError, "registry is down")
	}))
	t.Cleanup(srv.Close)
	client := func() (*edgeClient, error) {
		return &edgeClient{base: srv.URL, http: srv.Client(), token: "machine-token"}, nil
	}
	placementNow = func(verify bool) *placementView { return readPlacements(client, verify) }

	s := inv.Services["svc"]
	if h := resolvedHost(s); h != s.Host {
		t.Fatalf("resolvedHost = %q, want the declared %q", h, s.Host)
	}
	var h string
	out := captureStderr(t, func() {
		var err error
		if h, _, err = resolveHost(s, flags{vals: map[string]string{}}); err != nil {
			t.Errorf("resolveHost: %v", err)
		}
	})
	if h != "src" {
		t.Errorf("resolveHost = %q, want src by discovery", h)
	}
	if !strings.Contains(out, "resolving the host by discovery: placement registry not consulted") || !strings.Contains(out, "sudo") {
		t.Errorf("the discovery fallthrough did not say the registry was not consulted: %q", out)
	}
	w := buf.String()
	if n := strings.Count(w, "warning:"); n != 1 || !strings.Contains(w, "500") {
		t.Fatalf("warnings = %q, want one naming the failed request", w)
	}
}

// TestImportPlanSkipsSingletonWhileHostSilent: one active copy on src while dst
// does not answer is not "exactly one host" -- a copy on dst would be missed --
// so `place --import` must skip it with the reason, as placeAdopt refuses.
// With every host answering the same singleton is imported.
func TestImportPlanSkipsSingletonWhileHostSilent(t *testing.T) {
	resolutionRig(t, nil, nil, map[string][]string{"src": {"svc+"}}, "dst")
	entries, skipped := importPlan()
	if len(entries) != 0 {
		t.Errorf("entries = %v, want none while dst is silent", entries)
	}
	if len(skipped) != 1 || skipped[0] != "svc (a host did not answer: dst)" {
		t.Errorf("skipped = %q, want svc listed with the silent host", skipped)
	}

	resolutionRig(t, nil, nil, map[string][]string{"src": {"svc+"}})
	entries, skipped = importPlan()
	if len(entries) != 1 || entries[0] != (placementEntry{Service: "svc", Host: "src"}) || len(skipped) != 0 {
		t.Errorf("all answering: entries = %v skipped = %q, want svc on src", entries, skipped)
	}
}

// TestCmdPlaceImportNamesSilentHostWhenAllSkipped: when every service is
// skipped because a host did not answer, `place --import` still refuses, but
// the output must name that host -- "nothing to import" alone hides why.
func TestCmdPlaceImportNamesSilentHostWhenAllSkipped(t *testing.T) {
	resolutionRig(t, nil, nil, map[string][]string{"src": {"svc+"}}, "dst")
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	must(t, err)
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)})
	key := filepath.Join(t.TempDir(), "machine-key.json")
	b, err := json.Marshal(machineKey{KeyID: "k", UserID: "u", Key: string(pemKey)})
	must(t, err)
	must(t, os.WriteFile(key, b, 0o600))
	t.Setenv("SEC_MACHINE_KEY", key)

	var cmdErr error
	out := captureStderr(t, func() { cmdErr = cmdPlace([]string{"--import"}) })
	if cmdErr == nil || !strings.Contains(cmdErr.Error(), "nothing to import") {
		t.Fatalf("err = %v, want the nothing-to-import refusal", cmdErr)
	}
	if !strings.Contains(out, "undecided: svc (a host did not answer: dst)") {
		t.Errorf("output does not name the silent host dst:\n%s", out)
	}
}
