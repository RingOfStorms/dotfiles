package edgevhost

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testCfg(t *testing.T) *Config {
	t.Helper()
	return &Config{
		Domain: "example.com", Dir: t.TempDir(), CertDir: "/var/lib/fleet-cert/example.com/current",
		Hosts:     map[string]string{"h001": "100.64.0.13"},
		Reserved:  []string{"www.example.com"},
		NginxTest: "test", NginxReload: "reload", LimitZone: "fleet_edge_rt",
	}
}

func addReq() *Request {
	return &Request{Op: "add", FQDN: "app.example.com", Host: "h001", Until: time.Now().Add(time.Hour).Unix(),
		MaxBody: "100m", Websockets: true, Buffering: true, RequestBuffering: true, Timeouts: "60s"}
}

func stubRunner(t *testing.T, failTest bool) *[]string {
	t.Helper()
	var calls []string
	old := Runner
	Runner = func(c string) error {
		calls = append(calls, c)
		if c == "test" && failTest {
			return errors.New("boom")
		}
		return nil
	}
	t.Cleanup(func() { Runner = old })
	return &calls
}

func TestValidateRefuses(t *testing.T) {
	c := testCfg(t)
	cases := map[string]func(r *Request){
		"single label":  func(r *Request) { r.FQDN = "a.b.example.com" },
		"other domain":  func(r *Request) { r.FQDN = "app.evil.com" },
		"upper case":    func(r *Request) { r.FQDN = "App.example.com" },
		"reserved":      func(r *Request) { r.FQDN = "www.example.com" },
		"unknown host":  func(r *Request) { r.Host = "nope" },
		"maxBody":       func(r *Request) { r.MaxBody = "1m; include /etc/passwd" },
		"timeouts":      func(r *Request) { r.Timeouts = "60s;" },
		"negative":      func(r *Request) { r.Until = -5 },
		"injection fq":  func(r *Request) { r.FQDN = "a;b.example.com" },
		"bad op":        func(r *Request) { r.Op = "exec" },
		"apex refused":  func(r *Request) { r.FQDN = "example.com" },
		"empty label":   func(r *Request) { r.FQDN = ".example.com" },
		"trailing dash": func(r *Request) { r.FQDN = "app-.example.com" },
	}
	for name, mut := range cases {
		r := addReq()
		mut(r)
		if err := c.Validate(r); err == nil {
			t.Errorf("%s: accepted %+v", name, r)
		}
	}
	if err := c.Validate(addReq()); err != nil {
		t.Fatal(err)
	}
}

func TestRenderMatchesEdgeVirtualHosts(t *testing.T) {
	c := testCfg(t)
	r := addReq()
	out := c.Render(r)
	for _, w := range []string{
		"proxy_pass http://100.64.0.13:8443;",
		"server_name app.example.com;",
		"ssl_certificate /var/lib/fleet-cert/example.com/current/fullchain.pem;",
		"client_max_body_size 100m;",
		"proxy_set_header Connection $connection_upgrade;",
		"proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
		"limit_req zone=fleet_edge_rt",
		"proxy_read_timeout 60s;",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("missing %q in\n%s", w, out)
		}
	}
	e, ok := ParseHeader([]byte(out))
	if !ok || e.FQDN != r.FQDN || e.Until != r.Until || e.Host != "h001" {
		t.Errorf("header %+v %v", e, ok)
	}
}

// A placement vhost has no expiry, carries its kind in the header (so list
// reports who owns it) and renders without the expose path's rate limit.
func TestPlacementKind(t *testing.T) {
	c := testCfg(t)
	r := addReq()
	r.Kind, r.Until = KindPlacement, 0
	if err := c.Validate(r); err != nil {
		t.Fatal(err)
	}
	out := c.Render(r)
	if strings.Contains(out, "limit_req") || !strings.Contains(out, "fleet-edge placements") {
		t.Errorf("render\n%s", out)
	}
	if e, ok := ParseHeader([]byte(out)); !ok || e.Kind != KindPlacement || e.Until != 0 {
		t.Errorf("header %+v %v", e, ok)
	}
	r.Until = time.Now().Add(time.Hour).Unix()
	if err := c.Validate(r); err == nil {
		t.Error("placement with an expiry accepted")
	}
	r.Kind, r.Until = "other", 0
	if err := c.Validate(r); err == nil {
		t.Error("unknown kind accepted")
	}
	stubRunner(t, false)
	r.Kind = KindPlacement
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	l, err := c.List()
	if err != nil || len(l) != 1 || l[0].Kind != KindPlacement {
		t.Fatalf("list %+v %v", l, err)
	}
}

func TestAddRemoveIdempotent(t *testing.T) {
	c := testCfg(t)
	calls := stubRunner(t, false)
	r := addReq()
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 2 { // one test + one reload; the identical re-add is a no-op
		t.Errorf("calls %v", *calls)
	}
	var buf bytes.Buffer
	if err := c.Handle(&Request{Op: "list"}, &buf); err != nil || !strings.Contains(buf.String(), "app.example.com") {
		t.Fatalf("list %q %v", buf.String(), err)
	}
	if err := c.Handle(&Request{Op: "remove", FQDN: r.FQDN}, nil); err != nil {
		t.Fatal(err)
	}
	if err := c.Handle(&Request{Op: "remove", FQDN: r.FQDN}, nil); err != nil {
		t.Fatalf("second remove: %v", err)
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "app.example.com.conf")); !os.IsNotExist(err) {
		t.Fatal("file still there")
	}
}

// A remove is fenced by owner: it deletes only a file whose header carries
// the caller's kind (and host, if given); another owner's file is kept, the
// caller sees "kept: owned by <kind>" and no error.
func TestRemoveFencedByKind(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	conf := filepath.Join(c.Dir, "app.example.com.conf")
	placement := addReq()
	placement.Kind, placement.Until = KindPlacement, 0
	expose := addReq()
	remove := func(kind, host string) string {
		t.Helper()
		var buf bytes.Buffer
		if err := c.Handle(&Request{Op: "remove", Kind: kind, FQDN: "app.example.com", Host: host}, &buf); err != nil {
			t.Fatalf("remove kind %q host %q: %v", kind, host, err)
		}
		return buf.String()
	}
	exists := func() bool { _, err := os.Stat(conf); return err == nil }

	// An expose remove leaves a placement file.
	if err := c.Handle(placement, nil); err != nil {
		t.Fatal(err)
	}
	if out := remove(KindExpose, ""); !exists() || !strings.HasPrefix(out, KeptPrefix+"placement") {
		t.Fatalf("expose remove: exists=%v out %q", exists(), out)
	}
	// A matching kind on another host is kept too.
	if out := remove(KindPlacement, "h002"); !exists() || !strings.HasPrefix(out, KeptPrefix+"placement") {
		t.Fatalf("host-fenced remove: exists=%v out %q", exists(), out)
	}
	// A matching remove deletes.
	if out := remove(KindPlacement, "h001"); exists() || out != "" {
		t.Fatalf("placement remove: exists=%v out %q", exists(), out)
	}

	// A placement remove leaves an expose file.
	if err := c.Handle(expose, nil); err != nil {
		t.Fatal(err)
	}
	if out := remove(KindPlacement, ""); !exists() || !strings.HasPrefix(out, KeptPrefix+"expose") {
		t.Fatalf("placement remove: exists=%v out %q", exists(), out)
	}
	if out := remove(KindExpose, ""); exists() || out != "" {
		t.Fatalf("expose remove: exists=%v out %q", exists(), out)
	}

	if err := c.Handle(&Request{Op: "remove", Kind: "other", FQDN: "app.example.com"}, nil); err == nil {
		t.Error("remove with an unknown kind accepted")
	}
}

// A live expose override wins over a placement of the same name: the
// receiver keeps the expose file on a placement add (no error) until it
// expires; an expose add replaces a placement file.
func TestPlacementAddKeepsLiveExpose(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	conf := filepath.Join(c.Dir, "app.example.com.conf")
	expose := addReq()
	placement := addReq()
	placement.Kind, placement.Until = KindPlacement, 0
	if err := c.Handle(expose, nil); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(conf)
	var buf bytes.Buffer
	if err := c.Handle(placement, &buf); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(conf)
	if !bytes.Equal(before, after) || !strings.HasPrefix(buf.String(), KeptPrefix+"expose") {
		t.Fatalf("placement add over live expose: out %q, changed=%v", buf.String(), !bytes.Equal(before, after))
	}
	// Expired expose (Expire has not run yet): the placement takes over.
	dead := addReq()
	dead.Until = time.Now().Add(-time.Minute).Unix()
	_ = os.WriteFile(conf, []byte(c.Render(dead)), 0o644)
	buf.Reset()
	if err := c.Handle(placement, &buf); err != nil || buf.Len() != 0 {
		t.Fatalf("placement add over expired expose: %v %q", err, buf.String())
	}
	if e, ok := c.current("app.example.com"); !ok || e.Kind != KindPlacement {
		t.Fatalf("header %+v %v", e, ok)
	}
	// An expose add replaces a placement file.
	if err := c.Handle(expose, nil); err != nil {
		t.Fatal(err)
	}
	if e, ok := c.current("app.example.com"); !ok || e.Kind != KindExpose {
		t.Fatalf("header %+v %v", e, ok)
	}
}

// Through Receive (the forced command), a kept remove still exits 0.
func TestReceiveKeptRemove(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	r := addReq()
	r.Kind, r.Until = KindPlacement, 0
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "cfg.json")
	_ = os.WriteFile(p, []byte(`{"domain":"example.com","dir":"`+c.Dir+`","certDir":"/x","nginxTest":"test","nginxReload":"reload","hosts":{}}`), 0o644)
	var out bytes.Buffer
	if err := Receive(p, strings.NewReader(`{"op":"remove","fqdn":"app.example.com"}`), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), KeptPrefix+"placement") {
		t.Fatalf("out %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "app.example.com.conf")); err != nil {
		t.Fatal("placement file removed by an expose remove")
	}
}

func TestAddRollbackOnNginxTest(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	r := addReq()
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(c.Dir, "app.example.com.conf"))
	stubRunner(t, true)
	r2 := addReq()
	r2.MaxBody = "5m"
	if err := c.Handle(r2, nil); err == nil {
		t.Fatal("want nginx -t failure")
	}
	after, _ := os.ReadFile(filepath.Join(c.Dir, "app.example.com.conf"))
	if !bytes.Equal(before, after) {
		t.Fatal("previous file not restored")
	}
	// A failed first add leaves nothing behind.
	r3 := addReq()
	r3.FQDN = "new.example.com"
	if err := c.Handle(r3, nil); err == nil {
		t.Fatal("want failure")
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "new.example.com.conf")); !os.IsNotExist(err) {
		t.Fatal("failed add left a file")
	}
}

func TestExpireLocal(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	live, dead, forever := addReq(), addReq(), addReq()
	dead.FQDN, forever.FQDN = "dead.example.com", "forever.example.com"
	forever.Until = 0
	for _, r := range []*Request{live, forever} {
		if err := c.Handle(r, nil); err != nil {
			t.Fatal(err)
		}
	}
	dead.Until = time.Now().Add(-time.Minute).Unix()
	_ = os.WriteFile(filepath.Join(c.Dir, "dead.example.com.conf"), []byte(c.Render(dead)), 0o644)
	_ = os.WriteFile(filepath.Join(c.Dir, "junk.example.com.conf"), []byte("server {}\n"), 0o644)
	gone, err := c.Expire(time.Now(), true)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(gone, ",") != "dead.example.com.conf,junk.example.com.conf" {
		t.Fatalf("gone %v", gone)
	}
	l, _ := c.List()
	if len(l) != 2 {
		t.Fatalf("left %v", l)
	}
}

func TestReceiveRejectsUnknownFields(t *testing.T) {
	c := testCfg(t)
	p := filepath.Join(t.TempDir(), "cfg.json")
	_ = os.WriteFile(p, []byte(`{"domain":"example.com","dir":"`+c.Dir+`","certDir":"/x","nginxTest":"test","nginxReload":"reload","hosts":{}}`), 0o644)
	if err := Receive(p, strings.NewReader(`{"op":"list","raw":"server{}"}`), &bytes.Buffer{}); err == nil {
		t.Fatal("unknown field accepted")
	}
}

// failReload: a runner whose reload fails while *fail is true.
func failReload(t *testing.T, fail *bool) *[]string {
	t.Helper()
	var calls []string
	old := Runner
	Runner = func(c string) error {
		calls = append(calls, c)
		if c == "reload" && *fail {
			return errors.New("reload boom")
		}
		return nil
	}
	t.Cleanup(func() { Runner = old })
	return &calls
}

func TestRevokeReloadFailureRetried(t *testing.T) {
	c := testCfg(t)
	fail := false
	calls := failReload(t, &fail)
	r := addReq()
	if err := c.Handle(r, nil); err != nil || c.Pending() {
		t.Fatalf("add: %v pending=%v", err, c.Pending())
	}
	fail = true
	rm := &Request{Op: "remove", FQDN: r.FQDN}
	if err := c.Handle(rm, nil); err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		t.Fatalf("revoke with failing reload: %v", err)
	}
	if !c.Pending() {
		t.Fatal("marker not set")
	}
	// File is gone, but the second revoke must not report success yet.
	if err := c.Handle(rm, nil); err == nil {
		t.Fatal("second revoke returned nil while reload still fails")
	}
	// list reports it too.
	if err := c.Handle(&Request{Op: "list"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		t.Fatalf("list: %v", err)
	}
	fail = false
	n := len(*calls)
	if err := c.Handle(rm, nil); err != nil {
		t.Fatalf("third revoke: %v", err)
	}
	if got := (*calls)[n:]; strings.Join(got, ",") != "test,reload" {
		t.Fatalf("retry calls %v", got)
	}
	if c.Pending() {
		t.Fatal("marker not cleared")
	}
	// Clean state: an "already gone" remove runs nothing.
	n = len(*calls)
	if err := c.Handle(rm, nil); err != nil || len(*calls) != n {
		t.Fatalf("clean no-op: %v %v", err, (*calls)[n:])
	}
}

func TestExpireReloadFailureRetriedWithNoFiles(t *testing.T) {
	c := testCfg(t)
	fail := false
	calls := failReload(t, &fail)
	dead := addReq()
	dead.Until = time.Now().Add(-time.Minute).Unix()
	_ = os.WriteFile(filepath.Join(c.Dir, "app.example.com.conf"), []byte(c.Render(dead)), 0o644)
	fail = true
	gone, err := c.Expire(time.Now(), true)
	if len(gone) != 1 || err == nil || !c.Pending() {
		t.Fatalf("gone %v err %v pending %v", gone, err, c.Pending())
	}
	// Boot run (no reload) keeps the marker.
	if _, err := c.Expire(time.Now(), false); err != nil || !c.Pending() {
		t.Fatalf("no-reload run: %v %v", err, c.Pending())
	}
	fail = false
	n := len(*calls)
	gone, err = c.Expire(time.Now(), true)
	if len(gone) != 0 || err != nil {
		t.Fatalf("retry: %v %v", gone, err)
	}
	if strings.Join((*calls)[n:], ",") != "test,reload" || c.Pending() {
		t.Fatalf("calls %v pending %v", (*calls)[n:], c.Pending())
	}
	// Nothing to do: no reload.
	n = len(*calls)
	if _, err := c.Expire(time.Now(), true); err != nil || len(*calls) != n {
		t.Fatalf("idle expire ran %v", (*calls)[n:])
	}
}

func TestAddReloadFailureLeavesMarker(t *testing.T) {
	c := testCfg(t)
	fail := true
	calls := failReload(t, &fail)
	r := addReq()
	if err := c.Handle(r, nil); err == nil || !c.Pending() {
		t.Fatalf("add: %v pending %v", err, c.Pending())
	}
	fail = false
	n := len(*calls)
	// Identical re-add is a no-op for the file but must flush the reload.
	if err := c.Handle(r, nil); err != nil {
		t.Fatal(err)
	}
	if strings.Join((*calls)[n:], ",") != "test,reload" || c.Pending() {
		t.Fatalf("calls %v pending %v", (*calls)[n:], c.Pending())
	}
}

func TestNginxTestFailureClearsOwnMarker(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, true)
	if err := c.Handle(addReq(), nil); err == nil {
		t.Fatal("want failure")
	}
	if c.Pending() {
		t.Fatal("rolled-back add left the marker")
	}
}
