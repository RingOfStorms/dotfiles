package containers

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeEdge struct {
	calls  []string
	bodies []map[string]any
	reply  map[string]string // "METHOD path" -> JSON
}

func (f *fakeEdge) do(method, path string, body, out any) error {
	f.calls = append(f.calls, method+" "+path)
	b, _ := json.Marshal(body)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	f.bodies = append(f.bodies, m)
	if r, ok := f.reply[method+" "+path]; ok && out != nil {
		return json.Unmarshal([]byte(r), out)
	}
	return nil
}

func TestBackupPolicySetSendsRevision(t *testing.T) {
	f := &fakeEdge{reply: map[string]string{
		"GET /api/backup/canary": `{"row":{"subject":"canary","revision":7}}`,
		"PUT /api/backup/canary": `{"subject":"canary","target":"h004","offsite":true,"retentionLocal":"short","retentionB2":"local","revision":8}`,
	}}
	var out bytes.Buffer
	if err := backupPolicySet(f, []string{"canary", "target=h004", "offsite=true", "local=short"}, &out); err != nil {
		t.Fatal(err)
	}
	put := f.bodies[1]
	if put["revision"].(float64) != 7 || put["target"] != "h004" || put["offsite"] != true || put["retentionLocal"] != "short" {
		t.Fatalf("body %v", put)
	}
	if !strings.Contains(out.String(), "revision 8") {
		t.Fatal(out.String())
	}
	if err := backupPolicySet(f, []string{"canary", "colour=red"}, &out); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestBackupPolicyClearNeedsTypedConfirm(t *testing.T) {
	f := &fakeEdge{reply: map[string]string{"POST /api/backup/canary/clear": `{"subject":"canary","clear":{"scope":"b2","target":"h004"}}`}}
	var out bytes.Buffer
	if err := backupPolicyClear(f, []string{"canary", "b2"}, strings.NewReader("yes\n"), &out); err == nil || len(f.calls) != 0 {
		t.Fatalf("wrong confirm: %v %v", err, f.calls)
	}
	if err := backupPolicyClear(f, []string{"canary", "b2"}, strings.NewReader("clear svc-canary b2\n"), &out); err != nil {
		t.Fatal(err)
	}
	if f.bodies[0]["confirm"] != "clear svc-canary b2" || f.bodies[0]["scope"] != "b2" {
		t.Fatalf("%v", f.bodies[0])
	}
}

func TestBackupPolicyList(t *testing.T) {
	f := &fakeEdge{reply: map[string]string{"GET /api/backup": `{"rows":[{"subject":"default","target":"none","retentionLocal":"standard","retentionB2":"local"},{"subject":"canary","target":"h004","retentionLocal":"short","retentionB2":"local","revision":3},{"subject":"done1","target":"h004","retentionLocal":"short","retentionB2":"local","clear":{"scope":"both","target":"h004","done":["local","b2"]}},{"subject":"half","target":"h004","retentionLocal":"short","retentionB2":"local","clear":{"scope":"both","target":"h004","done":["local"]}}],"targets":[{"id":"h004","url":"rest:http://x:8000/","enabled":true,"stats":{"canary":{"localBytes":2048}}}],"subjects":["canary","forgejo","done1","half"]}`}}
	var out bytes.Buffer
	if err := backupPolicyList(f, &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	for _, want := range []string{"canary", "2.0KiB", "none (default)", "target h004"} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in\n%s", want, s)
		}
	}
	// A finished clear is not pending; a half-done one still is.
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(line, "done1 ") && strings.Contains(line, "clear") {
			t.Fatalf("finished clear listed as pending: %q", line)
		}
		if strings.HasPrefix(line, "half ") && !strings.Contains(line, "clear both") {
			t.Fatalf("pending clear missing: %q", line)
		}
	}
}

// A repo a target reports that the inventory does not name is listed after
// it, marked, with its size and no policy filled in from the default row.
func TestBackupPolicyListUnlisted(t *testing.T) {
	f := &fakeEdge{reply: map[string]string{"GET /api/backup": `{"rows":[{"subject":"default","target":"h004","retentionLocal":"standard","retentionB2":"local"}],"targets":[{"id":"h004","url":"rest:http://x:8000/","enabled":true,"stats":{"canary":{"localBytes":3072},"forgejo":{"localBytes":1}}}],"subjects":["forgejo"]}`}}
	var out bytes.Buffer
	if err := backupPolicyList(f, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(out.String(), "\n")
	if !strings.HasPrefix(lines[2], "forgejo ") || !strings.Contains(lines[2], "h004 (default)") {
		t.Fatalf("forgejo:\n%s", out.String())
	}
	if got := strings.Join(strings.Fields(lines[3]), " "); got != "canary - (not in inventory) false - - 0 3.0KiB - unknown" {
		t.Fatalf("canary: %q", lines[3])
	}
}

func TestBackupHeartbeat(t *testing.T) {
	dir := t.TempDir()
	stats := filepath.Join(dir, "stats.json")
	must(t, os.WriteFile(stats, []byte(`{"canary":{"localBytes":5,"writtenBy":"low"}}`), 0o600))
	must(t, os.WriteFile(filepath.Join(dir, "cleared.json"), []byte(`{"canary":["local"]}`), 0o600))
	f := &fakeEdge{reply: map[string]string{"POST /api/backup/targets/h004": `{"retention":{"canary":"short"},"clears":{},"writtenBy":{"canary":"low"}}`}}
	out := filepath.Join(dir, "policy.json")
	if err := backupHeartbeat(f, []string{"--id", "h004", "--url", "rest:http://x:8000/", "--pusher", "--stats", stats, "--out", out}); err != nil {
		t.Fatal(err)
	}
	b := f.bodies[0]
	if b["pusher"] != true || b["stats"] == nil || b["cleared"] == nil {
		t.Fatalf("body %v", b)
	}
	if b["stats"].(map[string]any)["canary"].(map[string]any)["writtenBy"] != "low" {
		t.Fatalf("heartbeat stripped provenance: %v", b)
	}
	policy, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		WrittenBy map[string]string `json:"writtenBy"`
	}
	if err := json.Unmarshal(policy, &reply); err != nil || reply.WrittenBy["canary"] != "low" {
		t.Fatalf("reply provenance: %s, %v", policy, err)
	}
	st, err := os.Stat(out)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatal(err, st)
	}
	if _, err := os.Stat(filepath.Join(dir, "cleared.json")); !os.IsNotExist(err) {
		t.Fatal("cleared.json not consumed")
	}
	if got := sortedKeys(map[string]int{"b": 1, "a": 2}); got[0] != "a" {
		t.Fatal(got)
	}
}

func TestBackupPolicyListProvenance(t *testing.T) {
	f := &fakeEdge{reply: map[string]string{"GET /api/backup": `{"rows":[{"subject":"default","target":"none"}],"targets":[{"id":"h004","stats":{"forgejo":{"localBytes":1}}},{"id":"h009","stats":{"forgejo":{"writtenBy":"low"}}}],"subjects":["forgejo","canary"],"writtenBy":{"retired":"low"}}`}}
	var out bytes.Buffer
	if err := backupPolicyList(f, &out); err != nil {
		t.Fatal(err)
	}
	got := map[string][]string{}
	for _, line := range strings.Split(out.String(), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 {
			got[fields[0]] = fields
		}
	}
	if line := strings.Join(got["forgejo"], " "); !strings.HasSuffix(line, "low") || !strings.Contains(line, "1.0B") {
		t.Fatalf("nonselected holder's low history missing: %q", line)
	}
	if line := strings.Join(got["canary"], " "); !strings.HasSuffix(line, "unknown") {
		t.Fatalf("missing provenance must be unknown: %q", line)
	}
	if line := strings.Join(got["retired"], " "); !strings.Contains(line, "not in inventory") || !strings.HasSuffix(line, "low") {
		t.Fatalf("retired history missing: %q", line)
	}
}

func TestBackupHeartbeatProvenanceWithoutStats(t *testing.T) {
	dir := t.TempDir()
	provenance := filepath.Join(dir, "written-by.json")
	must(t, os.WriteFile(provenance, []byte(`{"retired":"low"}`), 0o600))
	f := &fakeEdge{reply: map[string]string{"POST /api/backup/targets/h004": `{}`}}
	if err := backupHeartbeat(f, []string{"--id", "h004", "--url", "rest:http://x/", "--provenance", provenance, "--out", filepath.Join(dir, "policy.json")}); err != nil {
		t.Fatal(err)
	}
	if len(f.bodies) != 1 || f.bodies[0]["stats"] != nil || f.bodies[0]["writtenBy"].(map[string]any)["retired"] != "low" {
		t.Fatalf("history invented held repository or was stripped: %v", f.bodies)
	}
}
