package containers

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type failEdge struct{}

func (failEdge) do(string, string, any, any) error { return errors.New("connection refused") }

func TestResolveBackupCachesAndFallsBack(t *testing.T) {
	cache := filepath.Join(t.TempDir(), "fb", "target.json")
	var log bytes.Buffer
	ok := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo": `{"subject":"forgejo","target":"h004","url":"rest:http://100.64.0.4:8000/","repo":"rest:http://100.64.0.4:8000/svc-forgejo/","revision":2}`}}
	r, src, err := resolveBackup(func() (edgeDoer, error) { return ok, nil }, "forgejo", cache, &log)
	if err != nil || src != "api" || r.Repo != "rest:http://100.64.0.4:8000/svc-forgejo/" {
		t.Fatalf("api: %+v %s %v", r, src, err)
	}
	if st, err := os.Stat(cache); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("cache not written 0600: %v %v", st, err)
	}
	// API down: the cached answer
	r, src, err = resolveBackup(func() (edgeDoer, error) { return failEdge{}, nil }, "forgejo", cache, &log)
	if err != nil || src != "cache" || r.Target != "h004" {
		t.Fatalf("cache: %+v %s %v", r, src, err)
	}
	// stale target: cache too
	stale := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo": `{"subject":"forgejo","target":"h009","unavailable":"target stale"}`}}
	if _, src, err = resolveBackup(func() (edgeDoer, error) { return stale, nil }, "forgejo", cache, &log); err != nil || src != "cache" {
		t.Fatalf("stale: %s %v", src, err)
	}
	// no cache entry: refuse
	if _, _, err = resolveBackup(func() (edgeDoer, error) { return failEdge{}, nil }, "puzzles", cache, &log); err == nil || !strings.Contains(err.Error(), "refusing to guess") {
		t.Fatalf("no cache: %v", err)
	}
	// cache deleted: refuse
	os.Remove(cache)
	if _, _, err = resolveBackup(func() (edgeDoer, error) { return nil, errNoToken }, "forgejo", cache, &log); err == nil {
		t.Fatal("ran without a cache")
	}
}

func TestResolveBackupRejectsBadAnswers(t *testing.T) {
	cache := filepath.Join(t.TempDir(), "t.json")
	for _, body := range []string{
		`{"target":"h004","repo":"http://x:8000/svc-forgejo/"}`,          // bare http parses as a local path
		`{"target":"h004","repo":"rest:http://u:p@x:8000/svc-forgejo/"}`, // userinfo
		`{"target":"h004","repo":"rest:http://x:8000/svc-puzzles/"}`,     // another subject
		`{"target":"","repo":""}`,
	} {
		f := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo": body}}
		if _, _, err := resolveBackup(func() (edgeDoer, error) { return f, nil }, "forgejo", cache, &bytes.Buffer{}); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
	none := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo": `{"subject":"forgejo","target":"none"}`}}
	if r, _, err := resolveBackup(func() (edgeDoer, error) { return none, nil }, "forgejo", cache, &bytes.Buffer{}); err != nil || r.Target != "none" {
		t.Fatalf("none: %+v %v", r, err)
	}
	// writers get {row, resolved}
	w := &fakeEdge{reply: map[string]string{"GET /api/backup/forgejo": `{"row":{"subject":"forgejo"},"resolved":{"target":"h004","repo":"rest:http://x:8000/svc-forgejo/"}}`}}
	if r, _, err := resolveBackup(func() (edgeDoer, error) { return w, nil }, "forgejo", cache, &bytes.Buffer{}); err != nil || r.Target != "h004" {
		t.Fatalf("writer shape: %+v %v", r, err)
	}
	if _, _, err := resolveBackup(func() (edgeDoer, error) { return w, nil }, "../x", cache, &bytes.Buffer{}); err == nil {
		t.Fatal("bad subject name accepted")
	}
}

func TestParseStampRepo(t *testing.T) {
	b, err := parseStamp("time=2026-11-05T03:00:00Z snapshot=ab12 host=h001 target=h004 repo=rest:http://100.64.0.4:8000/svc-forgejo/")
	if err != nil || b.Repo != "rest:http://100.64.0.4:8000/svc-forgejo/" || b.Target != "h004" {
		t.Fatalf("%+v %v", b, err)
	}
	if _, err := parseStamp("time=2026-11-05T03:00:00Z snapshot=ab12 repo=rest:http://u:p@x/svc-forgejo/"); err == nil {
		t.Fatal("userinfo repo in a stamp accepted")
	}
	// old stamps (no repo) still parse
	if b, err := parseStamp("time=2026-11-05T03:00:00Z snapshot=ab12 host=h001"); err != nil || b.Repo != "" {
		t.Fatalf("old stamp: %v", err)
	}
}

func TestRestoreUsesStampedRepo(t *testing.T) {
	oldInv := inv
	t.Cleanup(func() { inv = oldInv })
	inv = &Inventory{DataRoot: "/srv/containers"}
	s := Service{Name: "forgejo", Kind: "nixos"}
	st := backupStamp{Snapshot: "ab12", Repo: "rest:http://100.64.0.4:8000/svc-forgejo/"}
	for name, sc := range map[string]string{
		"restore-check": restoreCheckScript(s, st.Repo, st.Snapshot),
	} {
		if !strings.Contains(sc, "fleet-restic --subject 'forgejo' -r 'rest:http://100.64.0.4:8000/svc-forgejo/' restore ab12") {
			t.Errorf("%s does not restore the stamped repo:\n%s", name, sc)
		}
	}
}

func TestExtraPathScripts(t *testing.T) {
	s := Service{Name: "immich", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{
		{Path: "/drives/wd10/immich", Exclude: []string{"thumbs", "nested/cache"}},
		{Path: "/var/lib/immich-extra"},
	}}}
	pf := extraPathsPreflightScript(s, "h003")
	for _, want := range []string{".cnt-sync-immich", "exists and is not empty", "findmnt", "nfs*|cifs|smb3|fuse.sshfs|autofs|9p"} {
		if !strings.Contains(pf, want) {
			t.Fatalf("preflight lacks %q:\n%s", want, pf)
		}
	}
	r := backupExtraSyncScript(s, "rest:http://x/svc-immich/", "ab", s.Backup.ExtraPaths, "", false)
	for _, want := range []string{"-r 'rest:http://x/svc-immich/'", "restore 'ab:/drives/wd10/immich'", "--target '/drives/wd10/immich'", "--overwrite if-changed --delete --exclude '/.cnt-sync-immich' --exclude '/thumbs' --exclude '/nested/cache'", "--include '/immich' --include '!/immich/*'", "restore 'ab:/var/lib/immich-extra'"} {
		if !strings.Contains(r, want) {
			t.Fatalf("sync lacks %q:\n%s", want, r)
		}
	}
	into := extraRestoreScript(s, "", "latest", []string{"/drives/wd10/immich"}, "/tmp/x")
	if strings.Contains(into, "is not empty") || !strings.Contains(into, "--target '/tmp/x/drives/wd10/immich'") || !strings.Contains(into, "restore 'latest:/drives/wd10/immich' --tag 'svc:immich'") {
		t.Fatalf("--into:\n%s", into)
	}
	if backupExtraSyncScript(Service{Name: "a"}, "", "", nil, "", false) != "" {
		t.Fatal("no extra paths should add nothing")
	}
}

func TestMoveRefusesTargetWithoutGrant(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.WriteFile(m.dstState()+"/no-grant", nil, 0o644))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "preflight") {
		t.Fatalf("expected a preflight refusal, got %v", err)
	}
	if strings.Contains(m.calls(), "\nsystemctl stop") {
		t.Fatal("source was stopped")
	}
	m.assertSourceIntact(t)
}

func TestMoveRefusesBackupsOff(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.WriteFile(m.srcState()+"/target-none", nil, 0o644))
	if err := runMove(t); err == nil {
		t.Fatal("moved a subject with target=none")
	}
	m.assertSourceIntact(t)
}

func TestMoveRestoresFromStampedRepo(t *testing.T) {
	m := newMoveRig(t)
	if err := runMove(t); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(m.calls(), "fleet-restic --subject svc -r rest:http://100.64.0.4:8000/svc-svc/ restore ") {
		t.Fatalf("restore did not use the stamped repo:\n%s", m.calls())
	}
}
