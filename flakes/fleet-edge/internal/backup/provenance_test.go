package backup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func lowTrustHost(host string) string {
	if host == "joe" {
		return "low"
	}
	return "high"
}

func assertWrittenBy(t *testing.T, s *Service, subject, want string) {
	t.Helper()
	e := s.Snapshot()
	if e.WrittenBy[subject] != want {
		t.Fatalf("%s provenance = %q, want %q", subject, e.WrittenBy[subject], want)
	}
	for _, target := range e.Targets {
		if st, ok := target.Stats[subject]; ok && st.WrittenBy != want {
			t.Fatalf("%s/%s provenance = %q, want %q", target.ID, subject, st.WrittenBy, want)
		}
	}
}

func TestProvenancePendingMovePersistsAcrossRollbackAndRestart(t *testing.T) {
	f := newFixture(t)
	f.s.cfg.HostTrust = lowTrustHost
	pl := map[string][2]string{"forgejo": {"lio", ""}, "localai": {"lio", "joe"}}
	f.place(pl)
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"localai": {LocalBytes: i64(4)}})
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/localai/credentials", nil); code != 200 {
		t.Fatalf("pending credential fetch: %d", code)
	}
	pl["localai"] = [2]string{"lio", ""} // aborted move; low host already had access
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{})
	f.register(t, "h009", "100.64.0.19", false, map[string]Stats{"localai": {LocalBytes: i64(8)}})
	assertWrittenBy(t, f.s, "localai", WrittenByLow)
	assertWrittenBy(t, f.s, "forgejo", "")
	f.s.cfg.HostTrust = func(string) string { return "high" } // inventory promotion cannot erase evidence
	s2, err := New(f.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	assertWrittenBy(t, s2, "localai", WrittenByLow)
	st := s2.Snapshot().Targets[1].Stats["localai"]
	if st.LocalBytes == nil || *st.LocalBytes != 8 {
		t.Fatalf("new holder's real stats lost: %+v", st)
	}
}

func TestProvenanceClaimsOnlyDowngradeAndRequireTargetIdentity(t *testing.T) {
	f := newFixture(t)
	f.s.cfg.HostTrust = lowTrustHost
	f.place(map[string][2]string{"forgejo": {"lio", ""}})
	if code, _ := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/forgejo/credentials", nil); code != 403 {
		t.Fatalf("arbitrary credential fetch: %d", code)
	}
	if code, _ := f.do(t, "joe", "100.64.0.12", "POST", "/api/backup/targets/joe", Heartbeat{URL: "rest:http://joe/", Stats: map[string]Stats{"forgejo": {WrittenBy: WrittenByLow}}}); code != 403 {
		t.Fatalf("reader submitted target stats: %d", code)
	}
	assertWrittenBy(t, f.s, "forgejo", "")
	for _, value := range []string{"high", "trusted", "LOW"} {
		if code, _ := f.do(t, "h004", "100.64.0.17", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://h/", Stats: map[string]Stats{"forgejo": {WrittenBy: value}}}); code != 400 {
			t.Fatalf("trust assertion %q accepted: %d", value, code)
		}
	}
	f.register(t, "h004", "100.64.0.17", false, map[string]Stats{"forgejo": {WrittenBy: WrittenByLow}})
	f.register(t, "h004", "100.64.0.17", false, map[string]Stats{"forgejo": {LocalBytes: i64(1)}})
	f.register(t, "h009", "100.64.0.19", false, map[string]Stats{"forgejo": {B2Bytes: i64(2)}})
	assertWrittenBy(t, f.s, "forgejo", WrittenByLow)
	code, body := heartbeatRaw(t, f, "h009", "100.64.0.19", Heartbeat{URL: "rest:http://h/"})
	var reply HeartbeatReply
	if code != 200 || json.Unmarshal([]byte(body), &reply) != nil || reply.WrittenBy["forgejo"] != WrittenByLow {
		t.Fatalf("target policy omitted durable history: %d %s", code, body)
	}
}

func TestProvenanceMigratesBoundAndAuthenticatedAuditHistory(t *testing.T) {
	f := newFixture(t)
	f.s.cfg.HostTrust = lowTrustHost
	f.place(map[string][2]string{"localai": {"lio", ""}})
	c, err := f.s.ensureCred("localai")
	if err != nil {
		t.Fatal(err)
	}
	c.BoundHost = "joe" // pre-provenance authority's last observed owner
	if err := f.s.saveCreds(); err != nil {
		t.Fatal(err)
	}
	entries := []auditEntry{
		{Host: "joe", Sub: "joe", Role: roleReader, Code: 200, Action: "GET /api/backup/retired/credentials"},
		{Host: "joe", Sub: "joe", Role: roleReader, Code: 403, Action: "GET /api/backup/denied/credentials"},
		{Host: "joe", Sub: "joe", Role: roleReader, Code: 200, Action: "GET /api/backup/canary"},
		{Host: "lio", Sub: "lio", Role: roleWriter, Code: 200, Action: "PUT /api/backup/forgejo", Message: "placement joe -> lio; restRevision 2"},
		{Host: "fleet-edge", Code: 200, Action: "rotate moved", Message: "placement joe -> lio; restRevision 2"},
	}
	for _, e := range entries {
		f.s.logAudit(e)
	}
	s2, err := New(f.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, subject := range []string{"localai", "retired", "moved"} {
		assertWrittenBy(t, s2, subject, WrittenByLow)
	}
	for _, subject := range []string{"denied", "canary", "forgejo"} {
		assertWrittenBy(t, s2, subject, "")
	}
}

func TestProvenanceUnobservedPlacementHistoryAndClear(t *testing.T) {
	f := newFixture(t)
	f.s.cfg.HostTrust = lowTrustHost
	f.place(map[string][2]string{"localai": {"lio", ""}})
	f.s.cfg.LowTrustSubjects = func() map[string]bool { return map[string]bool{"localai": true, "retired": true} }
	f.register(t, "h004", "100.64.0.17", false, map[string]Stats{"localai": {LocalBytes: i64(1)}})
	if code, _ := f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/localai/clear", ClearRequest{Scope: "local", Confirm: "clear svc-localai local"}); code != 200 {
		t.Fatalf("clear: %d", code)
	}
	if code, _ := f.do(t, "h004", "100.64.0.17", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://h/", Stats: map[string]Stats{}, Cleared: map[string][]string{"localai": {"local"}}}); code != 200 {
		t.Fatalf("clear completion: %d", code)
	}
	assertWrittenBy(t, f.s, "localai", WrittenByLow)
	assertWrittenBy(t, f.s, "retired", WrittenByLow)
	if len(f.s.Snapshot().Targets[0].Stats) != 0 {
		t.Fatal("history must not fabricate held repos or sizes after clear")
	}
}

func TestProvenanceSaveFailureBlocksCredentialRelease(t *testing.T) {
	f := newFixture(t)
	f.place(map[string][2]string{"localai": {"joe", ""}})
	if _, err := f.s.ensureCred("localai"); err != nil {
		t.Fatal(err)
	}
	f.s.cfg.HostTrust = lowTrustHost
	path := filepath.Join(f.dir, "backup-credentials.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	code, out := f.do(t, "joe", "100.64.0.12", "GET", "/api/backup/localai/credentials", nil)
	if code != 500 || out["RESTIC_PASSWORD"] != nil || f.s.creds.WrittenBy["localai"] != "" {
		t.Fatalf("unrecorded low grant: %d %v, history %v", code, out, f.s.creds.WrittenBy)
	}
}

func TestProvenanceSnapshotOwnsMutableData(t *testing.T) {
	f := newFixture(t)
	complete := true
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(4), B2Bytes: i64(8), Complete: &complete, WrittenBy: WrittenByLow}})
	if code, _ := f.do(t, "h004", "100.64.0.17", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://h/", Pusher: true, Applied: map[string]int64{"canary": 1}}); code != 200 {
		t.Fatal(code)
	}
	if code, _ := f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/canary/clear", ClearRequest{Scope: "both", Confirm: "clear svc-canary both"}); code != 200 {
		t.Fatal(code)
	}
	if code, _ := f.do(t, "h004", "100.64.0.17", "POST", "/api/backup/targets/h004", Heartbeat{URL: "rest:http://h/", Cleared: map[string][]string{"canary": {"local"}}}); code != 200 {
		t.Fatal(code)
	}
	snapshot := f.s.Snapshot()
	var row *Row
	for _, candidate := range snapshot.Rows {
		if candidate.Subject == "canary" {
			row = candidate
		}
	}
	if row == nil || row.Clear == nil || len(row.Clear.Done) != 1 {
		t.Fatalf("missing clear fixture: %+v", row)
	}
	if err := f.s.markLow("retired"); err != nil {
		t.Fatal(err)
	}
	if snapshot.WrittenBy["retired"] != "" {
		t.Fatal("later authority provenance changed published snapshot")
	}
	// Dashboard callers own their copy, including pointer values and clear
	// slices; mutating it must not alter the next heartbeat/export's state.
	snapshot.WrittenBy["canary"] = ""
	st := snapshot.Targets[0].Stats["canary"]
	*st.LocalBytes, *st.B2Bytes, *st.Complete = 40, 80, false
	delete(snapshot.Targets[0].Stats, "canary")
	snapshot.Targets[0].Applied["canary"] = 99
	row.Target = "mutated"
	row.Clear.Done[0] = "mutated"
	fresh := f.s.Snapshot()
	actual := fresh.Targets[0].Stats["canary"]
	if fresh.WrittenBy["canary"] != WrittenByLow || actual.LocalBytes == nil || *actual.LocalBytes != 4 || actual.B2Bytes == nil || *actual.B2Bytes != 8 || actual.Complete == nil || !*actual.Complete || fresh.Targets[0].Applied["canary"] != 1 {
		t.Fatalf("snapshot mutated authority: %+v %+v", fresh, actual)
	}
	for _, candidate := range fresh.Rows {
		if candidate.Subject == "canary" && (candidate.Target == "mutated" || candidate.Clear.Done[0] != "local") {
			t.Fatalf("snapshot mutated authority row: %+v", candidate)
		}
	}
}

func TestProvenanceConcurrentSnapshotSerialization(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", true, map[string]Stats{"canary": {LocalBytes: i64(4), WrittenBy: WrittenByLow}})
	start := make(chan struct{})
	errors := make(chan error, 4)
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for range 100 {
				snapshot := f.s.Snapshot()
				if _, err := json.Marshal(snapshot); err != nil {
					errors <- err
					return
				}
			}
		}()
	}
	close(start)
	wg.Wait()
	close(errors)
	for err := range errors {
		t.Fatal(err)
	}
}

func TestProvenanceMigratesTrailingSlashCredentialGrant(t *testing.T) {
	f := newFixture(t)
	f.s.cfg.HostTrust = lowTrustHost
	f.place(map[string][2]string{"localai": {"lio", ""}})
	if _, err := f.s.ensureCred("localai"); err != nil {
		t.Fatal(err)
	}
	// The pre-feature API accepted this during a pending move, which later
	// rolled back without changing BoundHost or recording a committed rotation.
	f.s.logAudit(auditEntry{Host: "joe", Sub: "joe", Role: roleReader, Code: 200, Action: "GET /api/backup//localai/credentials//"})
	f.s.logAudit(auditEntry{Host: "joe", Sub: "joe", Role: roleReader, Code: 403, Action: "GET /api/backup/forgejo/credentials/"})
	s2, err := New(f.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	assertWrittenBy(t, s2, "localai", WrittenByLow)
	assertWrittenBy(t, s2, "forgejo", "")
}

func TestProvenanceHistoryDoesNotClaimRepository(t *testing.T) {
	f := newFixture(t)
	f.register(t, "h004", "100.64.0.17", false, map[string]Stats{"canary": {LocalBytes: i64(4)}})
	code, _ := f.do(t, "h009", "100.64.0.19", "POST", "/api/backup/targets/h009", Heartbeat{
		URL: "rest:http://h009/", Stats: map[string]Stats{}, WrittenBy: map[string]string{"canary": WrittenByLow, "retired": WrittenByLow},
	})
	if code != 200 {
		t.Fatal(code)
	}
	assertWrittenBy(t, f.s, "canary", WrittenByLow)
	assertWrittenBy(t, f.s, "retired", WrittenByLow)
	if len(f.s.targets["h009"].Stats) != 0 || f.s.holds("h009", "canary") || f.s.holds("h009", "retired") {
		t.Fatal("provenance-only target falsely holds repository")
	}
	code, keys := f.do(t, "h009", "100.64.0.19", "GET", "/api/backup/targets/h009/repo-keys", nil)
	if code != 200 || len(keys["repoKeys"].(map[string]any)) != 0 {
		t.Fatalf("history granted unrelated repo keys: %d %v", code, keys)
	}
	code, out := f.do(t, "lio", "100.64.0.1", "POST", "/api/backup/canary/clear", ClearRequest{Scope: "local", Confirm: "clear svc-canary local"})
	if code != 200 || out["clear"].(map[string]any)["target"] != "h004" {
		t.Fatalf("history masked actual clear holder: %d %v", code, out)
	}
	for _, writtenBy := range []map[string]string{{"canary": "high"}, {"canary": ""}, {"bad/name": WrittenByLow}} {
		if code, _ := f.do(t, "h009", "100.64.0.19", "POST", "/api/backup/targets/h009", Heartbeat{URL: "rest:http://h009/", WrittenBy: writtenBy}); code != 400 {
			t.Fatalf("invalid history accepted: %d %v", code, writtenBy)
		}
	}
}
