package backup

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// place sets the fixture's live placement: subject -> {host, pending}.
func (f *fixture) place(m map[string][2]string) {
	f.s.cfg.Placement = func(s string) (string, string) { p := m[s]; return p[0], p[1] }
}

func TestCredentialFetchScoping(t *testing.T) {
	f := newFixture(t)
	f.place(map[string][2]string{"forgejo": {"lio", ""}, "canary": {"lio", "joe"}})
	code, out := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	if code != 200 || out["RESTIC_REST_USERNAME"] != "svc-forgejo" || len(out["RESTIC_PASSWORD"].(string)) != 64 {
		t.Fatalf("placed host: %d %v", code, out)
	}
	// pending move destination
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/canary/credentials", nil); code != 200 {
		t.Fatalf("pending destination: %d", code)
	}
	// other host (low trust joe, not placed)
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/forgejo/credentials", nil); code != 403 {
		t.Fatalf("other host: %d", code)
	}
	// a target is not a client
	if code, _ := f.do(t, "h004", "100.64.0.17", "GET", "/api/backup/forgejo/credentials", nil); code != 403 {
		t.Fatalf("target: %d", code)
	}
	// stable across fetches
	_, again := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	if again["RESTIC_PASSWORD"] != out["RESTIC_PASSWORD"] {
		t.Fatal("repo password changed between fetches")
	}
	b, _ := os.ReadFile(filepath.Join(f.dir, "backup-audit.log"))
	if !strings.Contains(string(b), "credentials fetched") || strings.Contains(string(b), out["RESTIC_PASSWORD"].(string)) {
		t.Fatal("fetch not audited, or a secret in the audit log")
	}
}

func heartbeatRaw(t *testing.T, f *fixture, id, peer string, hb Heartbeat) (int, string) {
	t.Helper()
	r := httptest.NewRequest("POST", "/api/backup/targets/"+id, strings.NewReader(mustJSON(hb)))
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("X-Fleet-Peer", peer)
	r.Header.Set("Authorization", "Bearer good-"+id)
	w := httptest.NewRecorder()
	f.s.Handler().ServeHTTP(w, r)
	return w.Code, w.Body.String()
}

func TestTargetFeedHasNoRepoPassword(t *testing.T) {
	f := newFixture(t)
	f.place(map[string][2]string{"forgejo": {"lio", ""}})
	_, cred := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	code, body := heartbeatRaw(t, f, "h004", "100.64.0.17", Heartbeat{URL: "rest:http://h/"})
	if code != 200 {
		t.Fatal(code, body)
	}
	if strings.Contains(body, cred["RESTIC_PASSWORD"].(string)) || strings.Contains(strings.ToLower(body), "resticpassword") {
		t.Fatalf("heartbeat leaks the repo password: %s", body)
	}
	var rep HeartbeatReply
	_ = json.Unmarshal([]byte(body), &rep)
	if rep.Credentials["forgejo"].RestPassword != cred["RESTIC_REST_PASSWORD"] || rep.Credentials["canary"].Username != "svc-canary" {
		t.Fatalf("feed: %+v", rep.Credentials)
	}
}

func TestRepoKeysScoping(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", false, map[string]Stats{"canary": {LocalBytes: i64(1)}})
	f.register(t, "h009", "100.64.0.19", false, nil)
	get := func(id, peer string) (int, map[string]any) {
		code, out := f.do(t, id, peer, "GET", "/api/backup/targets/"+id+"/repo-keys", nil)
		m, _ := out["repoKeys"].(map[string]any)
		return code, m
	}
	// default row target none: h004 holds only canary (stats), h009 nothing
	if code, k := get("h004", "100.64.0.17"); code != 200 || len(k) != 1 || k["canary"] == nil {
		t.Fatalf("h004 by stats: %d %v", code, k)
	}
	if _, k := get("h009", "100.64.0.19"); len(k) != 0 {
		t.Fatalf("non-holder got %v", k)
	}
	// default row -> h009: every subject without its own row inherits it
	rev := int64(0)
	if code, _ := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/default", PolicyRequest{Target: str("h009"), Revision: rev}); code != 200 {
		t.Fatal(code)
	}
	if code, _ := f.do(t, "lio", "100.64.0.1", "PUT", "/api/backup/forgejo", PolicyRequest{Target: str("h004")}); code != 200 {
		t.Fatal(code)
	}
	_, k := get("h009", "100.64.0.19")
	if k["canary"] == nil || k["localai"] == nil || k["forgejo"] != nil {
		t.Fatalf("h009 via default row: %v", k)
	}
	_, k4 := get("h004", "100.64.0.17")
	if k4["forgejo"] == nil || k4["localai"] != nil {
		t.Fatalf("h004: %v", k4)
	}
	// another target's keys, a client, a writer: 403
	if code, _ := f.do(t, "h004", "100.64.0.17", "GET", "/api/backup/targets/h009/repo-keys", nil); code != 403 {
		t.Fatalf("cross target: %d", code)
	}
	if code, _ := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/targets/h004/repo-keys", nil); code != 403 {
		t.Fatalf("writer: %d", code)
	}
	b, _ := os.ReadFile(filepath.Join(f.dir, "backup-audit.log"))
	if !strings.Contains(string(b), "repo keys: canary localai") {
		t.Fatalf("repo-keys not audited:\n%s", b)
	}
}

func TestRotateAndApplied(t *testing.T) {
	f := newFixture(t)
	f.place(map[string][2]string{"forgejo": {"lio", ""}})
	_, c1 := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	heartbeatRaw(t, f, "h004", "100.64.0.17", Heartbeat{URL: "rest:http://h/", Applied: map[string]int64{"forgejo": 1}})
	pending := func() []string {
		for _, c := range f.s.CredentialStatus().Subjects {
			if c.Subject == "forgejo" {
				return c.PendingOn
			}
		}
		t.Fatal("no forgejo")
		return nil
	}
	if p := pending(); len(p) != 0 {
		t.Fatalf("pending before rotate: %v", p)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "POST", "/api/backup/forgejo/rotate", nil); code != 403 {
		t.Fatalf("reader rotate: %d", code)
	}
	code, out := f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/forgejo/rotate", nil)
	if code != 200 || out["restRevision"].(float64) != 2 {
		t.Fatalf("rotate: %d %v", code, out)
	}
	if p := pending(); len(p) != 1 || p[0] != "h004" {
		t.Fatalf("pending after rotate: %v", p)
	}
	_, c2 := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	if c2["RESTIC_REST_PASSWORD"] == c1["RESTIC_REST_PASSWORD"] || c2["RESTIC_PASSWORD"] != c1["RESTIC_PASSWORD"] {
		t.Fatal("rotate must change the REST password only")
	}
	heartbeatRaw(t, f, "h004", "100.64.0.17", Heartbeat{URL: "rest:http://h/", Applied: map[string]int64{"forgejo": 2}})
	if p := pending(); len(p) != 0 {
		t.Fatalf("still pending after applied: %v", p)
	}
}

func TestMoveCommitRotatesAndRevokes(t *testing.T) {
	f := newFixture(t)
	pl := map[string][2]string{"localai": {"lio", ""}}
	f.place(pl)
	_, c1 := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/localai/credentials", nil)
	// in flight: both
	pl["localai"] = [2]string{"lio", "joe"}
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/localai/credentials", nil); code != 200 {
		t.Fatal("destination during move", code)
	}
	if code, _ := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/localai/credentials", nil); code != 200 {
		t.Fatal("source during move", code)
	}
	// commit: joe bound
	pl["localai"] = [2]string{"joe", ""}
	code, c2 := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/localai/credentials", nil)
	if code != 200 || c2["restRevision"].(float64) != 2 || c2["RESTIC_REST_PASSWORD"] == c1["RESTIC_REST_PASSWORD"] {
		t.Fatalf("commit did not rotate: %d %v", code, c2)
	}
	if code, _ := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/localai/credentials", nil); code != 403 {
		t.Fatalf("old host still fetches: %d", code)
	}
}

func TestCredentialsPersist(t *testing.T) {
	f := newFixture(t)
	f.place(map[string][2]string{"forgejo": {"lio", ""}})
	_, c1 := f.do(t, "lio", "100.64.0.1", "GET", "/api/backup/forgejo/credentials", nil)
	st, err := os.Stat(filepath.Join(f.dir, "backup-credentials.json"))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("credentials file: %v %v", st, err)
	}
	s2, err := New(Config{StateDir: f.dir, Writers: f.s.cfg.Writers, Targets: f.s.cfg.Targets, Readers: f.s.cfg.Readers,
		Subjects: f.s.cfg.Subjects, Now: f.s.cfg.Now, Placement: f.s.cfg.Placement})
	if err != nil {
		t.Fatal(err)
	}
	c, _ := s2.RevealAs("x", "forgejo")
	if c.ResticPassword != c1["RESTIC_PASSWORD"] || c.RestPassword != c1["RESTIC_REST_PASSWORD"] {
		t.Fatal("credentials changed across restart")
	}
}

func TestExportImportRoundTrip(t *testing.T) {
	f := newFixture(t)
	if !f.s.CredentialStatus().ExportStale {
		t.Fatal("never exported must warn")
	}
	text, err := f.s.ExportAs("ops")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(text, "# fleet-edge backup credentials export ") || strings.Count(text, "\nsvc-") != 3 {
		t.Fatalf("export:\n%s", text)
	}
	if f.s.CredentialStatus().ExportStale {
		t.Fatal("fresh export still warns")
	}
	orig, _ := f.s.RevealAs("ops", "forgejo")
	// h005 rebuilt: empty state dir
	g := newFixture(t)
	lines, err := g.s.ImportAs("ops", text, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range lines {
		if l.Action != "same" {
			t.Fatalf("after import %s: %s", l.Subject, l.Action)
		}
	}
	got, _ := g.s.RevealAs("ops", "forgejo")
	if got.ResticPassword != orig.ResticPassword || got.RestPassword != orig.RestPassword {
		t.Fatal("round trip lost values")
	}
	// differing value: not overwritten without the checkbox
	g.s.RotateAs("ops", "forgejo")
	rot, _ := g.s.RevealAs("ops", "forgejo")
	prev, _ := g.s.ImportPreview(text)
	for _, l := range prev {
		if l.Subject == "forgejo" && (l.Action != "differs" || l.Differs[0] != "RESTIC_REST_PASSWORD") {
			t.Fatalf("preview: %+v", l)
		}
	}
	g.s.ImportAs("ops", text, nil)
	if now, _ := g.s.RevealAs("ops", "forgejo"); now.RestPassword != rot.RestPassword {
		t.Fatal("overwrote without the checkbox")
	}
	g.s.ImportAs("ops", text, map[string]bool{"forgejo": true})
	if now, _ := g.s.RevealAs("ops", "forgejo"); now.RestPassword != orig.RestPassword || now.RestRevision != rot.RestRevision+1 {
		t.Fatalf("overwrite: %+v", now)
	}
	if _, err := g.s.ImportPreview("svc-x RESTIC_PASSWORD=zz RESTIC_REST_PASSWORD=00"); err == nil {
		t.Fatal("bad import accepted")
	}
	// a new repo password after the export warns again
	f.place(map[string][2]string{})
	f.s.mu.Lock()
	*f.now = f.now.Add(1e9 * 10)
	delete(f.s.creds.Creds, "canary")
	f.s.ensureCred("canary")
	f.s.mu.Unlock()
	if !f.s.CredentialStatus().ExportStale {
		t.Fatal("new repo password after export must warn")
	}
}
