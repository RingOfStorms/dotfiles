package containers

import (
	"os"
	"os/exec"
	"path/filepath"
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
	return Service{Name: "app", Host: "h001", Routes: map[string]Route{
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
		{"web", "public", "fleet-edge"},
		{"web", "internet", "want tailnet or lan"},
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
		"[ -e /etc/systemd/system/fleet-containers-expose-expire.service ]", // module check
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
	tbl := routesTableWith([]Service{exposeSvc()}, []override{{Service: "app", Route: "web", Exposure: "lan", Baseline: "tailnet", Until: 1180}}, now)
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
	if !strings.Contains(strings.Join(ran, "\n"), "--no-block try-reload-or-restart nginx.service") {
		t.Errorf("ran %v", ran)
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
