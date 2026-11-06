package containers

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type errEdge struct{ err error }

func (e errEdge) do(string, string, any, any) error { return e.err }

const hexA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const hexB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func TestBackupCredsFreshCacheAnd403(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "creds")
	var log bytes.Buffer
	ok := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo/credentials": `{"subject":"forgejo","RESTIC_PASSWORD":"` + hexA + `","RESTIC_REST_USERNAME":"svc-forgejo","RESTIC_REST_PASSWORD":"` + hexB + `","restRevision":3}`}}
	p, src, err := backupCreds(func() (edgeDoer, error) { return ok, nil }, "forgejo", dir, &log)
	if err != nil || src != "api" {
		t.Fatal(src, err)
	}
	st, err := os.Stat(p)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("not 0600: %v %v", st, err)
	}
	if d, _ := os.Stat(dir); d.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v", d.Mode())
	}
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), "RESTIC_PASSWORD="+hexA+"\n") || !strings.Contains(string(b), "RESTIC_REST_USERNAME=svc-forgejo\n") {
		t.Fatalf("file:\n%s", b)
	}
	// API down: cache
	if p2, src, err := backupCreds(func() (edgeDoer, error) { return failEdge{}, nil }, "forgejo", dir, &log); err != nil || src != "cache" || p2 != p {
		t.Fatalf("cache: %s %v", src, err)
	}
	if _, _, err := backupCreds(func() (edgeDoer, error) { return nil, errNoToken }, "forgejo", dir, &log); err != nil {
		t.Fatalf("no token, cache: %v", err)
	}
	// 403: cache entry deleted, run fails, later runs fail even with API down
	no := errEdge{&edgeHTTPError{403, "not placed"}}
	if _, _, err := backupCreds(func() (edgeDoer, error) { return no, nil }, "forgejo", dir, &log); err == nil {
		t.Fatal("403 accepted")
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatal("cache survived a 403")
	}
	if _, _, err := backupCreds(func() (edgeDoer, error) { return failEdge{}, nil }, "forgejo", dir, &log); err == nil {
		t.Fatal("ran without cache")
	}
	// malformed answers rejected
	bad := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo/credentials": `{"RESTIC_PASSWORD":"x","RESTIC_REST_USERNAME":"svc-puzzles","RESTIC_REST_PASSWORD":"y"}`}}
	if _, _, err := backupCreds(func() (edgeDoer, error) { return bad, nil }, "forgejo", dir, &log); err == nil {
		t.Fatal("bad answer accepted")
	}
	if _, _, err := backupCreds(func() (edgeDoer, error) { return ok, nil }, "../x", dir, &log); err == nil {
		t.Fatal("bad subject")
	}
}

func TestHeartbeatSplitsCredentials(t *testing.T) {
	dir := t.TempDir()
	reply := `{"retention":{"forgejo":"standard"},"credentials":{"forgejo":{"username":"svc-forgejo","restPassword":"` + hexB + `","restRevision":2}}}`
	out, err := splitHeartbeatReply(json.RawMessage(reply), filepath.Join(dir, "rest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), hexB) || !strings.Contains(string(out), "retention") {
		t.Fatalf("policy keeps credentials: %s", out)
	}
	st, err := os.Stat(filepath.Join(dir, "rest.json"))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatal(st, err)
	}
	if _, err := splitHeartbeatReply(json.RawMessage(`{"credentials":{"forgejo":{"username":"svc-x","restPassword":"`+hexB+`"}}}`), filepath.Join(dir, "r2")); err == nil {
		t.Fatal("bad username accepted")
	}
}

func TestRepoKeysWritesHeldOnly(t *testing.T) {
	dir := t.TempDir()
	must(t, os.WriteFile(filepath.Join(dir, "svc-gone"), []byte("x"), 0o600))
	e := &fakeEdge{reply: map[string]string{"GET /api/backup/targets/h004/repo-keys": `{"repoKeys":{"forgejo":"` + hexA + `"}}`}}
	if err := backupRepoKeys(e, []string{"--id", "h004", "--dir", dir}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "svc-forgejo"))
	if err != nil || string(b) != "RESTIC_PASSWORD="+hexA+"\n" {
		t.Fatal(string(b), err)
	}
	if _, err := os.Stat(filepath.Join(dir, "svc-gone")); !os.IsNotExist(err) {
		t.Fatal("stale key kept")
	}
}
