package backupui

import (
	"bufio"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
)

type stubVerifier struct{}

func (stubVerifier) VerifyZitadelToken(raw string) (auth.VerifiedToken, error) {
	sub, ok := strings.CutPrefix(raw, "good-")
	if !ok {
		return auth.VerifiedToken{}, errors.New("bad token")
	}
	return auth.VerifiedToken{Subject: sub}, nil
}

type fx struct {
	svc *backup.Service
	ui  *UI
	dir string
}

func newFx(t *testing.T) *fx {
	t.Helper()
	now := time.Unix(2_000_000, 0)
	nowf := func() time.Time { return now }
	mk := func(m map[string]authority.Writer) *authority.Auth {
		a, err := authority.New(m, stubVerifier{}, nowf)
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	dir := t.TempDir()
	svc, err := backup.New(backup.Config{
		StateDir: dir,
		Writers:  mk(map[string]authority.Writer{}),
		Targets: mk(map[string]authority.Writer{
			"h004": {Sub: "h004", Peer: "100.64.0.17"},
			"h009": {Sub: "h009", Peer: "100.64.0.19"},
		}),
		Readers:  mk(map[string]authority.Writer{}),
		Subjects: func() []string { return []string{"canary", "forgejo"} },
		Now:      nowf,
	})
	if err != nil {
		t.Fatal(err)
	}
	f := &fx{svc: svc, dir: dir, ui: New(svc, Config{Group: "admin", Users: []string{"ops@example.com"}, Now: nowf})}
	local := int64(10)
	f.heartbeat(t, "h004", "100.64.0.17", true, map[string]backup.Stats{"canary": {LocalBytes: &local}})
	f.heartbeat(t, "h009", "100.64.0.19", false, nil)
	return f
}

func (f *fx) heartbeat(t *testing.T, id, peer string, pusher bool, stats map[string]backup.Stats) {
	t.Helper()
	b, _ := json.Marshal(backup.Heartbeat{URL: "rest:http://" + peer + ":8000/", Pusher: pusher, Stats: stats})
	r := httptest.NewRequest("POST", "/api/backup/targets/"+id, strings.NewReader(string(b)))
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("X-Fleet-Peer", peer)
	r.Header.Set("Authorization", "Bearer good-"+id)
	w := httptest.NewRecorder()
	f.svc.Handler().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("heartbeat %s: %d %s", id, w.Code, w.Body)
	}
}

type req struct {
	user, groups, remote, origin, csrf string
	form                               url.Values
}

const admin = "josh@example.com"

func (f *fx) post(path string, q req) *httptest.ResponseRecorder {
	if q.user == "" {
		q.user = admin
	}
	if q.groups == "" {
		q.groups = "role:admin"
	}
	if q.remote == "" {
		q.remote = "127.0.0.1:4000"
	}
	if q.origin == "" {
		q.origin = "https://fleet.example.com"
	}
	if q.form == nil {
		q.form = url.Values{}
	}
	if q.csrf == "" {
		q.csrf = f.ui.token(q.user)
	}
	if q.csrf != "-" {
		q.form.Set("csrf", q.csrf)
	}
	r := httptest.NewRequest("POST", path, strings.NewReader(q.form.Encode()))
	r.Host = "fleet.example.com"
	r.RemoteAddr = q.remote
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Header.Set("Origin", q.origin)
	r = as(r, q.user, q.groups)
	w := httptest.NewRecorder()
	f.ui.ServeHTTP(w, r)
	return w
}

// follow GETs the redirect target as the same user and returns the page.
func (f *fx) follow(t *testing.T, w *httptest.ResponseRecorder) (int, string) {
	t.Helper()
	if w.Code != http.StatusSeeOther {
		t.Fatalf("want redirect, got %d %s", w.Code, w.Body)
	}
	r := httptest.NewRequest("GET", w.Header().Get("Location"), nil)
	r.RemoteAddr = "127.0.0.1:4000"
	r = as(r, admin, "role:admin")
	g := httptest.NewRecorder()
	f.ui.ServeHTTP(g, r)
	return g.Code, g.Body.String()
}

func (f *fx) row(subject string) *backup.Row {
	for _, r := range f.svc.Snapshot().Rows {
		if r.Subject == subject {
			return r
		}
	}
	return nil
}

func (f *fx) audit(t *testing.T) []map[string]any {
	t.Helper()
	fh, err := os.Open(filepath.Join(f.dir, "backup-audit.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	var out []map[string]any
	for sc := bufio.NewScanner(fh); sc.Scan(); {
		var m map[string]any
		_ = json.Unmarshal(sc.Bytes(), &m)
		if m["role"] == "ui" {
			out = append(out, m)
		}
	}
	return out
}

func form(kv ...string) url.Values {
	v := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		v.Set(kv[i], kv[i+1])
	}
	return v
}

func setForm(rev, target, local, b2, offsite string) url.Values {
	return form("revision", rev, "target", target, "was-target", "none", "retentionLocal", local,
		"was-retentionLocal", "standard", "retentionB2", b2, "was-retentionB2", "local", "offsite", offsite)
}

func TestCSRFMissingOrForged(t *testing.T) {
	f := newFx(t)
	for _, tok := range []string{"-", "deadbeef", New(nil, Config{}).token(admin), f.ui.token("someone-else")} {
		if w := f.post("/backup/canary/policy", req{csrf: tok, form: setForm("0", "h004", "long", "local", "")}); w.Code != 403 {
			t.Fatalf("csrf %q: %d", tok, w.Code)
		}
	}
	if f.row("canary") != nil {
		t.Fatal("row written despite bad CSRF")
	}
}

func TestWrongOrigin(t *testing.T) {
	f := newFx(t)
	for _, o := range []string{"https://evil.example", "null", "http://fleet.example.com.evil"} {
		if w := f.post("/backup/canary/off", req{origin: o, form: form("revision", "0")}); w.Code != 403 {
			t.Fatalf("origin %q: %d", o, w.Code)
		}
	}
	// No Origin and no Referer at all.
	r := httptest.NewRequest("POST", "/backup/canary/off", strings.NewReader(url.Values{"csrf": {f.ui.token(admin)}, "revision": {"0"}}.Encode()))
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r = as(r, admin, "admin")
	w := httptest.NewRecorder()
	f.ui.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("no origin: %d", w.Code)
	}
}

// as attaches a verified identity, as auth.Require does after checking the
// session cookie.
func as(r *http.Request, user, groups string) *http.Request {
	var roles []string
	for _, g := range strings.Split(groups, ",") {
		if g = strings.TrimSpace(g); g != "" {
			roles = append(roles, g)
		}
	}
	return r.WithContext(auth.WithIdentity(r.Context(), auth.Identity{Subject: user, Name: user, Roles: roles}))
}

// TestHeadersAreNotIdentity: the old oauth2-proxy headers, even from
// loopback, are not an identity; only a verified session is.
func TestHeadersAreNotIdentity(t *testing.T) {
	f := newFx(t)
	for _, method := range []string{"GET", "POST"} {
		r := httptest.NewRequest(method, "/backup/", nil)
		if method == "POST" {
			r = httptest.NewRequest(method, "/backup/canary/policy", strings.NewReader(setForm("0", "h004", "long", "local", "").Encode()))
			r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		}
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("X-Auth-Request-Email", admin)
		r.Header.Set("X-Auth-Request-Groups", "admin")
		g := httptest.NewRecorder()
		f.ui.ServeHTTP(g, r)
		if g.Code != 403 {
			t.Fatalf("%s with forged headers: %d", method, g.Code)
		}
	}
	if f.row("canary") != nil {
		t.Fatal("forged POST wrote a row")
	}
}

func TestNonAllowedUser(t *testing.T) {
	f := newFx(t)
	w := f.post("/backup/canary/policy", req{user: "guest@example.com", groups: "viewer", form: setForm("0", "h004", "long", "local", "")})
	if w.Code != 403 || f.row("canary") != nil {
		t.Fatalf("guest: %d", w.Code)
	}
	// The explicit allowlist works without the group.
	w = f.post("/backup/canary/off", req{user: "ops@example.com", groups: "viewer", form: form("revision", "0")})
	if c, _ := f.follow(t, w); c != 200 {
		t.Fatalf("allowlisted user: %d", c)
	}
	// Read-only render for the guest has no forms.
	r := httptest.NewRequest("GET", "/backup/", nil)
	r.RemoteAddr = "127.0.0.1:1"
	r = as(r, "guest", "")
	g := httptest.NewRecorder()
	f.ui.ServeHTTP(g, r)
	if g.Code != 200 || strings.Contains(g.Body.String(), "<form") {
		t.Fatalf("guest page: %d", g.Code)
	}
}

// TestUnlistedRepoReadOnly: a repo h004 reports outside the inventory shows
// up marked, without forms the API would refuse (unknown subject).
func TestUnlistedRepoReadOnly(t *testing.T) {
	f := newFx(t)
	local := int64(10)
	f.heartbeat(t, "h004", "100.64.0.17", true, map[string]backup.Stats{"canary": {LocalBytes: &local}, "retired": {LocalBytes: &local}})
	r := httptest.NewRequest("GET", "/backup/", nil)
	r.RemoteAddr = "127.0.0.1:1"
	r = as(r, admin, "role:admin")
	g := httptest.NewRecorder()
	f.ui.ServeHTTP(g, r)
	page := g.Body.String()
	if g.Code != 200 || !strings.Contains(page, `retired <span class="warn">(not in inventory)</span>`) {
		t.Fatalf("page: %d\n%s", g.Code, page)
	}
	if strings.Contains(page, `action="/backup/retired/`) || !strings.Contains(page, `action="/backup/canary/policy"`) {
		t.Fatalf("forms:\n%s", page)
	}
}

func TestSetTargetPresetOffsite(t *testing.T) {
	f := newFx(t)
	code, page := f.follow(t, f.post("/backup/canary/policy", req{form: setForm("0", "h004", "long", "standard", "on")}))
	if code != 200 || !strings.Contains(page, "canary: policy saved") {
		t.Fatalf("set: %d %s", code, page)
	}
	r := f.row("canary")
	if r == nil || r.Target != "h004" || r.RetentionLocal != "long" || r.RetentionB2 != "standard" || !r.Offsite {
		t.Fatalf("row: %+v", r)
	}
	if !strings.Contains(r.By, admin) {
		t.Fatalf("by: %q", r.By)
	}
	// The editor renders the row with its controls and revision.
	if !strings.Contains(page, `action="/backup/canary/policy"`) || !strings.Contains(page, `name="csrf"`) {
		t.Fatal("page lacks the policy form")
	}
}

func TestOffsiteRefusedOnNonPusher(t *testing.T) {
	f := newFx(t)
	code, page := f.follow(t, f.post("/backup/canary/policy", req{form: setForm("0", "h009", "standard", "local", "on")}))
	if code != 409 || !strings.Contains(page, "not a pusher") || f.row("canary") != nil {
		t.Fatalf("non-pusher offsite: %d", code)
	}
	// The toggle is disabled with the reason for a non-pusher row.
	f.post("/backup/canary/policy", req{form: setForm("0", "h009", "standard", "local", "")})
	_, page = f.follow(t, f.post("/backup/forgejo/off", req{form: form("revision", "0")}))
	if !strings.Contains(page, "h009 is not a pusher") {
		t.Fatal("no disabled reason")
	}
}

func TestStaleRevision(t *testing.T) {
	f := newFx(t)
	f.follow(t, f.post("/backup/canary/policy", req{form: setForm("0", "h004", "long", "local", "")}))
	code, page := f.follow(t, f.post("/backup/canary/policy", req{form: setForm("0", "h004", "short", "local", "")}))
	if code != 409 || !strings.Contains(page, "changed since revision") {
		t.Fatalf("stale: %d", code)
	}
	if f.row("canary").RetentionLocal != "long" {
		t.Fatal("stale write applied")
	}
}

func TestClearNeedsTypedName(t *testing.T) {
	f := newFx(t)
	for _, typed := range []string{"", "forgejo", "canar"} {
		code, _ := f.follow(t, f.post("/backup/canary/clear", req{form: form("scope", "local", "confirm", typed)}))
		if code != 400 || f.row("canary") != nil {
			t.Fatalf("confirm %q: %d", typed, code)
		}
	}
	code, page := f.follow(t, f.post("/backup/canary/clear", req{form: form("scope", "local", "confirm", "canary")}))
	if code != 200 || !strings.Contains(page, "clear local queued") {
		t.Fatalf("clear: %d", code)
	}
	if r := f.row("canary"); r == nil || r.Clear == nil || r.Clear.Scope != "local" {
		t.Fatalf("row: %+v", r)
	}
}

func TestTurnOff(t *testing.T) {
	f := newFx(t)
	f.follow(t, f.post("/backup/canary/policy", req{form: setForm("0", "h004", "long", "local", "")}))
	rev := f.row("canary").Revision
	code, _ := f.follow(t, f.post("/backup/canary/off", req{form: form("revision", jsonInt(rev))}))
	if code != 200 || f.row("canary").Target != backup.None {
		t.Fatalf("off: %d %+v", code, f.row("canary"))
	}
}

func TestAuditLinePerWrite(t *testing.T) {
	f := newFx(t)
	posts := []func() *httptest.ResponseRecorder{
		func() *httptest.ResponseRecorder {
			return f.post("/backup/canary/policy", req{form: setForm("0", "h004", "long", "local", "")})
		},
		func() *httptest.ResponseRecorder {
			return f.post("/backup/canary/policy", req{form: setForm("0", "h004", "long", "local", "")})
		}, // 409
		func() *httptest.ResponseRecorder { return f.post("/backup/canary/off", req{csrf: "bad"}) },
		func() *httptest.ResponseRecorder {
			return f.post("/backup/canary/clear", req{form: form("scope", "local", "confirm", "canary")})
		},
	}
	for _, p := range posts {
		p()
	}
	lines := f.audit(t)
	if len(lines) != len(posts) {
		t.Fatalf("audit lines %d, posts %d: %v", len(lines), len(posts), lines)
	}
	want := []float64{200, 409, 403, 200}
	for i, l := range lines {
		if l["user"] != admin || l["code"] != want[i] {
			t.Fatalf("line %d: %v", i, l)
		}
	}
}

func TestSignedFlashOnly(t *testing.T) {
	f := newFx(t)
	r := httptest.NewRequest("GET", "/backup/?ok=pwned&code=200&sig=x", nil)
	r.RemoteAddr = "127.0.0.1:1"
	r = as(r, admin, "")
	w := httptest.NewRecorder()
	f.ui.ServeHTTP(w, r)
	if strings.Contains(w.Body.String(), "pwned") {
		t.Fatal("unsigned flash rendered")
	}
}

func jsonInt(n int64) string { b, _ := json.Marshal(n); return string(b) }
