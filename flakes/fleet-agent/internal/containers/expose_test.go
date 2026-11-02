package containers

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHostListenersAudit(t *testing.T) {
	hl := parseHostListeners("# comment\ntcp 100.64.0.13 9101 host (status endpoint)\nbad line\ntcp x 99999 nope\nudp * 5000 host thing\n")
	if len(hl) != 2 || hl[0] != (hostListener{"tcp", "100.64.0.13", "9101", "host (status endpoint)"}) {
		t.Fatalf("parse: %+v", hl)
	}
	ss := `tcp   LISTEN 0      4096     100.64.0.13:9101      0.0.0.0:*    users:(("containers",pid=5,fd=3))
tcp   LISTEN 0      4096     10.12.14.10:9101      0.0.0.0:*    users:(("containers",pid=6,fd=3))
udp   UNCONN 0      0            0.0.0.0:5000      0.0.0.0:*    users:(("x",pid=7,fd=3))
`
	got := map[string]auditRow{}
	for _, r := range auditListeners(parseSS(ss), nil, "h001", hl...) {
		got[r.Proto+"/"+r.Port+"@"+r.Addr] = r
	}
	if r := got["tcp/9101@100.64.0.13"]; r.Status != "declared" || r.Owner != "host (status endpoint)" {
		t.Errorf("status endpoint: %+v", r)
	}
	if r := got["tcp/9101@10.12.14.10"]; r.Status != "UNDECLARED" {
		t.Errorf("same port, other address must stay undeclared: %+v", r)
	}
	if r := got["udp/5000@0.0.0.0"]; r.Status != "declared" {
		t.Errorf("wildcard decl: %+v", r)
	}
	// Without the file, 9101 is undeclared (nothing hard-coded).
	if r := auditListeners(parseSS(ss), nil, "h001"); r[0].Status != "UNDECLARED" || r[1].Status != "UNDECLARED" {
		t.Errorf("no decl: %+v", r)
	}
}

func TestSplitAudit(t *testing.T) {
	out := "SS\n" + auditMarkHost + "\ntcp 1.2.3.4 9 o\n" + auditMarkOv + "\n{\"service\":\"p\",\"route\":\"web\",\"exposure\":\"lan\",\"baseline\":\"tailnet\",\"until\":1}\n"
	ss, hl, ov := splitAudit(out)
	if ss != "SS\n" || hl != "tcp 1.2.3.4 9 o\n" || len(parseOverrides(ov, "h")) != 1 {
		t.Errorf("split: %q %q %q", ss, hl, ov)
	}
	if ss, hl, ov := splitAudit("plain"); ss != "plain" || hl != "" || ov != "" {
		t.Errorf("plain: %q %q %q", ss, hl, ov)
	}
	if !strings.Contains(auditCollectScript, "ss -ltnupH") || !strings.Contains(auditCollectScript, hostListenersFile) {
		t.Errorf("collect script:\n%s", auditCollectScript)
	}
}

func exposeSvc() Service {
	return Service{Name: "app", Routes: map[string]Route{
		"web": httpRoute("app", 8000, "tailnet", "native"),
		"raw": {Port: 9000, Proto: "tcp", Exposure: "tailnet", Auth: sp("native")},
		"pub": httpRoute("pub", 8001, "public", "native"),
		"loc": {Port: 7000, Proto: "http", Exposure: "local", FQDN: sp("loc.joshuabell.xyz")},
	}}
}

func TestExposeCheck(t *testing.T) {
	s := exposeSvc()
	o, err := exposeCheck(s, "web", "lan")
	if err != nil {
		t.Fatal(err)
	}
	if o.Routes["web"].Exposure != "lan" || s.Routes["web"].Exposure != "tailnet" {
		t.Errorf("override must copy: %v / %v", o.Routes["web"].Exposure, s.Routes["web"].Exposure)
	}
	if v := routesVhost(o); !strings.Contains(v, "nginx-acl-lan.conf") || strings.Contains(v, "nginx-acl-tailnet.conf") {
		t.Errorf("vhost:\n%s", v)
	}
	bad := []struct{ route, level, want string }{
		{"web", "tailnet", "already"},
		{"web", "internet", "want tailnet, lan or public"},
		{"raw", "lan", "only http"},
		{"loc", "lan", "exposure = local"},
		{"pub", "lan", "only widens"},
	}
	for _, c := range bad {
		if _, err := exposeCheck(s, c.route, c.level); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s->%s: %v, want %q", c.route, c.level, err, c.want)
		}
	}
	// lib.nix auth rule still applies to public.
	na := s
	na.Routes = map[string]Route{"web": httpRoute("app", 8000, "tailnet", "none")}
	if _, err := exposeCheck(na, "web", "public"); err == nil || !strings.Contains(err.Error(), "publicWithoutAuth") {
		t.Errorf("auth none public: %v", err)
	}
}

func TestExposeCheckPublic(t *testing.T) {
	s := exposeSvc()
	o, err := exposeCheck(s, "web", "public")
	if err != nil {
		t.Fatal(err)
	}
	if r := o.Routes["web"]; r.Exposure != "public" || len(r.Via) != 1 || r.Via[0] != "edge" {
		t.Fatalf("route %+v", r)
	}
	if v := routesVhost(o); !strings.Contains(v, "8443") {
		t.Errorf("no edge server:\n%s", v)
	}
	// sso-proxy is public, so a gated route can go public too.
	g := s
	g.Routes = map[string]Route{"web": httpRoute("app", 8000, "tailnet", "oauth2-proxy")}
	if _, err := exposeCheck(g, "web", "public"); err != nil {
		t.Errorf("gated public: %v", err)
	}
	r := httpRoute("app", 8000, "tailnet", "native")
	r.Via = []string{"router"}
	g.Routes = map[string]Route{"web": r}
	if _, err := exposeCheck(g, "web", "public"); err == nil || !strings.Contains(err.Error(), "edge") {
		t.Errorf("router via: %v", err)
	}
}

func TestExposeFor(t *testing.T) {
	for _, c := range []struct {
		level, v string
		want     time.Duration
		bad      bool
	}{
		{"public", "", publicDefaultFor, false},
		{"public", "forever", 0, false},
		{"public", "720h", 720 * time.Hour, false},
		{"public", "10s", 0, true},
		{"lan", "48h", 0, true},
		{"lan", "forever", 0, true},
		{"lan", "", 0, true},
		{"lan", "1h", time.Hour, false},
	} {
		d, err := exposeFor(c.level, c.v)
		if (err != nil) != c.bad || !c.bad && d != c.want {
			t.Errorf("%s %q: %v %v", c.level, c.v, d, err)
		}
	}
}

func TestExposeScriptForever(t *testing.T) {
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}}
	sc := exposeScript(exposeSvc(), override{Service: "app", Route: "web", Exposure: "public", Baseline: "tailnet"}, 0, "B", "C")
	if strings.Contains(sc, "systemd-run") || !strings.Contains(sc, "until=0") {
		t.Errorf("forever script:\n%s", sc)
	}
}

type fakeEdgeAPI struct {
	log       []string
	prepErr   error
	commitErr error
	revokeErr error
	listRows  []edgeRow
	listErr   error
}

func (f *fakeEdgeAPI) prepare(edgeReq) error { f.log = append(f.log, "prepare"); return f.prepErr }
func (f *fakeEdgeAPI) commit(edgeReq) (edgeRow, error) {
	f.log = append(f.log, "commit")
	return edgeRow{FQDN: "app.example.com", DNS: "ok", Edge: true}, f.commitErr
}
func (f *fakeEdgeAPI) revoke(string) error { f.log = append(f.log, "revoke"); return f.revokeErr }
func (f *fakeEdgeAPI) list(bool) ([]edgeRow, *edgeVerify, error) {
	f.log = append(f.log, "list")
	return f.listRows, nil, f.listErr
}

func TestExposePublicOrder(t *testing.T) {
	run := func(f *fakeEdgeAPI, hostErr error) (string, error) {
		err := exposePublic(f, exposeSvc(), "web", "h001", time.Hour, "",
			func() error { f.log = append(f.log, "host"); return hostErr },
			func() error { f.log = append(f.log, "host-revoke"); return nil })
		return strings.Join(f.log, ","), err
	}
	if l, err := run(&fakeEdgeAPI{}, nil); err != nil || l != "prepare,host,commit" {
		t.Errorf("ok: %s %v", l, err)
	}
	if l, err := run(&fakeEdgeAPI{prepErr: errors.New("no")}, nil); err == nil || l != "prepare" {
		t.Errorf("prepare refused must touch nothing: %s", l)
	}
	if l, err := run(&fakeEdgeAPI{}, errors.New("nginx")); err == nil || l != "prepare,host,revoke" {
		t.Errorf("host fail: %s", l)
	}
	if l, err := run(&fakeEdgeAPI{commitErr: errors.New("bunny")}, nil); err == nil || l != "prepare,host,commit,host-revoke,revoke" {
		t.Errorf("commit fail: %s", l)
	}
}

// resetEdge is a stateful h005: revoke drops the service's row.
type resetEdge struct {
	fakeEdgeAPI
	rows    []edgeRow
	stuck   bool // revoke "succeeds" but the row stays (sweep pending)
	revoked []string
}

func (f *resetEdge) revoke(svc string) error {
	f.revoked = append(f.revoked, svc)
	if f.revokeErr != nil || f.stuck {
		return f.revokeErr
	}
	var keep []edgeRow
	for _, r := range f.rows {
		if r.Service != svc {
			keep = append(keep, r)
		}
	}
	f.rows = keep
	return nil
}
func (f *resetEdge) list(bool) ([]edgeRow, *edgeVerify, error) { return f.rows, nil, f.listErr }

func TestExposeResetClearsEverywhere(t *testing.T) {
	hostOv := map[string][]override{
		"h001": {{Service: "app", Route: "web", Exposure: "lan", Baseline: "tailnet"}, {Service: "other", Route: "web", Exposure: "lan"}},
		"lio":  {{Service: "app", Route: "web", Exposure: "public", Baseline: "tailnet"}}, // stale copy after a move
	}
	list := func(h string) (hostOverrideState, error) {
		if h == "down" {
			return hostOverrideState{}, errors.New("ssh: timeout")
		}
		return hostOverrideState{Overrides: hostOv[h]}, nil
	}
	var revoked []string
	revokeHost := func(h string) error {
		revoked = append(revoked, h)
		var keep []override
		for _, o := range hostOv[h] {
			if o.Service != "app" {
				keep = append(keep, o)
			}
		}
		hostOv[h] = keep
		return nil
	}
	// lio is not in the host list: h005's row names it, so it is swept too.
	edge := &resetEdge{rows: []edgeRow{{Service: "app", Route: "web", Host: "lio"}, {Service: "keep", Route: "web", Host: "h001"}}}
	if err := exposeReset(edge, nil, "app", []string{"h001", "h003"}, list, revokeHost); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if strings.Join(edge.revoked, ",") != "app" || strings.Join(revoked, ",") != "h001,lio" {
		t.Fatalf("h005 revoked %v, hosts revoked %v", edge.revoked, revoked)
	}
	if len(hostOv["h001"]) != 1 || hostOv["h001"][0].Service != "other" || len(edge.rows) != 1 || edge.rows[0].Service != "keep" {
		t.Fatalf("other services' overrides must survive: %v %v", hostOv, edge.rows)
	}
}

func TestExposeResetReportsWhatIsLeft(t *testing.T) {
	none := func(string) error { return nil }
	empty := func(h string) (hostOverrideState, error) {
		if h == "down" {
			return hostOverrideState{}, errors.New("ssh: timeout")
		}
		return hostOverrideState{}, nil
	}
	// h005 unreachable: the hosts are still cleared, but reset fails.
	err := exposeReset(nil, errNoToken, "app", []string{"h001"}, empty, none)
	if err == nil || !strings.Contains(err.Error(), "override API") {
		t.Errorf("no h005 must fail: %v", err)
	}
	// A host that does not answer is never reported clean.
	err = exposeReset(&resetEdge{}, nil, "app", []string{"h001", "down"}, empty, none)
	if err == nil || !strings.Contains(err.Error(), "down: overrides unknown") {
		t.Errorf("unreachable host must fail: %v", err)
	}
	// h005's row survives the DELETE (o002 push failed, sweep retries).
	edge := &resetEdge{rows: []edgeRow{{Service: "app", Route: "web", Host: "h001", State: "removing", LastError: "o002: down"}}, stuck: true}
	err = exposeReset(edge, nil, "app", []string{"h001"}, empty, none)
	if err == nil || !strings.Contains(err.Error(), "h005 still has app.web") {
		t.Errorf("leftover h005 row must fail: %v", err)
	}
	// The host revert fails: still listed afterwards.
	stuckHost := func(string) (hostOverrideState, error) {
		return hostOverrideState{Overrides: []override{{Service: "app", Route: "web", Exposure: "lan"}}}, nil
	}
	err = exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, stuckHost, func(string) error { return errors.New("nginx -t") })
	if err == nil || !strings.Contains(err.Error(), "h001: revoke: nginx -t") || !strings.Contains(err.Error(), "h001 still has app.web lan") {
		t.Errorf("failed host revert must fail: %v", err)
	}
}

func TestExpireForeverOnlyPublic(t *testing.T) {
	dir := t.TempDir()
	oldO, oldN, oldR := overridesDir, nginxDir, runCmd
	overridesDir, nginxDir = dir+"/ov", dir+"/nginx"
	runCmd = func(string, ...string) error { return nil }
	defer func() { overridesDir, nginxDir, runCmd = oldO, oldN, oldR }()
	for svc, exp := range map[string]string{"pub": "public", "lan": "lan"} {
		_ = os.MkdirAll(filepath.Join(overridesDir, svc), 0o755)
		_ = os.WriteFile(filepath.Join(overridesDir, svc, "override.json"), []byte(`{"service":"`+svc+`","route":"web","exposure":"`+exp+`","until":0}`), 0o644)
		_ = os.WriteFile(filepath.Join(overridesDir, svc, "baseline.conf"), []byte("B"), 0o644)
	}
	_ = os.MkdirAll(nginxDir, 0o755)
	_ = cmdExposeExpire([]string{"--all"})
	if _, err := os.Stat(filepath.Join(overridesDir, "pub")); err != nil {
		t.Error("public forever expired")
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "lan")); !os.IsNotExist(err) {
		t.Error("lan without deadline kept (must fail closed)")
	}
}

func TestEdgeLeftovers(t *testing.T) {
	host := []override{{Service: "a", Route: "web", Exposure: "public", Host: "h001"}, {Service: "b", Route: "web", Exposure: "public", Host: "h001"}}
	rows := []edgeRow{{Service: "a", Route: "web", State: "committed", FQDN: "a.x"}, {Service: "c", Route: "web", State: "committed", FQDN: "c.x", Host: "h003"}}
	v := &edgeVerify{DNS: map[string]string{"a": "ok", "c": "mismatch"}, Edge: map[string]string{"a": "ok", "c": "missing"}, EdgeExtra: []string{"z.x"}}
	got := strings.Join(edgeLeftovers(host, rows, v), "\n")
	for _, w := range []string{"c.web: h005 row", "c.web: DNS mismatch", "c.web: o002 vhost missing", "b.web: public on h001 but no h005 row", "z.x without"} {
		if !strings.Contains(got, w) {
			t.Errorf("missing %q in\n%s", w, got)
		}
	}
	if strings.Contains(got, "a.web") {
		t.Errorf("clean row flagged:\n%s", got)
	}
}

func TestPickRouteAndTarget(t *testing.T) {
	if s, r := splitTarget("puzzles.web"); s != "puzzles" || r != "web" {
		t.Error(s, r)
	}
	if s, r := splitTarget("puzzles/web"); s != "puzzles" || r != "web" {
		t.Error(s, r)
	}
	s := exposeSvc()
	if r, err := pickRoute(s, ""); err != nil || r != "loc" && r != "web" {
		// two http routes (web, loc): must ask
		if err == nil {
			t.Errorf("ambiguous: %q", r)
		}
	}
	delete(s.Routes, "loc")
	delete(s.Routes, "pub")
	if r, err := pickRoute(s, ""); err != nil || r != "web" {
		t.Errorf("single http: %q %v", r, err)
	}
	if _, err := pickRoute(s, "nope"); err == nil {
		t.Error("unknown route accepted")
	}
}

func TestExposeScript(t *testing.T) {
	s := exposeSvc()
	o, _ := exposeCheck(s, "web", "lan")
	sc := exposeScript(s, override{Service: "app", Route: "web", Exposure: "lan", Baseline: "tailnet", Reason: `it's "x"`}, 180, "BASE", routesVhost(o))
	for _, w := range []string{
		"[ -e /etc/systemd/system/fleet-containers-expose-boot.service ]", // module check
		"/var/lib/fleet-containers/overrides/app",
		`"exposure":"lan","baseline":"tailnet"`,
		"--unit=fleet-expose-app --on-active=181s",
		"nginx -t -c /etc/nginx/nginx.conf",
		"nginx-acl-lan.conf",
	} {
		if !strings.Contains(sc, w) {
			t.Errorf("missing %q in\n%s", w, sc)
		}
	}
	// override.json is written before the site, the timer after it.
	if i, j, k := strings.Index(sc, "override.json.new\"\n"), strings.Index(sc, "nginx -t"), strings.Index(sc, "systemd-run"); !(i < j && j < k) {
		t.Errorf("order %d %d %d", i, j, k)
	}
}

func TestDeployDropsOverride(t *testing.T) {
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}}
	ps := prepareScript(exposeSvc(), "h001")
	i, j := strings.LastIndex(ps, "overrides/app"), strings.Index(ps, "nginx -t")
	if i < 0 || j < 0 || i < j {
		t.Errorf("deploy must drop the override only after the site:\n%s", ps)
	}
}

func TestOverridesInRoutesTable(t *testing.T) {
	now := time.Unix(1000, 0)
	tbl := routesTableWith([]Service{exposeSvc()}, []override{{Service: "app", Route: "web", Exposure: "lan", Baseline: "tailnet", Until: 1180}}, nil, now)
	if !strings.Contains(tbl, "lan (OVERRIDDEN from tailnet, 3m0s left)") {
		t.Errorf("table:\n%s", tbl)
	}
	if l := (override{Until: 900}).left(now); !strings.Contains(l, "expired") {
		t.Error(l)
	}
}

func TestExpireOne(t *testing.T) {
	dir := t.TempDir()
	oldO, oldN, oldR := overridesDir, nginxDir, runCmd
	defer func() { overridesDir, nginxDir, runCmd = oldO, oldN, oldR }()
	overridesDir, nginxDir = filepath.Join(dir, "ov"), filepath.Join(dir, "nginx")
	var ran []string
	nginxOK := true
	runCmd = func(n string, a ...string) error {
		ran = append(ran, n+" "+strings.Join(a, " "))
		if n == "nginx" && !nginxOK {
			return os.ErrInvalid
		}
		return nil
	}
	setup := func(until int64) {
		d := filepath.Join(overridesDir, "app")
		must(t, os.MkdirAll(d, 0o755))
		must(t, os.MkdirAll(nginxDir, 0o755))
		must(t, os.WriteFile(filepath.Join(d, "baseline.conf"), []byte("BASE"), 0o644))
		must(t, os.WriteFile(filepath.Join(d, "override.json"), []byte(`{"service":"app","route":"web","exposure":"lan","baseline":"tailnet","until":`+strconv.FormatInt(until, 10)+`}`), 0o644))
		must(t, os.WriteFile(filepath.Join(nginxDir, "app.conf"), []byte("WIDE"), 0o644))
	}
	site := func() string { b, _ := os.ReadFile(filepath.Join(nginxDir, "app.conf")); return string(b) }

	// Not due: untouched.
	setup(time.Now().Unix() + 3600)
	must(t, cmdExposeExpire([]string{"--all"}))
	if site() != "WIDE" || len(ran) != 0 {
		t.Fatalf("early revert: %q %v", site(), ran)
	}
	// Due (time travel via until in the past): baseline back, dir gone, reload.
	setup(1)
	must(t, cmdExposeExpire([]string{"--all"}))
	if site() != "BASE" {
		t.Errorf("site = %q", site())
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "app")); !os.IsNotExist(err) {
		t.Error("override dir left")
	}
	if j := strings.Join(ran, "\n"); !strings.Contains(j, "systemctl try-reload-or-restart nginx.service") || strings.Contains(j, "--no-block") {
		t.Errorf("ran %v", ran)
	}
	if reloadPending() {
		t.Error("marker left after a good reload")
	}
	// --now revokes early.
	setup(time.Now().Unix() + 3600)
	must(t, cmdExposeExpire([]string{"--now", "app"}))
	if site() != "BASE" {
		t.Errorf("revoke: %q", site())
	}
	// Baseline fails nginx -t: fail closed (site removed, never WIDE).
	setup(1)
	nginxOK = false
	if err := cmdExposeExpire([]string{"app"}); err == nil {
		t.Error("want error")
	}
	if _, err := os.Stat(filepath.Join(nginxDir, "app.conf")); !os.IsNotExist(err) {
		t.Errorf("site kept: %q", site())
	}
	// Garbage override.json counts as due.
	nginxOK = true
	setup(1)
	must(t, os.WriteFile(filepath.Join(overridesDir, "app", "override.json"), []byte("{"), 0o644))
	must(t, cmdExposeExpire([]string{"app"}))
	if site() != "BASE" {
		t.Errorf("garbage: %q", site())
	}
	if err := cmdExposeExpire([]string{"../etc"}); err == nil {
		t.Error("bad name accepted")
	}
}

// overrideRig is a fake host for script-level tests: a temp dir standing in
// for /var/lib/fleet-containers with an active expose of app.web (site WIDE,
// baseline BASE), and stub nginx/systemctl in PATH. nginx -t fails while
// $dir/nginx-fail exists; systemctl reload fails while $dir/reload-fail
// exists; every systemctl call is logged.
type overrideRig struct {
	t                *testing.T
	bash, dir, bin   string
	site, ovDir, log string
}

func newOverrideRig(t *testing.T) *overrideRig {
	r := &overrideRig{t: t, bash: realPath(t, "bash"), dir: t.TempDir(), bin: t.TempDir()}
	oldO, oldN, oldI := overridesDir, nginxDir, inv
	t.Cleanup(func() { overridesDir, nginxDir, inv = oldO, oldN, oldI })
	overridesDir, nginxDir = filepath.Join(r.dir, "overrides"), filepath.Join(r.dir, "nginx")
	inv = &Inventory{DataRoot: filepath.Join(r.dir, "data"), Hosts: map[string]Host{}}
	r.site, r.ovDir, r.log = filepath.Join(nginxDir, "app.conf"), filepath.Join(overridesDir, "app"), filepath.Join(r.dir, "systemctl.log")
	must(t, os.MkdirAll(r.ovDir, 0o755))
	must(t, os.MkdirAll(nginxDir, 0o755))
	must(t, os.WriteFile(filepath.Join(r.ovDir, "baseline.conf"), []byte("BASE"), 0o644))
	must(t, os.WriteFile(filepath.Join(r.ovDir, "override.json"), []byte(`{"service":"app","route":"web","exposure":"lan","baseline":"tailnet","until":9999999999}`), 0o644))
	must(t, os.WriteFile(r.site, []byte("WIDE"), 0o644))
	writeExe(t, filepath.Join(r.bin, "nginx"), "#!"+r.bash+"\n! [ -e "+r.dir+"/nginx-fail ]\n")
	writeExe(t, filepath.Join(r.bin, "systemctl"), "#!"+r.bash+"\necho \"$*\" >> "+r.log+"\ncase \"$*\" in reload\\ nginx) ! [ -e "+r.dir+"/reload-fail ];; esac\n")
	return r
}

func (r *overrideRig) fail(what string) {
	must(r.t, os.WriteFile(filepath.Join(r.dir, what), nil, 0o644))
}

// run executes a host script with every /var/lib/fleet-containers path
// pointed at the rig.
func (r *overrideRig) run(script string) error {
	script = strings.ReplaceAll(script, "/var/lib/fleet-containers", r.dir)
	c := exec.Command(r.bash, "-c", script)
	c.Env = append(os.Environ(), "PATH="+r.bin+":"+os.Getenv("PATH"))
	out, err := c.CombinedOutput()
	r.t.Logf("script: err=%v\n%s", err, out)
	return err
}

func (r *overrideRig) siteNow() string { b, _ := os.ReadFile(r.site); return string(b) }

// assertSafe: the widened site never outlives its expiry state.
func (r *overrideRig) assertSafe() {
	r.t.Helper()
	site := r.siteNow()
	if !strings.Contains(site, "WIDE") {
		return
	}
	if _, err := os.Stat(filepath.Join(r.ovDir, "override.json")); err != nil {
		r.t.Fatalf("site is still widened (%q) but override.json is gone: permanent exposure", site)
	}
	if _, err := os.Stat(filepath.Join(r.ovDir, "baseline.conf")); err != nil {
		r.t.Fatal("override kept without baseline.conf: expiry cannot narrow")
	}
	if b, _ := os.ReadFile(r.log); strings.Contains(string(b), "stop fleet-expose-app.timer") {
		r.t.Fatal("expiry timer stopped while the widened site is live")
	}
}

func vhostOnlyScript() string {
	return "set -euo pipefail\n" + siteScript(exposeSvc(), "h001") + dropOverrideScript("app")
}

func TestVhostOnlyDeployFailureKeepsOverride(t *testing.T) {
	for _, what := range []string{"nginx-fail", "reload-fail"} {
		t.Run(what, func(t *testing.T) {
			r := newOverrideRig(t)
			r.fail(what)
			if r.run(vhostOnlyScript()) == nil {
				t.Fatal("deploy --vhost-only succeeded with a failing nginx")
			}
			if r.siteNow() != "WIDE" {
				t.Errorf("site = %q, want the previous (widened) one restored", r.siteNow())
			}
			r.assertSafe()
			// ...and the expiry job still narrows it.
			old := runCmd
			defer func() { runCmd = old }()
			runCmd = func(string, ...string) error { return nil }
			must(t, cmdExposeExpire([]string{"--now", "app"}))
			if r.siteNow() != "BASE" {
				t.Errorf("after expiry site = %q, want BASE", r.siteNow())
			}
		})
	}
}

func TestVhostOnlyDeploySuccessDropsOverride(t *testing.T) {
	r := newOverrideRig(t)
	must(t, r.run(vhostOnlyScript()))
	if s := r.siteNow(); !strings.Contains(s, "generated from routes") || strings.Contains(s, "WIDE") {
		t.Errorf("site = %q, want the service.nix vhost", s)
	}
	if _, err := os.Stat(r.ovDir); !os.IsNotExist(err) {
		t.Error("override dir left after a successful deploy")
	}
	if b, _ := os.ReadFile(r.log); !strings.Contains(string(b), "stop fleet-expose-app.timer") {
		t.Errorf("timer not stopped: %s", b)
	}
}

func TestFullDeployFailureKeepsOverride(t *testing.T) {
	// Fails at the site step (nginx -t), and fails before it (host check).
	t.Run("nginx -t", func(t *testing.T) {
		r := newOverrideRig(t)
		r.fail("nginx-fail")
		if r.run(prepareScript(exposeSvc(), "h001")) == nil {
			t.Fatal("prepare succeeded")
		}
		r.assertSafe()
	})
	t.Run("before site", func(t *testing.T) {
		r := newOverrideRig(t)
		s := exposeSvc()
		s.Requires = []string{"nope"}
		old := capDir
		defer func() { capDir = old }()
		capDir = filepath.Join(r.dir, "caps")
		if r.run(prepareScript(s, "h001")) == nil {
			t.Fatal("prepare succeeded")
		}
		if r.siteNow() != "WIDE" {
			t.Fatalf("site touched: %q", r.siteNow())
		}
		r.assertSafe()
	})
	// Interrupted at any point: cut the script after every line and check.
	t.Run("interrupted", func(t *testing.T) {
		lines := strings.SplitAfter(prepareScript(exposeSvc(), "h001"), "\n")
		for i := range lines {
			r := newOverrideRig(t)
			_ = r.run(strings.Join(lines[:i], "") + "\nexit 0\n")
			r.assertSafe()
		}
	})
	t.Run("success", func(t *testing.T) {
		r := newOverrideRig(t)
		must(t, r.run(prepareScript(exposeSvc(), "h001")))
		if _, err := os.Stat(r.ovDir); !os.IsNotExist(err) || strings.Contains(r.siteNow(), "WIDE") {
			t.Errorf("success: site %q, override dir err %v", r.siteNow(), err)
		}
	})
}

func TestDestroyRemovesSiteBeforeOverride(t *testing.T) {
	lines := strings.SplitAfter(cleanupScript(exposeSvc()), "\n")
	for i := range lines {
		r := newOverrideRig(t)
		_ = r.run(strings.Join(lines[:i], "") + "\nexit 0\n")
		r.assertSafe()
	}
	r := newOverrideRig(t)
	must(t, r.run(cleanupScript(exposeSvc())))
	if _, err := os.Stat(r.site); !os.IsNotExist(err) {
		t.Error("site left")
	}
	if _, err := os.Stat(r.ovDir); !os.IsNotExist(err) {
		t.Error("override left")
	}
}

// A rejected re-expose must not delete the live override it was replacing.
func TestReexposeFailureKeepsOldOverride(t *testing.T) {
	r := newOverrideRig(t)
	r.fail("nginx-fail")
	s := exposeSvc()
	sc := exposeScript(s, override{Service: "app", Route: "web", Exposure: "lan", Baseline: "tailnet"}, 60, "BASE", "WIDER")
	// Skip the host-module checks (first lines up to `d=`).
	sc = "set -eu\n" + sc[strings.Index(sc, "d='"):]
	if r.run(sc) == nil {
		t.Fatal("expose succeeded")
	}
	r.assertSafe()
	if b, _ := os.ReadFile(filepath.Join(r.ovDir, "override.json")); !strings.Contains(string(b), "9999999999") {
		t.Errorf("old override not restored: %s", b)
	}
}

// expireRig: one override dir + site, stubbed nginx/systemctl.
type expireRig struct {
	t                *testing.T
	ran              []string
	testOK, reloadOK bool
}

func newExpireRig(t *testing.T) *expireRig {
	t.Helper()
	dir := t.TempDir()
	oldO, oldN, oldR := overridesDir, nginxDir, runCmd
	t.Cleanup(func() { overridesDir, nginxDir, runCmd = oldO, oldN, oldR })
	overridesDir, nginxDir = filepath.Join(dir, "ov"), filepath.Join(dir, "nginx")
	r := &expireRig{t: t, testOK: true, reloadOK: true}
	runCmd = func(n string, a ...string) error {
		c := n + " " + strings.Join(a, " ")
		r.ran = append(r.ran, c)
		if n == "nginx" && !r.testOK || n == "systemctl" && strings.Contains(c, "reload") && !r.reloadOK {
			return os.ErrInvalid
		}
		return nil
	}
	must(t, os.MkdirAll(nginxDir, 0o755))
	return r
}

func (r *expireRig) setup(svc, exposure string, until int64) {
	d := filepath.Join(overridesDir, svc)
	must(r.t, os.MkdirAll(d, 0o755))
	must(r.t, os.WriteFile(filepath.Join(d, "baseline.conf"), []byte("BASE"), 0o644))
	must(r.t, os.WriteFile(filepath.Join(d, "override.json"), []byte(`{"service":"`+svc+`","route":"web","exposure":"`+exposure+`","baseline":"tailnet","until":`+strconv.FormatInt(until, 10)+`}`), 0o644))
	must(r.t, os.WriteFile(filepath.Join(nginxDir, svc+".conf"), []byte("WIDE"), 0o644))
}

func (r *expireRig) reloads() int {
	n := 0
	for _, c := range r.ran {
		if strings.HasPrefix(c, "systemctl") && strings.Contains(c, "reload") {
			n++
		}
	}
	return n
}

func TestExpireReloadFailureRetriedBySweep(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", 1)
	r.reloadOK = false
	if err := cmdExposeExpire([]string{"--all"}); err == nil || !strings.Contains(err.Error(), "reload pending") {
		t.Fatalf("want reload pending error, got %v", err)
	}
	if !reloadPending() {
		t.Fatal("marker not kept")
	}
	// Next sweep: no override dirs left, still retries and fails.
	if err := cmdExposeExpire([]string{"--all"}); err == nil {
		t.Fatal("sweep returned nil while reload still fails")
	}
	r.reloadOK = true
	r.ran = nil
	if err := cmdExposeExpire([]string{"--all"}); err != nil {
		t.Fatal(err)
	}
	if reloadPending() || r.reloads() != 1 {
		t.Fatalf("pending %v ran %v", reloadPending(), r.ran)
	}
	// Clean: a sweep with nothing to do runs nothing.
	r.ran = nil
	must(t, cmdExposeExpire([]string{"--all"}))
	if len(r.ran) != 0 {
		t.Fatalf("idle sweep ran %v", r.ran)
	}
}

func TestRevokeReloadFailureThenRetry(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", time.Now().Unix()+3600)
	r.reloadOK = false
	if err := cmdExposeExpire([]string{"--now", "app"}); err == nil {
		t.Fatal("revoke with failed reload returned nil")
	}
	// Site file already reverted, but the revoke is not done.
	if b, _ := os.ReadFile(filepath.Join(nginxDir, "app.conf")); string(b) != "BASE" {
		t.Fatalf("site %q", b)
	}
	// The revoke script still runs while only the marker is left.
	if sc := revokeScript("app"); !strings.Contains(sc, ".reload-pending") {
		t.Fatalf("revoke script ignores the marker:\n%s", sc)
	}
	r.reloadOK = true
	if err := cmdExposeExpire([]string{"--now", "app"}); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if reloadPending() {
		t.Fatal("marker left")
	}
}

func TestExpireBootNeverReloads(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", 1)
	must(t, cmdExposeExpire([]string{"--boot", "--all"}))
	if r.reloads() != 0 {
		t.Fatalf("boot reloaded: %v", r.ran)
	}
	if b, _ := os.ReadFile(filepath.Join(nginxDir, "app.conf")); string(b) != "BASE" {
		t.Fatalf("site %q", b)
	}
	if !reloadPending() {
		t.Fatal("boot must leave the marker for the runtime sweep")
	}
	// A pending marker alone: boot still doesn't reload.
	must(t, cmdExposeExpire([]string{"--boot", "--all"}))
	if r.reloads() != 0 {
		t.Fatalf("boot reloaded on marker: %v", r.ran)
	}
	must(t, cmdExposeExpire([]string{"--all"}))
	if r.reloads() != 1 || reloadPending() {
		t.Fatalf("runtime sweep: %v pending %v", r.ran, reloadPending())
	}
}

func TestExpireForeverSurvivesButPendingRetried(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "public", 0)
	must(t, cmdExposeExpire([]string{"--all"}))
	if b, _ := os.ReadFile(filepath.Join(nginxDir, "app.conf")); string(b) != "WIDE" || len(r.ran) != 0 {
		t.Fatalf("forever touched: %q %v", b, r.ran)
	}
	// An unrelated pending reload is still retried alongside it.
	must(t, setReloadPending("test"))
	must(t, cmdExposeExpire([]string{"--all"}))
	if r.reloads() != 1 || reloadPending() {
		t.Fatalf("pending not flushed: %v", r.ran)
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "app", "override.json")); err != nil {
		t.Fatal("forever override removed")
	}
	// Non-public without a deadline is garbage: reverted.
	r.setup("bad", "lan", 0)
	must(t, cmdExposeExpire([]string{"--all"}))
	if b, _ := os.ReadFile(filepath.Join(nginxDir, "bad.conf")); string(b) != "BASE" {
		t.Fatalf("garbage kept: %q", b)
	}
}

func TestListReportsReloadPending(t *testing.T) {
	if !hasReloadPending("{\"service\":\"a\"}\nRELOAD-PENDING\n") || hasReloadPending("{}\n") {
		t.Fatal("marker line")
	}
	if !strings.Contains(overridesListScript, ".reload-pending") {
		t.Fatal("list script ignores the marker")
	}
}

// listLocal runs the real list script against the test overridesDir.
func listLocal(t *testing.T) func(string) (hostOverrideState, error) {
	return func(h string) (hostOverrideState, error) {
		sc := strings.ReplaceAll(overridesListScript, "/var/lib/fleet-containers/overrides", overridesDir)
		out, err := exec.Command("sh", "-c", sc).Output()
		if err != nil {
			return hostOverrideState{}, err
		}
		return parseHostOverrides(string(out), h), nil
	}
}

// Regression: a revert whose reload failed used to delete the override dir,
// so the next `--reset` saw nothing and reported clean while nginx still
// served the widened vhost.
func TestResetAfterFailedReloadNotClean(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", time.Now().Unix()+3600)
	r.setup("other", "lan", time.Now().Unix()+3600)
	r.reloadOK = false
	revokes := 0
	revoke := func(string) error { revokes++; return cmdExposeExpire([]string{"--now", "app"}) }
	if err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke); err == nil {
		t.Fatal("reset with a failed reload reported clean")
	}
	if revokes != resetAttempts {
		t.Fatalf("reset gave up after %d revokes, want %d", revokes, resetAttempts)
	}
	st, _ := listLocal(t)("h001")
	if !st.Pending || !slices.Equal(st.Reverted, []string{"app"}) || len(st.Overrides) != 1 || st.Overrides[0].Service != "other" {
		t.Fatalf("after failed reload: %+v", st)
	}
	// Retry while the reload still fails: still not clean (the bug said clean).
	err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke)
	if err == nil || !strings.Contains(err.Error(), "reload still pending") || revokes != 2*resetAttempts {
		t.Fatalf("second reset: %v (revokes %d)", err, revokes)
	}
	// Reload works again: the retry clears it.
	r.reloadOK = true
	r.ran = nil
	if err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if revokes != 2*resetAttempts+1 || r.reloads() != 1 || reloadPending() {
		t.Fatalf("revokes %d ran %v pending %v", revokes, r.ran, reloadPending())
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "app")); !os.IsNotExist(err) {
		t.Fatal("orphan dir left after a good reload")
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "other", "override.json")); err != nil {
		t.Fatal("other service's override removed")
	}
	if b, _ := os.ReadFile(filepath.Join(nginxDir, "app.conf")); string(b) != "BASE" {
		t.Fatalf("site %q", b)
	}
	// Clean now: nothing to revoke.
	if err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke); err != nil || revokes != 2*resetAttempts+1 {
		t.Fatalf("clean reset: %v revokes %d", err, revokes)
	}
}

// A reload that fails once is retried within the same reset, and reset
// only reports clean after the re-read confirms it.
func TestResetRetriesUntilReloadConfirmed(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", time.Now().Unix()+3600)
	r.reloadOK = false
	revokes := 0
	revoke := func(string) error {
		revokes++
		err := cmdExposeExpire([]string{"--now", "app"})
		r.reloadOK = true // nginx recovers before the next attempt
		return err
	}
	if err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if revokes != 2 || reloadPending() {
		t.Fatalf("revokes %d pending %v", revokes, reloadPending())
	}
}

// An override dir without override.json (interrupted apply) is listed as
// an orphan and revoked by reset, not skipped as "clean".
func TestResetRevokesOrphanDir(t *testing.T) {
	r := newExpireRig(t)
	must(t, os.MkdirAll(filepath.Join(overridesDir, "app"), 0o755))
	must(t, os.WriteFile(filepath.Join(overridesDir, "app", "baseline.conf"), []byte("BASE"), 0o644))
	st, _ := listLocal(t)("h001")
	if !slices.Equal(st.Orphans, []string{"app"}) || st.residue("app") == "" {
		t.Fatalf("orphan not listed: %+v", st)
	}
	revokes := 0
	revoke := func(string) error { revokes++; return cmdExposeExpire([]string{"--now", "app"}) }
	if err := exposeReset(&resetEdge{}, nil, "app", []string{"h001"}, listLocal(t), revoke); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if revokes != 1 || r.reloads() != 1 {
		t.Fatalf("revokes %d ran %v", revokes, r.ran)
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "app")); !os.IsNotExist(err) {
		t.Fatal("orphan dir left")
	}
}

func TestMain(m *testing.M) {
	resetRetryDelay = 0
	os.Exit(m.Run())
}

func TestExpireKeepsReexposedDirOnClear(t *testing.T) {
	r := newExpireRig(t)
	r.setup("app", "lan", 1)
	r.reloadOK = false
	_ = cmdExposeExpire([]string{"--all"})
	// Re-exposed while the reload is owed: the new override survives the flush.
	r.setup("app", "lan", time.Now().Unix()+3600)
	r.reloadOK = true
	must(t, cmdExposeExpire([]string{"--all"}))
	if _, err := os.Stat(filepath.Join(overridesDir, "app", "override.json")); err != nil {
		t.Fatal("re-exposed override removed")
	}
	if _, err := os.Stat(filepath.Join(overridesDir, "app", revertedFile)); !os.IsNotExist(err) {
		t.Fatal("stale reverted marker kept")
	}
}
