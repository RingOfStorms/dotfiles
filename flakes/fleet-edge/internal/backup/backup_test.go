package backup

import (
	"bufio"
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
)

type stubVerifier struct{}

func (stubVerifier) VerifyZitadelToken(raw string) (auth.VerifiedToken, error) {
	sub, ok := strings.CutPrefix(raw, "good-")
	if !ok {
		return auth.VerifiedToken{}, errors.New("bad token")
	}
	return auth.VerifiedToken{Subject: sub}, nil
}

type fixture struct {
	s   *Service
	dir string
	now *time.Time
}

func newFixture(t *testing.T) *fixture {
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
	s, err := New(Config{
		StateDir: dir,
		Writers:  mk(map[string]authority.Writer{"lio": {Sub: "lio", Peer: "100.64.0.1"}}),
		Targets: mk(map[string]authority.Writer{
			"h004": {Sub: "h004", Peer: "100.64.0.17"},
			"h009": {Sub: "h009", Peer: "100.64.0.19"},
		}),
		Readers: mk(map[string]authority.Writer{
			"lio": {Sub: "lio", Peer: "100.64.0.1"},
			"joe": {Sub: "joe", Peer: "100.64.0.12"},
		}),
		Subjects: func() []string { return []string{"canary", "localai", "forgejo"} },
		Owns:     func(h, s string) bool { return h == "joe" && s == "localai" },
		Now:      nowf,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{s: s, dir: dir, now: &now}
}

func (f *fixture) do(t *testing.T, who, peer, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd *strings.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = strings.NewReader(string(b))
	} else {
		rd = strings.NewReader("")
	}
	r := httptest.NewRequest(method, path, rd)
	r.RemoteAddr = "127.0.0.1:5555"
	r.Header.Set("X-Fleet-Peer", peer)
	r.Header.Set("Authorization", "Bearer good-"+who)
	w := httptest.NewRecorder()
	f.s.Handler().ServeHTTP(w, r)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func i64(v int64) *int64 { return &v }

func (f *fixture) register(t *testing.T, id, peer string, pusher bool, stats map[string]Stats) {
	t.Helper()
	if code, out := f.do(t, id, peer, "POST", "/api/backup/targets/"+id,
		Heartbeat{URL: "rest:http://" + peer + ":8000/", Pusher: pusher, Stats: stats}); code != 200 {
		t.Fatalf("register %s: %d %v", id, code, out)
	}
}

func auditLines(t *testing.T, dir string) int {
	t.Helper()
	fh, err := os.Open(filepath.Join(dir, "backup-audit.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	n := 0
	for sc := bufio.NewScanner(fh); sc.Scan(); n++ {
	}
	return n
}

func TestForbidden(t *testing.T) {
	f := newFixture(t)
	// wrong-peer registration: h004 posting h009's record
	if code, _ := f.do(t, "h004", "100.64.0.17", "POST", "/api/backup/targets/h009", Heartbeat{URL: "rest:http://x/"}); code != 403 {
		t.Fatalf("cross registration: %d", code)
	}
	// a token from the wrong overlay IP never authenticates
	if code, _ := f.do(t, "h004", "100.64.0.1", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://x/"}); code != 401 {
		t.Fatalf("wrong peer: %d", code)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "PUT", "/api/backup/localai", PolicyRequest{}); code != 403 {
		t.Fatalf("reader PUT: %d", code)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/forgejo", nil); code != 403 {
		t.Fatalf("reader other subject: %d", code)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup", nil); code != 403 {
		t.Fatalf("reader full view: %d", code)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "POST", "/api/backup/localai/clear", ClearRequest{Scope: "local", Confirm: "clear svc-localai local"}); code != 403 {
		t.Fatalf("reader clear: %d", code)
	}
	if code, out := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/localai", nil); code != 200 || out["target"] != None {
		t.Fatalf("reader own subject: %d %v", code, out)
	}
	if _, ok := mustGet(t, f, "joe", "100.64.0.12", "/api/backup/localai")["offsite"]; ok {
		t.Fatal("reader view leaks offsite")
	}
	if code, _ := f.do(t, "nobody", "100.64.0.99", "GET", "/api/backup/localai", nil); code != 401 {
		t.Fatalf("unknown sub: %d", code)
	}
}

func mustGet(t *testing.T, f *fixture, who, peer, path string) map[string]any {
	t.Helper()
	code, out := f.do(t, who, peer, "GET", path, nil)
	if code != 200 {
		t.Fatalf("GET %s: %d %v", path, code, out)
	}
	return out
}

func str(s string) *string { return &s }
func boolp(b bool) *bool   { return &b }

func TestConflicts(t *testing.T) {
	f := newFixture(t)
	lio := func(method, path string, body any) (int, map[string]any) {
		return f.do(t, "lio", "100.64.0.1", method, path, body)
	}
	if code, _ := lio("PUT", "/api/backup/canary", PolicyRequest{Target: str("h004")}); code != 409 {
		t.Fatalf("unknown target: %d", code)
	}
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(100)}})
	f.register(t, "h009", "100.64.0.19", false, nil)
	if code, _ := lio("PUT", "/api/backup/canary", PolicyRequest{Target: str("h009"), Offsite: boolp(true)}); code != 409 {
		t.Fatalf("offsite on non-pusher: %d", code)
	}
	if code, _ := lio("PUT", "/api/backup/canary", PolicyRequest{Target: str("h004"), RetentionLocal: str("forever")}); code != 409 {
		t.Fatalf("unknown preset: %d", code)
	}
	code, out := lio("PUT", "/api/backup/canary", PolicyRequest{Target: str("h004"), Offsite: boolp(true), RetentionLocal: str("short")})
	if code != 200 {
		t.Fatalf("good put: %d %v", code, out)
	}
	if code, _ := lio("PUT", "/api/backup/canary", PolicyRequest{RetentionLocal: str("long")}); code != 409 {
		t.Fatalf("revision conflict: %d", code)
	}
	rev := int64(out["revision"].(float64))
	if code, _ := lio("PUT", "/api/backup/canary", PolicyRequest{RetentionLocal: str("long"), Revision: rev}); code != 200 {
		t.Fatalf("revision ok: %d", code)
	}
	// stale target
	*f.now = f.now.Add(2 * time.Hour)
	if code, _ := lio("PUT", "/api/backup/forgejo", PolicyRequest{Target: str("h004")}); code != 409 {
		t.Fatalf("stale target: %d", code)
	}
	// disabled target
	f.register(t, "h009", "100.64.0.19", false, nil)
	if code, _ := lio("PUT", "/api/backup/targets/h009", map[string]bool{"enabled": false}); code != 200 {
		t.Fatalf("disable: %d", code)
	}
	if code, _ := lio("PUT", "/api/backup/forgejo", PolicyRequest{Target: str("h009")}); code != 409 {
		t.Fatalf("disabled target: %d", code)
	}
	// clear b2 with no offsite repo
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(100)}})
	if code, _ := lio("POST", "/api/backup/canary/clear", ClearRequest{Scope: "b2", Confirm: "clear svc-canary b2"}); code != 409 {
		t.Fatalf("clear b2 without offsite repo: %d", code)
	}
	if code, _ := lio("POST", "/api/backup/forgejo/clear", ClearRequest{Scope: "local", Confirm: "clear svc-forgejo local"}); code != 409 {
		t.Fatalf("clear repo nobody holds: %d", code)
	}
}

func TestBadRequests(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(1), B2Bytes: i64(1)}})
	for _, req := range []ClearRequest{
		{Scope: "local", Confirm: "clear svc-canary b2"},
		{Scope: "local", Confirm: "yes"},
		{Scope: "everything", Confirm: "clear svc-canary everything"},
		{Scope: "", Confirm: ""},
	} {
		if code, _ := f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/canary/clear", req); code != 400 {
			t.Fatalf("%+v: %d", req, code)
		}
	}
}

func TestTurnOffAndClearFlow(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(5), B2Bytes: i64(5)}})
	code, out := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/canary", PolicyRequest{Target: str("h004"), Offsite: boolp(true)})
	if code != 200 {
		t.Fatal(code, out)
	}
	rev := int64(out["revision"].(float64))
	code, out = f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/canary", PolicyRequest{Target: str(None), Revision: rev})
	if code != 200 || out["target"] != None || out["offsite"] != true {
		t.Fatalf("turn off: %d %v", code, out)
	}
	code, out = f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/canary/clear", ClearRequest{Scope: "both", Confirm: "clear svc-canary both"})
	if code != 200 || out["offsite"] != false {
		t.Fatalf("clear: %d %v", code, out)
	}
	hb := func(cleared map[string][]string) HeartbeatReply {
		r := httptest.NewRequest("POST", "/api/backup/targets/h004", strings.NewReader(mustJSON(Heartbeat{URL: "rest:http://h/", Pusher: true, Cleared: cleared})))
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("X-Fleet-Peer", "100.64.0.17")
		r.Header.Set("Authorization", "Bearer good-h004")
		w := httptest.NewRecorder()
		f.s.Handler().ServeHTTP(w, r)
		var rep HeartbeatReply
		if err := json.Unmarshal(w.Body.Bytes(), &rep); err != nil || w.Code != 200 {
			t.Fatalf("hb: %d %s", w.Code, w.Body)
		}
		return rep
	}
	if rep := hb(nil); rep.Clears["canary"] != "local" || rep.Retention["canary"] != "standard" {
		t.Fatalf("pending local: %+v", rep)
	}
	if rep := hb(map[string][]string{"canary": {"local"}}); rep.Clears["canary"] != "b2" {
		t.Fatalf("pending b2: %+v", rep)
	}
	if rep := hb(map[string][]string{"canary": {"b2"}}); rep.Clears["canary"] != "" {
		t.Fatalf("done: %+v", rep)
	}
}

func TestPersistAndExport(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", true, nil)
	if code, _ := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/canary", PolicyRequest{Target: str("h004")}); code != 200 {
		t.Fatal(code)
	}
	for _, n := range []string{"backup.json", "backup-targets.json", "backup-audit.log"} {
		st, err := os.Stat(filepath.Join(f.dir, n))
		if err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", n, err, st)
		}
	}
	s2, err := New(Config{StateDir: f.dir, Writers: f.s.cfg.Writers, Targets: f.s.cfg.Targets, Readers: f.s.cfg.Readers, Now: f.s.cfg.Now})
	if err != nil {
		t.Fatal(err)
	}
	if r := s2.resolve("canary"); r.Repo != "rest:http://100.64.0.17:8000/svc-canary/" || r.Unavailable != "" {
		t.Fatalf("reloaded: %+v", r)
	}
	r := httptest.NewRequest("GET", "/internal/backup.json", nil)
	r.RemoteAddr = "100.64.0.1:1"
	w := httptest.NewRecorder()
	f.s.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("non-loopback export: %d", w.Code)
	}
}

func TestOneAuditLinePerRequest(t *testing.T) {
	f := newFixture(t)
	reqs := 0
	call := func(who, peer, m, p string, b any) {
		reqs++
		f.do(t, who, peer, m, p, b)
	}
	call("h004", "100.64.0.17", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://x/"})
	call("lio", "100.64.0.1", "PUT", "/api/backup/canary", PolicyRequest{Target: str("h004")})
	call("joe", "100.64.0.12", "GET", "/api/backup/forgejo", nil)
	call("nobody", "100.64.0.1", "GET", "/api/backup", nil)
	call("lio", "100.64.0.1", "POST", "/api/backup/canary/clear", ClearRequest{Scope: "x"})
	call("lio", "100.64.0.1", "GET", "/api/backup", nil)
	if n := auditLines(t, f.dir); n != reqs {
		t.Fatalf("audit lines %d, requests %d", n, reqs)
	}
}

// TestHeartbeatCoversEverySubject: the target's pruner looks up
// .retention[<subject>] for each repo it holds, so every known subject must be
// in the reply, including the ones that inherit the default row and the ones
// this target has not measured yet (a freshly seeded target has no stats).
func TestHeartbeatCoversEverySubject(t *testing.T) {
	f := newFixture(t)
	hb := func(h Heartbeat) HeartbeatReply {
		r := httptest.NewRequest("POST", "/api/backup/targets/h004", strings.NewReader(mustJSON(h)))
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("X-Fleet-Peer", "100.64.0.17")
		r.Header.Set("Authorization", "Bearer good-h004")
		w := httptest.NewRecorder()
		f.s.Handler().ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("hb: %d %s", w.Code, w.Body)
		}
		var rep HeartbeatReply
		if err := json.Unmarshal(w.Body.Bytes(), &rep); err != nil {
			t.Fatal(err)
		}
		return rep
	}
	// Before any row exists the built-in default row still answers for every
	// subject: a newly deployed target must be able to prune what it holds.
	if rep := hb(Heartbeat{URL: "rest:http://h/", Pusher: true}); rep.Retention["forgejo"] != "standard" {
		t.Fatalf("built-in default: %v", rep.Retention)
	}
	if code, out := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/default", PolicyRequest{Target: str("h004")}); code != 200 {
		t.Fatalf("default: %d %v", code, out)
	}
	// Every subject inherits the default row, stats or no stats.
	rep := hb(Heartbeat{URL: "rest:http://h/", Pusher: true})
	for _, n := range []string{"canary", "localai", "forgejo"} {
		if rep.Retention[n] != "standard" || rep.RetentionB2[n] != "standard" {
			t.Fatalf("%s: retention %v / b2 %v", n, rep.Retention, rep.RetentionB2)
		}
	}
	if _, ok := rep.Retention[Default]; ok {
		t.Fatalf("default row leaked into the reply: %v", rep.Retention)
	}
	// An explicit row wins over the default.
	if code, out := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/forgejo", PolicyRequest{Target: str("h004"), RetentionLocal: str("short")}); code != 200 {
		t.Fatalf("forgejo: %d %v", code, out)
	}
	rep = hb(Heartbeat{URL: "rest:http://h/", Pusher: true})
	if rep.Retention["forgejo"] != "short" || rep.Retention["canary"] != "standard" {
		t.Fatalf("mixed: %v", rep.Retention)
	}
}

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }
