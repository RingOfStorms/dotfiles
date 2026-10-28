package overrides

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/bunny"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgevhost"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

func sp(s string) *string { return &s }

type fakeDNS struct {
	zone bunny.Zone
	next int64
	fail error
	log  []string
}

func (f *fakeDNS) Zone(context.Context) (*bunny.Zone, error) {
	if f.fail != nil {
		return nil, f.fail
	}
	z := f.zone
	z.Records = append([]bunny.Record(nil), f.zone.Records...)
	return &z, nil
}
func (f *fakeDNS) Create(_ context.Context, _ int64, name, value string, ttl int) (int64, error) {
	if f.fail != nil {
		return 0, f.fail
	}
	f.next++
	f.zone.Records = append(f.zone.Records, bunny.Record{ID: f.next, Type: 2, Name: name, Value: value, TTL: ttl})
	f.log = append(f.log, "create "+name)
	return f.next, nil
}
func (f *fakeDNS) Delete(_ context.Context, _ int64, id int64) error {
	if f.fail != nil {
		return f.fail
	}
	for i, r := range f.zone.Records {
		if r.ID == id {
			f.zone.Records = append(f.zone.Records[:i], f.zone.Records[i+1:]...)
		}
	}
	f.log = append(f.log, "delete")
	return nil
}

type fakeEdge struct {
	files map[string]edgevhost.Request
	fail  error
	// addThenFail: "add" is applied, then the call still errors (ssh
	// dropped after o002 ran the receiver).
	addThenFail error
	// removeFail: only "remove" errors.
	removeFail error
}

func (f *fakeEdge) Do(_ context.Context, r edgevhost.Request) ([]byte, error) {
	if f.fail != nil {
		return nil, f.fail
	}
	switch r.Op {
	case "add":
		f.files[r.FQDN] = r
		if f.addThenFail != nil {
			return nil, f.addThenFail
		}
	case "remove":
		if f.removeFail != nil {
			return nil, f.removeFail
		}
		delete(f.files, r.FQDN)
	case "list":
		l := []edgevhost.Entry{}
		for k, v := range f.files {
			l = append(l, edgevhost.Entry{FQDN: k, Host: v.Host, Until: v.Until})
		}
		return json.Marshal(l)
	}
	return nil, nil
}

type rig struct {
	t      *testing.T
	s      *Service
	dns    *fakeDNS
	edge   *fakeEdge
	host   []HostOverride
	hostEr error
	now    time.Time
	idp    *testIdP
}

// Writers in the rig: oren (the default caller) and lio, with their real
// subs and overlay IPs. o002's sub is a stand-in for a high-trust machine
// user that is not a writer.
const (
	orenSub  = "364267099884879875"
	orenPeer = "100.64.0.2"
	lioSub   = "344412093056811011"
	lioPeer  = "100.64.0.1"
	o002Sub  = "399999999999999995"
	o002Peer = "100.64.0.5"
	project  = "344379162166820867"
)

// testIdP serves discovery + JWKS for one RSA key and signs tokens.
type testIdP struct {
	t   *testing.T
	srv *httptest.Server
	key *rsa.PrivateKey
}

func newTestIdP(t *testing.T) *testIdP {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	p := &testIdP{t: t, key: key}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{"issuer": p.srv.URL, "jwks_uri": p.srv.URL + "/oauth/v2/keys"})
		case "/oauth/v2/keys":
			_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]any{{
				"kid": "k1", "kty": "RSA", "alg": "RS256", "use": "sig",
				"n": base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
				"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes()),
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(p.srv.Close)
	return p
}

// sign makes an RS256 JWT with kid k1 using key.
func (p *testIdP) sign(key *rsa.PrivateKey, claims map[string]any) string {
	p.t.Helper()
	h, _ := json.Marshal(map[string]any{"alg": "RS256", "typ": "JWT", "kid": "k1"})
	c, _ := json.Marshal(claims)
	in := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(c)
	sum := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		p.t.Fatal(err)
	}
	return in + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// token is a valid machine token for sub at r.now; edit tweaks the claims.
func (r *rig) token(sub string, edit func(map[string]any)) string {
	claims := map[string]any{
		"iss": r.idp.srv.URL, "sub": sub, "aud": []string{sub, project},
		"iat": r.now.Unix(), "exp": r.now.Add(time.Hour).Unix(),
	}
	if edit != nil {
		edit(claims)
	}
	return r.idp.sign(r.idp.key, claims)
}

func newRig(t *testing.T) *rig {
	t.Helper()
	r := &rig{t: t, now: time.Unix(1_000_000, 0),
		dns:  &fakeDNS{zone: bunny.Zone{ID: 7, Domain: "example.com"}, next: 100},
		edge: &fakeEdge{files: map[string]edgevhost.Request{}},
		idp:  newTestIdP(t)}
	tb := true
	inv := &inventory.Inventory{Services: map[string]inventory.Service{
		"app": {Name: "app", Host: "h001", Routes: map[string]inventory.Route{
			"web":   {Proto: "http", Exposure: "tailnet", Auth: sp("native"), FQDN: sp("app.example.com"), Zone: sp("main"), MaxBody: "100m", Timeouts: "60s", Websockets: true, RequestBuffering: &tb},
			"open":  {Proto: "http", Exposure: "tailnet", Auth: sp("none"), FQDN: sp("open.example.com"), Zone: sp("main"), MaxBody: "1m", Timeouts: "60s"},
			"gated": {Proto: "http", Exposure: "tailnet", Auth: sp("oauth2-proxy"), FQDN: sp("gated.example.com"), Zone: sp("main"), MaxBody: "1m", Timeouts: "60s"},
		}},
		"pub":  {Name: "pub", Host: "h001", Routes: map[string]inventory.Route{"web": {Proto: "http", Exposure: "public", Auth: sp("native"), FQDN: sp("pub.example.com"), Zone: sp("main"), MaxBody: "1m", Timeouts: "60s"}}},
		"priv": {Name: "priv", Host: "h001", Routes: map[string]inventory.Route{"web": {Proto: "http", Exposure: "tailnet", Auth: sp("native"), FQDN: sp("priv.ts.example.com"), Zone: sp("private"), MaxBody: "1m", Timeouts: "60s"}}},
		"decl": {Name: "decl", Host: "h001", Routes: map[string]inventory.Route{"web": {Proto: "http", Exposure: "tailnet", Auth: sp("native"), FQDN: sp("www.example.com"), Zone: sp("main"), MaxBody: "1m", Timeouts: "60s"}}},
		"tcp":  {Name: "tcp", Host: "h001", Routes: map[string]inventory.Route{"ssh": {Proto: "tcp", Exposure: "tailnet", Zone: sp("main")}}},
	}}
	verifier, err := auth.New(auth.Config{
		Zitadel:    auth.ZitadelConfig{Issuer: r.idp.srv.URL, ProjectID: project},
		HTTPClient: r.idp.srv.Client(),
		Now:        func() time.Time { return r.now },
	})
	if err != nil {
		t.Fatal(err)
	}
	s, err := New(Config{
		Inventory: inv, Spec: &bunny.Spec{Zone: "example.com", Records: []bunny.Desired{{Name: "www", Type: "CNAME", Value: "o002.example.com", Source: "hand"}}},
		Domain: "example.com", Target: "o002.example.com", StateDir: t.TempDir(),
		Verifier: verifier,
		Writers:  map[string]Writer{"oren": {Sub: orenSub, Peer: orenPeer}, "lio": {Sub: lioSub, Peer: lioPeer}},
		DNS:      r.dns, Edge: r.edge,
		Status: func(context.Context, string) ([]HostOverride, error) { return r.host, r.hostEr },
		Now:    func() time.Time { return r.now },
	})
	if err != nil {
		t.Fatal(err)
	}
	r.s = s
	return r
}

func (r *rig) hostPublic(svc, route string) {
	r.host = []HostOverride{{Service: svc, Route: route, Exposure: "public"}}
}

// call is a request through nginx (loopback + X-Fleet-Peer) as oren.
func (r *rig) call(method, path, peer string, body any) (int, map[string]any) {
	r.t.Helper()
	return r.callTok(method, path, peer, r.token(orenSub, nil), body)
}

func (r *rig) callTok(method, path, peer, tok string, body any) (int, map[string]any) {
	r.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(b))
	req.RemoteAddr = "127.0.0.1:5555"
	req.Header.Set("X-Fleet-Peer", peer)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	w := httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func (r *rig) add(svc, route string, until int64) (int, map[string]any) {
	req := Request{Service: svc, Route: route, Host: "h001", Until: until}
	if c, out := r.call("POST", "/api/overrides/prepare", orenPeer, req); c != 200 {
		return c, out
	}
	r.hostPublic(svc, route)
	return r.call("POST", "/api/overrides/commit", orenPeer, req)
}

func (r *rig) auditLog() string {
	b, _ := os.ReadFile(filepath.Join(r.s.cfg.StateDir, "audit.log"))
	return string(b)
}

func TestAuthAllowedSub(t *testing.T) {
	r := newRig(t)
	if c, out := r.call("GET", "/api/overrides", orenPeer, nil); c != 200 {
		t.Fatalf("oren: %d %v", c, out)
	}
	if c, out := r.callTok("GET", "/api/overrides", lioPeer, r.token(lioSub, nil), nil); c != 200 {
		t.Fatalf("lio: %d %v", c, out)
	}
	if c, out := r.add("app", "web", 0); c != 200 {
		t.Fatalf("write: %d %v", c, out)
	}
	if d := r.s.rows["app"].Device; d != "oren" {
		t.Errorf("row device = %q", d)
	}
	if a := r.auditLog(); !strings.Contains(a, `"host":"oren","sub":"`+orenSub+`"`) || !strings.Contains(a, `"action":"commit"`) {
		t.Errorf("audit lacks host/sub:\n%s", a)
	}
}

func TestAuthRefusals(t *testing.T) {
	r := newRig(t)
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, peer, tok, audit string
	}{
		// High trust with every role still isn't a writer: only the sub list counts.
		{"o002 sub", o002Peer, r.token(o002Sub, func(m map[string]any) {
			m["flatRolesClaim"] = []string{"machines-hightrust", "admin"}
		}), `"sub":"` + o002Sub + `"`},
		{"unknown sub", orenPeer, r.token("111111111111111111", nil), "not an override writer"},
		{"bad signature", orenPeer, r.idp.sign(other, map[string]any{
			"iss": r.idp.srv.URL, "sub": orenSub, "aud": []string{project},
			"iat": r.now.Unix(), "exp": r.now.Add(time.Hour).Unix(),
		}), "invalid JWT signature"},
		{"expired", orenPeer, r.token(orenSub, func(m map[string]any) {
			m["iat"], m["exp"] = r.now.Add(-2*time.Hour).Unix(), r.now.Add(-time.Hour).Unix()
		}), "JWT expired"},
		{"wrong source ip", lioPeer, r.token(orenSub, nil), `"host":"oren"`},
		{"wrong audience", orenPeer, r.token(orenSub, func(m map[string]any) { m["aud"] = []string{orenSub} }), "audience"},
		{"wrong issuer", orenPeer, r.token(orenSub, func(m map[string]any) { m["iss"] = "https://evil.example" }), "issuer"},
		{"missing token", orenPeer, "", "missing bearer token"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := len(r.auditLog())
			if c, _ := r.callTok("POST", "/api/overrides/prepare", tc.peer, tc.tok, Request{Service: "app", Route: "web", Host: "h001"}); c != 401 {
				t.Fatalf("got %d, want 401", c)
			}
			if a := r.auditLog()[before:]; !strings.Contains(a, `"result":"denied"`) || !strings.Contains(a, tc.audit) {
				t.Errorf("audit:\n%s", a)
			}
		})
	}
	if len(r.s.rows) != 0 {
		t.Fatalf("a refused request reserved a row: %v", r.s.rows)
	}
	// Direct (not via nginx): X-Fleet-Peer from a non-loopback peer is ignored.
	req := httptest.NewRequest("GET", "/api/overrides", nil)
	req.RemoteAddr = "100.64.0.9:1"
	req.Header.Set("X-Fleet-Peer", orenPeer)
	req.Header.Set("Authorization", "Bearer "+r.token(orenSub, nil))
	w := httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	if w.Code != 401 {
		t.Errorf("spoofed X-Fleet-Peer accepted: %d", w.Code)
	}
}

func TestNewRejectsAmbiguousWriters(t *testing.T) {
	base := Config{Inventory: &inventory.Inventory{}, Spec: &bunny.Spec{Zone: "example.com"}, Domain: "example.com",
		Target: "o002.example.com", StateDir: t.TempDir(), Verifier: &auth.Authenticator{}}
	for name, w := range map[string]map[string]Writer{
		"shared sub": {"a": {Sub: "1", Peer: "100.64.0.1"}, "b": {Sub: "1", Peer: "100.64.0.2"}},
		"no peer":    {"a": {Sub: "1"}},
		"no sub":     {"a": {Peer: "100.64.0.1"}},
	} {
		cfg := base
		cfg.Writers = w
		if _, err := New(cfg); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	base.Verifier = nil
	if _, err := New(base); err == nil {
		t.Error("nil verifier accepted")
	}
}

func TestCheckRefusals(t *testing.T) {
	r := newRig(t)
	for _, tc := range []struct{ svc, route, host, want string }{
		{"app", "open", "h001", "publicWithoutAuth"},
		{"pub", "web", "h001", "already public"},
		{"priv", "web", "h001", "zone"},
		{"decl", "web", "h001", "declared in the public spec"},
		{"tcp", "ssh", "h001", "http"},
		{"app", "web", "lio", "inventory has host"},
		{"app", "nope", "h001", "no route"},
		{"ghost", "web", "h001", "unknown service"},
	} {
		c, out := r.call("POST", "/api/overrides/prepare", "100.64.0.2", Request{Service: tc.svc, Route: tc.route, Host: tc.host, Until: 0})
		if c != 409 || !strings.Contains(out["error"].(string), tc.want) {
			t.Errorf("%s.%s@%s: %d %v", tc.svc, tc.route, tc.host, c, out["error"])
		}
	}
	if len(r.dns.log)+len(r.edge.files) != 0 {
		t.Fatal("refusal touched dns/edge")
	}
}

// ROUTING-PLAN §8 step 6: sso-proxy is public now, so auth = oauth2-proxy
// is no longer refused for a public override.
func TestCheckAllowsOauth2ProxyPublic(t *testing.T) {
	r := newRig(t)
	if c, out := r.call("POST", "/api/overrides/prepare", "100.64.0.2", Request{Service: "app", Route: "gated", Host: "h001"}); c != 200 {
		t.Fatalf("gated public prepare: %d %v", c, out)
	}
}

func TestAddRemoveOrderAndIdempotent(t *testing.T) {
	r := newRig(t)
	until := r.now.Add(time.Hour).Unix()
	if c, out := r.add("app", "web", until); c != 200 {
		t.Fatalf("%d %v", c, out)
	}
	if len(r.dns.zone.Records) != 1 || r.dns.zone.Records[0].TTL != RecordTTL || r.edge.files["app.example.com"].Until != until {
		t.Fatalf("dns %v edge %v", r.dns.zone.Records, r.edge.files)
	}
	if !r.edge.files["app.example.com"].Websockets || r.edge.files["app.example.com"].MaxBody != "100m" {
		t.Fatalf("edge req %+v", r.edge.files["app.example.com"])
	}
	// Repeat: no second record.
	if c, _ := r.add("app", "web", until+60); c != 200 || len(r.dns.zone.Records) != 1 {
		t.Fatalf("repeat: %d %v", c, r.dns.zone.Records)
	}
	// Export owns the record.
	if e := r.s.export(); len(e.Owned) != 1 || e.Owned[0].Name != "app" {
		t.Fatalf("export %+v", e)
	}
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 200 {
		t.Fatal(c)
	}
	if len(r.dns.zone.Records) != 0 || len(r.edge.files) != 0 || len(r.s.rows) != 0 {
		t.Fatal("not cleaned")
	}
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 200 {
		t.Fatalf("second delete: %d", c)
	}
}

func TestCommitNeedsHostSide(t *testing.T) {
	r := newRig(t)
	req := Request{Service: "app", Route: "web", Host: "h001"}
	r.call("POST", "/api/overrides/prepare", "100.64.0.2", req)
	r.host = []HostOverride{}
	if c, _ := r.call("POST", "/api/overrides/commit", "100.64.0.2", req); c != 409 {
		t.Fatalf("commit without host public: %d", c)
	}
	r.hostEr = errors.New("down")
	if c, _ := r.call("POST", "/api/overrides/commit", "100.64.0.2", req); c != 502 {
		t.Fatalf("host down: %d", c)
	}
	if len(r.dns.log) != 0 {
		t.Fatal("dns touched")
	}
}

func TestCommitEdgeFailureRollsBackDNS(t *testing.T) {
	r := newRig(t)
	r.edge.fail = errors.New("o002 down")
	if c, _ := r.add("app", "web", 0); c != 502 {
		t.Fatal(c)
	}
	// o002 down for remove too: row kept Removing, DNS already dropped.
	if len(r.dns.zone.Records) != 0 || r.s.rows["app"] == nil || r.s.rows["app"].State != Removing {
		t.Fatalf("dns %v row %+v", r.dns.zone.Records, r.s.rows["app"])
	}
	r.edge.fail = nil
	r.s.Sweep(context.Background())
	if len(r.s.rows) != 0 {
		t.Fatalf("sweep left %+v", r.s.rows)
	}
}

// ssh error AFTER o002 applied the site: the row must survive (Removing,
// on disk) until the sweep has removed both the site and the record.
func TestCommitSSHErrorAfterApplyKeepsRow(t *testing.T) {
	r := newRig(t)
	r.edge.addThenFail = errors.New("ssh: connection reset")
	r.edge.removeFail = errors.New("ssh: connection reset")
	if c, _ := r.add("app", "web", 0); c != 502 {
		t.Fatal(c)
	}
	if _, ok := r.edge.files["app.example.com"]; !ok {
		t.Fatal("rig: site should be applied on o002")
	}
	if o := r.s.rows["app"]; o == nil || o.State != Removing {
		t.Fatalf("row %+v", o)
	}
	s2, err := New(r.s.cfg) // durable across a restart
	if err != nil || s2.rows["app"] == nil || s2.rows["app"].State != Removing {
		t.Fatalf("reloaded %v %+v", err, s2.rows)
	}
	r.edge.addThenFail, r.edge.removeFail = nil, nil
	r.s.Sweep(context.Background())
	if len(r.edge.files) != 0 || len(r.dns.zone.Records) != 0 || len(r.s.rows) != 0 {
		t.Fatalf("after sweep: edge %v dns %v rows %v", r.edge.files, r.dns.zone.Records, r.s.rows)
	}
}

// Renewal (record exists, created=false) whose push fails drops the owned
// record and only that one.
func TestRenewalFailureCleansRecord(t *testing.T) {
	r := newRig(t)
	if c, out := r.add("app", "web", 0); c != 200 {
		t.Fatal(c, out)
	}
	r.dns.zone.Records = append(r.dns.zone.Records, bunny.Record{ID: 9, Type: 2, Name: "other", Value: "o002.example.com"})
	r.edge.fail = errors.New("o002 down")
	if c, _ := r.add("app", "web", r.now.Add(time.Hour).Unix()); c != 502 {
		t.Fatal(c)
	}
	if len(r.dns.zone.Records) != 1 || r.dns.zone.Records[0].Name != "other" {
		t.Fatalf("dns %v", r.dns.zone.Records)
	}
	if r.s.rows["app"] == nil || r.s.rows["app"].State != Removing {
		t.Fatalf("row %+v", r.s.rows["app"])
	}
	r.edge.fail = nil
	r.s.Sweep(context.Background())
	if len(r.s.rows) != 0 || len(r.edge.files) != 0 {
		t.Fatalf("rows %v edge %v", r.s.rows, r.edge.files)
	}
}

// Same id but changed value: not ours any more, never deleted.
func TestRenewalFailureLeavesChangedRecord(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", 0)
	r.dns.zone.Records[0].Value = "elsewhere.example.net"
	r.edge.fail = errors.New("o002 down")
	r.add("app", "web", 0)
	if len(r.dns.zone.Records) != 1 {
		t.Fatalf("changed record deleted: %v", r.dns.zone.Records)
	}
}

func TestRevokeRemovingRow(t *testing.T) {
	r := newRig(t)
	r.edge.addThenFail = errors.New("ssh reset")
	r.edge.removeFail = errors.New("ssh reset")
	r.add("app", "web", 0)
	if r.s.rows["app"] == nil || r.s.rows["app"].State != Removing {
		t.Fatal("setup")
	}
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 502 || r.s.rows["app"] == nil {
		t.Fatalf("revoke while o002 down: %d", c)
	}
	r.edge.addThenFail, r.edge.removeFail = nil, nil
	if c, out := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 200 {
		t.Fatal(c, out)
	}
	if len(r.s.rows)+len(r.edge.files)+len(r.dns.zone.Records) != 0 {
		t.Fatalf("rows %v edge %v dns %v", r.s.rows, r.edge.files, r.dns.zone.Records)
	}
}

func TestDNSRefusesForeignRecord(t *testing.T) {
	r := newRig(t)
	r.dns.zone.Records = []bunny.Record{{ID: 5, Type: 0, Name: "app", Value: "1.2.3.4"}}
	if c, out := r.add("app", "web", 0); c != 502 || !strings.Contains(out["error"].(string), "doesn't own") {
		t.Fatal(c, out)
	}
	if len(r.edge.files) != 0 {
		t.Fatal("edge pushed")
	}
}

func TestSweepExpiryAndRetry(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", r.now.Add(time.Minute).Unix())
	r.now = r.now.Add(2 * time.Minute)
	r.edge.fail = errors.New("o002 down")
	r.s.Sweep(context.Background())
	// DNS still deleted; row kept Removing for retry.
	if len(r.dns.zone.Records) != 0 || r.s.rows["app"] == nil || r.s.rows["app"].State != Removing {
		t.Fatalf("after failed sweep: dns %v row %+v", r.dns.zone.Records, r.s.rows["app"])
	}
	r.edge.fail = nil
	r.s.Sweep(context.Background())
	if len(r.s.rows) != 0 || len(r.edge.files) != 0 {
		t.Fatal("retry didn't finish")
	}
}

func TestSweepForeverAndDrift(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", 0)
	r.now = r.now.Add(1000 * time.Hour)
	r.s.Sweep(context.Background())
	if r.s.rows["app"] == nil {
		t.Fatal("forever expired")
	}
	r.host = []HostOverride{} // host deployed/revoked
	r.s.Sweep(context.Background())
	if r.s.rows["app"] == nil {
		t.Fatal("drift removed before grace")
	}
	r.now = r.now.Add(DriftGrace + time.Second)
	r.s.Sweep(context.Background())
	if r.s.rows["app"] != nil || len(r.dns.zone.Records) != 0 {
		t.Fatal("drift not removed")
	}
}

func TestSweepStalePrepareAndRepush(t *testing.T) {
	r := newRig(t)
	r.call("POST", "/api/overrides/prepare", "100.64.0.2", Request{Service: "app", Route: "web", Host: "h001"})
	r.now = r.now.Add(PrepareTTL + time.Second)
	r.s.Sweep(context.Background())
	if len(r.s.rows) != 0 {
		t.Fatal("stale prepare kept")
	}
	r.add("app", "web", 0)
	delete(r.edge.files, "app.example.com") // o002 rebooted
	r.s.Sweep(context.Background())
	if _, ok := r.edge.files["app.example.com"]; !ok {
		t.Fatal("not re-pushed")
	}
}

func TestDeleteMismatchKeepsRecord(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", 0)
	r.dns.zone.Records[0].Value = "elsewhere.example.net"
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 409 {
		t.Fatal(c)
	}
	if len(r.dns.zone.Records) != 1 || r.s.rows["app"].DNS != "mismatch" || len(r.edge.files) != 0 {
		t.Fatal("mismatch handling")
	}
}

func TestUnconfigured503AndRateLimit(t *testing.T) {
	r := newRig(t)
	r.s.cfg.DNS = nil
	if c, _ := r.call("POST", "/api/overrides/prepare", "100.64.0.2", Request{Service: "app", Route: "web", Host: "h001"}); c != 503 {
		t.Fatal(c)
	}
	r2 := newRig(t)
	var last int
	for range RateMaxWrites + 1 {
		last, _ = r2.call("DELETE", "/api/overrides/none", "100.64.0.2", nil)
	}
	if last != 429 {
		t.Fatal(last)
	}
	if c, _ := r2.call("GET", "/api/overrides", "100.64.0.2", nil); c != 200 {
		t.Fatal("reads limited")
	}
}

func TestExportLoopbackOnly(t *testing.T) {
	r := newRig(t)
	req := httptest.NewRequest("GET", "/internal/overrides.json", nil)
	req.RemoteAddr = "127.0.0.1:1"
	req.Header.Set("X-Fleet-Peer", "100.64.0.2") // came through nginx
	w := httptest.NewRecorder()
	r.s.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatal(w.Code)
	}
}

func TestStatePersists(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", 0)
	s2, err := New(r.s.cfg)
	if err != nil || s2.rows["app"] == nil || s2.rows["app"].RecordID == 0 {
		t.Fatalf("%v %+v", err, s2.rows)
	}
}

func TestReleasedWhenDeclared(t *testing.T) {
	r := newRig(t)
	r.add("app", "web", 0)
	r.s.cfg.Spec.Records = append(r.s.cfg.Spec.Records, bunny.Desired{Name: "app", Type: "CNAME", Value: "o002.example.com"})
	r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil)
	if len(r.dns.zone.Records) != 1 {
		t.Fatal("declared record deleted")
	}
}

// o002 removed the file but its reload failed: the receiver errors, so
// h005 keeps the row Removing and the verify flags "reload pending".
func TestEdgeReloadPendingKeepsRemoving(t *testing.T) {
	r := newRig(t)
	if c, out := r.add("app", "web", 0); c != 200 {
		t.Fatal(c, out)
	}
	r.edge.removeFail = errors.New("fleet-vhost-receive: " + edgevhost.ErrReloadPending + ": nginx reload: boom")
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c != 502 {
		t.Fatal(c)
	}
	if o := r.s.rows["app"]; o == nil || o.State != Removing {
		t.Fatalf("row %+v", o)
	}
	r.edge.fail = r.edge.removeFail // list errors the same way
	v := r.s.verify(context.Background())
	if !v.EdgeReloadPending || v.Edge["app"] != edgevhost.ErrReloadPending {
		t.Fatalf("verify %+v", v)
	}
	r.edge.fail, r.edge.removeFail = nil, nil
	r.s.Sweep(context.Background())
	if len(r.s.rows) != 0 {
		t.Fatalf("sweep left %+v", r.s.rows)
	}
}

// DNS mismatch + o002 down: the sweep keeps retrying the edge removal
// (never touching the changed record) until o002 is back.
func TestSweepRetriesEdgeDespiteDNSMismatch(t *testing.T) {
	r := newRig(t)
	if c, out := r.add("app", "web", 0); c != 200 {
		t.Fatal(c, out)
	}
	r.dns.zone.Records[0].Value = "elsewhere.example.net"
	r.edge.removeFail = errors.New("o002 down")
	if c, _ := r.call("DELETE", "/api/overrides/app", "100.64.0.2", nil); c == 200 {
		t.Fatal("revoke succeeded with o002 down")
	}
	for i := 0; i < 3; i++ {
		r.s.Sweep(context.Background())
	}
	o := r.s.rows["app"]
	if o == nil || o.State != Removing || !o.Edge || o.DNS != "mismatch" {
		t.Fatalf("row %+v", o)
	}
	if _, ok := r.edge.files["app.example.com"]; !ok {
		t.Fatal("rig: site should still be on o002")
	}
	r.edge.removeFail = nil
	r.s.Sweep(context.Background())
	o = r.s.rows["app"]
	if len(r.edge.files) != 0 {
		t.Fatalf("edge not removed: %v", r.edge.files)
	}
	if o == nil || o.State != Removing || o.Edge || o.DNS != "mismatch" {
		t.Fatalf("row after recovery %+v", o)
	}
	if len(r.dns.zone.Records) != 1 || r.dns.zone.Records[0].Value != "elsewhere.example.net" {
		t.Fatalf("dns touched: %v", r.dns.zone.Records)
	}
	n := len(r.dns.log)
	r.s.Sweep(context.Background()) // edge gone: row parked for a human
	if len(r.dns.log) != n || r.s.rows["app"] == nil {
		t.Fatal("parked row changed")
	}
}
