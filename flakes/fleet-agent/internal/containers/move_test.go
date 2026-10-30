package containers

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Move tests run cmdMove end to end over the fake ssh of newRig, with fakes
// for systemctl (unit state in files, fleet-backup-svc@ snapshots into a
// fake repo), fleet-restic (restore from that repo), nix (build prints a
// fake out with bin/fleet-install) and sqlite3 (integrity_check says "ok"
// unless the file contains CORRUPT).

type moveRig struct {
	*rig
	repo string
}

func newMoveRig(t *testing.T) *moveRig {
	t.Helper()
	r := newRig(t)
	for _, tool := range []string{"gzip", "flock", "cp", "mktemp"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not available", tool)
		}
	}
	m := &moveRig{rig: r, repo: filepath.Join(filepath.Dir(r.root), "repo")}
	must(t, os.MkdirAll(m.repo, 0o755))
	// No registry client unless a test wires one (moveOnRegistry), and the
	// move-state file in a scratch dir, whatever the machine running the tests.
	t.Setenv("SEC_MACHINE_KEY", filepath.Join(t.TempDir(), "absent-machine-key.json"))
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	bash := realPath(t, "bash")
	// src: running, with a sqlite db, a pg dump, a live pg cluster.
	must(t, os.WriteFile(filepath.Join(r.root, "svc/data/app.db"), []byte("SQLite format 3\x00LIVE"), 0o644))
	must(t, os.MkdirAll(filepath.Join(r.root, "svc/pgdumps"), 0o755))
	gz := exec.Command(bash, "-c", "printf -- '--\\n-- PostgreSQL database cluster dump\\n--\\nSELECT 1;\\n--\\n-- PostgreSQL database cluster dump complete\\n--\\n' | gzip > "+filepath.Join(r.root, "svc/pgdumps/all.sql.gz"))
	must(t, gz.Run())
	must(t, os.MkdirAll(filepath.Join(r.root, "svc/postgres/base"), 0o700))
	must(t, os.WriteFile(filepath.Join(r.root, "svc/postgres/base/1"), []byte("pgdata"), 0o600))
	for _, st := range []string{r.root + ".state", r.dst + ".state"} {
		must(t, os.MkdirAll(st+"/efc/capabilities", 0o755))
		must(t, os.MkdirAll(st+"/vlfc", 0o755))
		must(t, os.WriteFile(st+"/efc/backup", nil, 0o644))
	}
	must(t, os.WriteFile(r.root+".state/active-fleet-svc.service", nil, 0o644))
	must(t, os.WriteFile(r.root+".state/installed-fleet-svc.service", nil, 0o644))

	writeExe(t, filepath.Join(r.bin, "systemctl"), "#!"+bash+`
echo "systemctl $*" >> `+r.log+`
[ "${1:-}" = -q ] && shift
case "$1" in
is-active)
  shift; [ "$1" = -q ] && { q=1; shift; }
  if [ -e "$FAKE_STATE/active-$1" ]; then [ -n "${q:-}" ] || echo active; exit 0; fi
  [ -n "${q:-}" ] || echo inactive; exit 3 ;;
show)
  u=${!#}; if [ -e "$FAKE_STATE/installed-$u" ]; then echo loaded; else echo not-found; fi ;;
stop)
  [ -e "$FAKE_STATE/installed-$2" ] || { echo "Failed to stop $2: Unit $2 not loaded." >&2; exit 5; }
  rm -f "$FAKE_STATE/active-$2" ;;
start)
  case "$2" in
  fleet-backup-svc@*)
    svc=${2#fleet-backup-svc@}; svc=${svc%.service}
    [ -e "$FAKE_STATE/skip-backup" ] && exit 0   # ConditionPathExists false
    id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    mkdir -p "$FAKE_REPO/$id/data" "$FAKE_REPO/$id/staging/$svc/sqlite/$svc/data"
    cp -a "$FAKE_ROOT/$svc" "$FAKE_REPO/$id/data/"
    rm -rf "$FAKE_REPO/$id/data/$svc/postgres" "$FAKE_REPO/$id/data/$svc/data/app.db"
    sed 's/LIVE/COPY/' "$FAKE_ROOT/$svc/data/app.db" > "$FAKE_REPO/$id/staging/$svc/sqlite/$svc/data/app.db"
    echo "$FAKE_HOST" > "$FAKE_REPO/$id/host"; touch -d "@$(( $(date +%s) + $(ls "$FAKE_REPO" | wc -l) ))" "$FAKE_REPO/$id"
    mkdir -p "$FAKE_STATE/vlfc/backup-last"
    echo "time=$(date -u +%Y-%m-%dT%H:%M:%SZ) snapshot=$id host=$FAKE_HOST" > "$FAKE_STATE/vlfc/backup-last/$svc" ;;
  *) [ -e "$FAKE_STATE/installed-$2" ] || { echo "Unit $2 not found." >&2; exit 5; }; touch "$FAKE_STATE/active-$2" ;;
  esac ;;
esac
exit 0
`)
	writeExe(t, filepath.Join(r.bin, "fleet-restic"), "#!"+bash+`
echo "fleet-restic $*" >> `+r.log+`
[ "$1" = restore ] || exit 2
id=$2; shift 2
[ "$id" = latest ] && { id=$(ls -t "$FAKE_REPO" | head -n1); shift 2; }
[ -d "$FAKE_REPO/$id" ] || { echo "no snapshot $id" >&2; exit 1; }
while [ $# -gt 0 ]; do case "$1" in --target) tgt=$2; shift 2;; *) shift;; esac; done
mkdir -p "$tgt$FAKE_ROOT" "$tgt$FAKE_STATE/vlfb/staging"
cp -a "$FAKE_REPO/$id/data/." "$tgt$FAKE_ROOT/"
cp -a "$FAKE_REPO/$id/staging/." "$tgt$FAKE_STATE/vlfb/staging/"
`)
	writeExe(t, filepath.Join(r.bin, "sqlite3"), "#!"+bash+`
f=$2; if grep -q CORRUPT "$f"; then echo "*** in database main ***"; echo "Page 3: btreeInitPage() returns error code 11"; else echo ok; fi
`)
	out := filepath.Join(filepath.Dir(r.root), "out")
	must(t, os.MkdirAll(out+"/bin", 0o755))
	writeExe(t, out+"/bin/fleet-install", "#!"+bash+"\ntouch \"$FAKE_STATE/active-fleet-svc.service\" \"$FAKE_STATE/installed-fleet-svc.service\" \"$FAKE_STATE/podman-svc\"\n")
	writeExe(t, filepath.Join(r.bin, "nix"), "#!/bin/sh\necho "+out+"\n")
	writeExe(t, filepath.Join(r.bin, "podman"), "#!"+bash+`
[ "$1 $2" = "container exists" ] || exit 125
[ -e "$FAKE_STATE/podman-$3" ]
`)
	must(t, os.WriteFile(r.root+".state/podman-svc", nil, 0o644))
	return m
}

func (m *moveRig) srcState() string { return m.root + ".state" }
func (m *moveRig) dstState() string { return m.dst + ".state" }

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	must(t, err)
	return string(b)
}

func runMove(t *testing.T) error {
	return cmdMove([]string{"svc", "--to", "dst", "--from", "src"})
}

// assertSourceIntact: data in place, not retired, running again.
func (m *moveRig) assertSourceIntact(t *testing.T) {
	t.Helper()
	if !exists(filepath.Join(m.root, "svc/data/b")) {
		t.Fatalf("source data was touched")
	}
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) > 0 {
		t.Fatalf("source was retired: %v", g)
	}
	if !exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatalf("source was left stopped:\n%s", m.calls())
	}
	if exists(m.srcState() + "/vlfc/move-svc.was-running") {
		t.Errorf("was-running marker left on the source after the restart")
	}
}

// assertTargetClean: nothing running or in place on the target.
func (m *moveRig) assertTargetClean(t *testing.T) {
	t.Helper()
	if exists(m.dstState() + "/active-fleet-svc.service") {
		t.Fatalf("service left running on the target")
	}
	if exists(filepath.Join(m.dst, "svc")) {
		t.Fatalf("target data left in place (should be moved aside)")
	}
	if exists(m.dstState() + "/vlfc/move-svc") {
		t.Fatalf("move marker left on the target")
	}
}

func TestMoveHappyPath(t *testing.T) {
	m := newMoveRig(t)
	if err := runMove(t); err != nil {
		t.Fatalf("move: %v\n%s", err, m.calls())
	}
	// data on the target: restic part, SQLite copy in place of the live db,
	// live PG cluster copied from the stopped source
	if got := readFile(t, filepath.Join(m.dst, "svc/data/b")); len(got) != 100000 {
		t.Fatalf("data/b: %d bytes", len(got))
	}
	if got := readFile(t, filepath.Join(m.dst, "svc/data/app.db")); !strings.HasSuffix(got, "COPY") {
		t.Fatalf("app.db is not the SQLite backup copy: %q", got)
	}
	if got := readFile(t, filepath.Join(m.dst, "svc/postgres/base/1")); got != "pgdata" {
		t.Fatalf("live PG cluster not copied: %q", got)
	}
	if !exists(m.dstState() + "/active-fleet-svc.service") {
		t.Fatal("not running on the target")
	}
	st, err := parseStamp(readFile(t, m.dstState()+"/vlfc/backup-last/svc"))
	if err != nil || st.Host != "dst" {
		t.Fatalf("no first backup on the target: %+v %v", st, err)
	}
	if exists(m.dstState() + "/vlfc/move-svc") {
		t.Error("move marker left on the target")
	}
	// source retired and stopped
	if g, _ := filepath.Glob(filepath.Join(m.root, "svc.moved-*")); len(g) != 1 || exists(filepath.Join(m.root, "svc")) {
		t.Fatalf("source not renamed to .moved-*: %v", g)
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("source still running")
	}
	// order: final backup, restore, deploy, restore check, first backup, switch
	c := m.calls()
	idx := func(s string) int {
		i := strings.Index(c, s)
		if i < 0 {
			t.Fatalf("%q not in log:\n%s", s, c)
		}
		return i
	}
	stop, fb, rc := idx("systemctl stop fleet-svc.service"), idx("systemctl start fleet-backup-svc@svc.service"), idx("--include")
	if !(stop < fb && fb < rc) {
		t.Errorf("wrong order: stop %d, backup %d, restore check %d", stop, fb, rc)
	}
	if strings.LastIndex(c, "fleet-backup-svc@svc") < rc {
		t.Error("first backup on the target did not follow the restore check")
	}
}

func TestMoveRefusesTargetWithoutBackup(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.Remove(m.dstState()+"/efc/backup"))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "preflight on dst") {
		t.Fatalf("expected a preflight refusal, got %v", err)
	}
	if strings.Contains(m.calls(), "\nsystemctl stop") {
		t.Fatalf("source was stopped although the target cannot be backed up:\n%s", m.calls())
	}
	m.assertSourceIntact(t)
}

func TestMoveRefusesMissingCapability(t *testing.T) {
	m := newMoveRig(t)
	old := capDir
	t.Cleanup(func() { capDir = old })
	capDir = "/etc/fleet-containers/capabilities" // rewritten per host by the fake ssh
	s := inv.Services["svc"]
	s.Requires = []string{"wd10"}
	inv.Services["svc"] = s
	if err := runMove(t); err == nil {
		t.Fatal("move to a host without the capability succeeded")
	}
	if strings.Contains(m.calls(), "\nsystemctl stop") {
		t.Fatal("source was stopped")
	}
	// with the capability it goes through
	must(t, os.WriteFile(m.dstState()+"/efc/capabilities/wd10", nil, 0o644))
	if err := runMove(t); err != nil {
		t.Fatalf("move with the capability: %v", err)
	}
}

func TestMoveFailedRestoreCheckRollsBack(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.WriteFile(filepath.Join(m.root, "svc/data/app.db"), []byte("SQLite format 3\x00LIVE CORRUPT"), 0o644))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "restore check") {
		t.Fatalf("expected the restore check to fail the move, got %v\n%s", err, m.calls())
	}
	m.assertSourceIntact(t)
	m.assertTargetClean(t)
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) != 1 {
		t.Fatalf("target data not kept aside: %v", g)
	}
	// fixed data: a re-run completes
	must(t, os.WriteFile(filepath.Join(m.root, "svc/data/app.db"), []byte("SQLite format 3\x00LIVE"), 0o644))
	if err := runMove(t); err != nil {
		t.Fatalf("re-run after the fix: %v", err)
	}
}

func TestMoveFailsWhenBackupDoesNotRun(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.MkdirAll(m.srcState()+"/vlfc/backup-last", 0o755))
	// an old stamp must not pass for the final backup
	must(t, os.WriteFile(m.srcState()+"/vlfc/backup-last/svc", []byte("time=2026-01-01T00:00:00Z snapshot=abc host=src\n"), 0o644))
	must(t, os.WriteFile(m.srcState()+"/skip-backup", nil, 0o644))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "final backup") {
		t.Fatalf("expected the final backup to fail, got %v", err)
	}
	m.assertSourceIntact(t)
	if strings.Contains(m.calls(), "fleet-restic restore") {
		t.Fatal("restored although no backup was taken")
	}
}

// The deploy fails before the unit exists on the target: stopping it fails
// like real systemd ("not loaded"), absence is proven, so the rollback
// succeeds and the source is started again.
func TestMoveFailedDeployRollsBack(t *testing.T) {
	m := newMoveRig(t)
	writeExe(t, filepath.Join(m.bin, "nix"), "#!/bin/sh\necho 'error: build failed' >&2; exit 1\n")
	if err := runMove(t); err == nil {
		t.Fatal("move succeeded with a failing deploy")
	}
	m.assertSourceIntact(t)
	m.assertTargetClean(t)
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) != 1 {
		t.Fatalf("restored target data not moved aside: %v", g)
	}
}

// A stopped source stays stopped when the move fails.
func TestMoveFailureKeepsStoppedSourceStopped(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.Remove(m.srcState()+"/active-fleet-svc.service"))
	writeExe(t, filepath.Join(m.bin, "nix"), "#!/bin/sh\nexit 1\n")
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "left stopped") {
		t.Fatalf("got %v", err)
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("a stopped source was started")
	}
}

// An interrupted run (killed after the restore) leaves the target marked
// and the source stopped with a was-running marker: the re-run clears the
// target and, on failure, still starts the source again.
func TestMoveRerunAfterInterruption(t *testing.T) {
	m := newMoveRig(t)
	must(t, os.MkdirAll(filepath.Join(m.dst, "svc/data"), 0o755))
	must(t, os.WriteFile(filepath.Join(m.dst, "svc/data/half"), nil, 0o644))
	must(t, os.WriteFile(m.dstState()+"/vlfc/move-svc", []byte("from=src snapshot=abc\n"), 0o644))
	must(t, os.Remove(m.srcState()+"/active-fleet-svc.service"))
	must(t, os.WriteFile(m.srcState()+"/vlfc/move-svc.was-running", nil, 0o644))
	writeExe(t, filepath.Join(m.bin, "nix"), "#!/bin/sh\nexit 1\n")
	err := runMove(t)
	if err == nil {
		t.Fatal("expected the deploy to fail")
	}
	t.Log(err)
	m.assertSourceIntact(t) // started again: it was running before the first attempt
	if g, _ := filepath.Glob(filepath.Join(m.dst, "svc.failed-move-*")); len(g) < 1 {
		t.Fatal("leftovers not moved aside")
	}
	// unmarked data on the target is refused, not overwritten
	must(t, os.MkdirAll(filepath.Join(m.dst, "svc/x"), 0o755))
	if err := runMove(t); err == nil || !strings.Contains(err.Error(), "preflight") {
		t.Fatalf("foreign data on the target must be refused: %v", err)
	}
}

func TestMoveDryRunShowsPlan(t *testing.T) {
	m := newMoveRig(t)
	dryRun = true
	t.Cleanup(func() { dryRun = false })
	r, w, _ := os.Pipe()
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	err := runMove(t)
	w.Close()
	os.Stdout, os.Stderr = oldOut, oldErr
	b := make([]byte, 1<<20)
	n, _ := r.Read(b)
	out := string(b[:n])
	for {
		k, _ := r.Read(b)
		if k == 0 {
			break
		}
		out += string(b[:k])
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"1/9 preflight", "2/9 final backup", "fleet-backup-svc@svc", "3/9 restoring", "4/9 deploying", "5/9 restore check", "PRAGMA integrity_check", "6/9 first backup", "7/9 committing", "8/9 switch", "9/9", ".moved-"} {
		if !strings.Contains(out, want) {
			t.Errorf("dry run lacks %q", want)
		}
	}
	if m.calls() != "" {
		t.Fatalf("dry run ran something:\n%s", m.calls())
	}
}

func TestParseStamp(t *testing.T) {
	st, err := parseStamp("time=2026-10-22T08:00:00Z snapshot=0a1b2c host=h001\n")
	if err != nil || st.Snapshot != "0a1b2c" || st.Host != "h001" || !st.Time.Equal(time.Date(2026, 10, 22, 8, 0, 0, 0, time.UTC)) {
		t.Fatalf("%+v %v", st, err)
	}
	for _, bad := range []string{"", "time=x snapshot=ab", "snapshot=ab host=h", "time=2026-10-22T08:00:00Z", "time=2026-10-22T08:00:00Z snapshot=ab;rm"} {
		if _, err := parseStamp(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestStampFrom(t *testing.T) {
	since := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	out := "WAS active\nrunning backup hook\nSTAMP time=2026-10-22T12:01:00Z snapshot=ff host=h001\n"
	if st, err := stampFrom(out, "h001", since); err != nil || st.Snapshot != "ff" {
		t.Fatalf("%+v %v", st, err)
	}
	if _, err := stampFrom(out, "h003", since); err == nil {
		t.Error("stamp from another host accepted")
	}
	if _, err := stampFrom("STAMP time=2026-10-21T12:00:00Z snapshot=ff host=h001", "h001", since); err == nil {
		t.Error("old stamp accepted")
	}
	if _, err := stampFrom("nothing", "h001", since); err == nil {
		t.Error("missing stamp accepted")
	}
	if !wasActive("WAS active\n") || !wasActive("WAS activating") || wasActive("WAS inactive") || wasActive("WAS failed") || wasActive("") {
		t.Error("wasActive")
	}
}

func TestEvalRestoreCheck(t *testing.T) {
	ok := "sqlite /srv/containers/x/data.db ok\npgdump /srv/containers/x/all.sql.gz ok\nchecked snapshot ab\n"
	if sum, err := evalRestoreCheck(ok, true); err != nil || sum != "1 SQLite db(s), 1 PG dump(s)" {
		t.Fatalf("%s %v", sum, err)
	}
	for _, bad := range []string{
		"sqlite /a.db *** in database main *** Page 3: bad\n",
		"pgdump /a.sql.gz bad-gzip\n",
		"pgdump /a.sql empty\n",
		"pgdump /a.sql truncated\n",
	} {
		if _, err := evalRestoreCheck(bad, false); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if _, err := evalRestoreCheck("sqlite /a.db ok\n", true); err == nil {
		t.Error("a service with a pg_dump hook must have a dump")
	}
	if !needsPGDump(Service{BackupHook: "runuser -u postgres -- pg_dumpall > x"}) || needsPGDump(Service{}) {
		t.Error("needsPGDump")
	}
}

// The restore-check script itself, on real files in a fake snapshot.
func TestRestoreCheckScriptOnFiles(t *testing.T) {
	m := newMoveRig(t)
	bash := realPath(t, "bash")
	d := m.root + "/svc/pgdumps"
	must(t, exec.Command(bash, "-c", "printf -- '-- PostgreSQL database dump\\nCOPY\\n' | gzip > "+d+"/trunc.sql.gz; : > "+d+"/empty.sql; echo garbage > "+d+"/bad.sql.gz; printf 'PGDMP...' > "+d+"/c.dump; printf 'hello' > "+d+"/notpg.sql").Run())
	must(t, os.WriteFile(m.root+"/svc/data/bad.db", []byte("SQLite format 3\x00CORRUPT"), 0o644))
	must(t, os.WriteFile(m.root+"/svc/data/notsqlite.db", []byte("hello"), 0o644))
	if err := cmdRestoreCheck([]string{"svc", "--host", "src", "--snapshot", "deadbeef"}); err == nil {
		t.Error("restore check of a missing snapshot passed")
	}
	if err := cmdRestoreCheck([]string{"svc", "--host", "src", "--snapshot", "x;rm"}); err == nil {
		t.Error("bad snapshot id accepted")
	}
	// take a snapshot, then check it
	c := exec.Command("ssh", "root@src", "bash -c 'systemctl start fleet-backup-svc@svc.service'")
	must(t, c.Run())
	out, err := remoteOut(context.Background(), "src", true, restoreCheckScript(inv.Services["svc"], "latest --tag svc:svc"))
	must(t, err)
	want := map[string]string{
		"/svc/data/app.db":          "ok",
		"/svc/data/bad.db":          "*** in database main *** Page 3: btreeInitPage() returns error code 11",
		"/svc/pgdumps/all.sql.gz":   "ok",
		"/svc/pgdumps/trunc.sql.gz": "truncated",
		"/svc/pgdumps/empty.sql":    "empty",
		"/svc/pgdumps/bad.sql.gz":   "bad-gzip",
		"/svc/pgdumps/c.dump":       "ok",
		"/svc/pgdumps/notpg.sql":    "not-a-pg-dump",
	}
	for suffix, res := range want {
		found := false
		for _, l := range strings.Split(out, "\n") {
			_, rest, _ := strings.Cut(l, " ")
			p, r, _ := strings.Cut(rest, " ")
			if strings.HasSuffix(p, suffix) {
				found = true
				if r != res {
					t.Errorf("%s: %q, want %q", suffix, r, res)
				}
			}
		}
		if !found {
			t.Errorf("%s not checked:\n%s", suffix, out)
		}
	}
	if strings.Contains(out, "notsqlite") {
		t.Error("non-SQLite .db checked as SQLite")
	}
	if g, _ := filepath.Glob(m.srcState() + "/tmp/cnt-restore-check-*"); len(g) > 0 {
		t.Errorf("scratch dir left behind: %v", g)
	}
	if _, err := evalRestoreCheck(out, true); err == nil {
		t.Error("bad files passed")
	}
}

func TestHealthScript(t *testing.T) {
	bash := realPath(t, "bash")
	bin := t.TempDir()
	log := filepath.Join(bin, "log")
	// fake curl: status from $CODE_<port>, logs its args
	writeExe(t, filepath.Join(bin, "curl"), "#!"+bash+"\necho \"$*\" >> "+log+"\nfor a; do case $a in *:8093*) printf %s \"${CODE_8093:-200}\"; exit;; https://*) printf %s \"${CODE_NGINX:-403}\"; exit;; esac; done; printf 000\n")
	writeExe(t, filepath.Join(bin, "sleep"), "#!/bin/sh\nexit 0\n")
	ip, fqdn := "10.233.2.2", "puzzles.example"
	s := Service{Name: "puzzles", Net: Net{Private: true, IP: &ip}, Routes: map[string]Route{
		"web": {Port: 8093, Proto: "http", Exposure: "public", FQDN: &fqdn},
	}}
	run := func(env ...string) error {
		c := exec.Command(bash, "-c", healthScript(s, "100.64.0.13"))
		c.Env = append(append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH")), env...)
		return c.Run()
	}
	if err := run(); err != nil {
		t.Fatalf("healthy route failed: %v", err)
	}
	l := readFile(t, log)
	if !strings.Contains(l, "http://10.233.2.2:8093/") || !strings.Contains(l, "https://puzzles.example/ --resolve puzzles.example:443:100.64.0.13") {
		t.Errorf("checks not as expected:\n%s", l)
	}
	if err := run("CODE_8093=502"); err == nil {
		t.Error("502 from the backend passed")
	}
	if err := run("CODE_NGINX=000"); err == nil {
		t.Error("unreachable nginx passed")
	}
	h := "/healthz"
	r := s.Routes["web"]
	r.Health = &h
	s.Routes["web"] = r
	if err := run("CODE_8093=404"); err == nil {
		t.Error("404 on an explicit health path passed")
	}
	if healthScript(Service{Name: "x"}, "") != "" {
		t.Error("no routes: no script")
	}
}

// rollbackRig runs the real rollback/switch scripts in bash against temp
// dirs, with stub systemctl/machinectl/extra-container in PATH. Stub
// behaviour comes from files in st: active (unit up), stop-fails,
// stop-ignored (stop "succeeds" but the unit stays up), kill-works,
// machine (nixos machine registered), uninstall-fails, loaded (unit
// known to systemd; stopping an unknown unit fails like real systemd),
// container (podman container exists).
type rollbackRig struct {
	t                  *testing.T
	bash, dir, bin, st string
	s                  Service
}

func newRollbackRig(t *testing.T, kind string) *rollbackRig {
	t.Helper()
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock not available")
	}
	r := &rollbackRig{t: t, bash: realPath(t, "bash"), dir: t.TempDir(), bin: t.TempDir()}
	r.st = filepath.Join(r.dir, "state")
	oldI, oldH, oldM, oldN, oldO, oldMU, oldW := inv, holdDir, moveMarkerDir, nginxDir, overridesDir, mutableUnits, moveStopWait
	t.Cleanup(func() {
		inv, holdDir, moveMarkerDir, nginxDir, overridesDir, mutableUnits, moveStopWait = oldI, oldH, oldM, oldN, oldO, oldMU, oldW
	})
	inv = &Inventory{DataRoot: filepath.Join(r.dir, "srv")}
	holdDir, moveMarkerDir = filepath.Join(r.dir, "hold"), filepath.Join(r.dir, "vlfc")
	nginxDir, overridesDir, mutableUnits = filepath.Join(r.dir, "nginx"), filepath.Join(r.dir, "ov"), filepath.Join(r.dir, "units")
	moveStopWait = 1
	r.s = Service{Name: "svc", Kind: kind}
	for _, d := range []string{r.st, moveMarkerDir, filepath.Join(inv.DataRoot, "svc/data")} {
		must(t, os.MkdirAll(d, 0o755))
	}
	must(t, os.WriteFile(filepath.Join(inv.DataRoot, "svc/data/f"), []byte("x"), 0o644))
	must(t, os.WriteFile(moveMarker("svc"), nil, 0o644))
	must(t, os.WriteFile(filepath.Join(r.st, "active"), nil, 0o644))
	must(t, os.WriteFile(filepath.Join(r.st, "loaded"), nil, 0o644))
	st := r.st
	writeExe(t, filepath.Join(r.bin, "systemctl"), "#!"+r.bash+`
echo "$*" >> `+st+`/log
case "$1" in
is-active) if [ -e `+st+`/active ]; then echo active; exit 0; fi; echo inactive; exit 3 ;;
show) [ -e `+st+`/loaded ] && echo loaded || echo not-found ;;
stop) [ -e `+st+`/loaded ] || { echo "Failed to stop $2: Unit $2 not loaded." >&2; exit 5; }
  [ -e `+st+`/stop-fails ] && exit 1; [ -e `+st+`/stop-ignored ] || rm -f `+st+`/active; rm -f `+st+`/machine ;;
kill) [ -e `+st+`/kill-works ] && rm -f `+st+`/active ;;
esac
exit 0
`)
	writeExe(t, filepath.Join(r.bin, "machinectl"), "#!"+r.bash+"\n[ -e "+st+"/machine ]\n")
	writeExe(t, filepath.Join(r.bin, "podman"), "#!"+r.bash+"\n[ \"$1 $2\" = \"container exists\" ] || exit 125\n[ -e "+st+"/container ]\n")
	writeExe(t, filepath.Join(r.bin, "extra-container"), "#!"+r.bash+"\n! [ -e "+st+"/uninstall-fails ]\n")
	return r
}

func (r *rollbackRig) set(f string) { must(r.t, os.WriteFile(filepath.Join(r.st, f), nil, 0o644)) }

func (r *rollbackRig) run(script string) (string, error) {
	c := exec.Command(r.bash, "-c", script)
	c.Env = append(os.Environ(), "PATH="+r.bin+":"+os.Getenv("PATH"))
	out, err := c.CombinedOutput()
	return string(out), err
}

// untouched: data in place, nothing moved aside, marker kept.
func (r *rollbackRig) assertUntouched(out string) {
	r.t.Helper()
	if !exists(filepath.Join(inv.DataRoot, "svc/data/f")) {
		r.t.Fatalf("data moved although the target was not confirmed down:\n%s", out)
	}
	if g, _ := filepath.Glob(filepath.Join(inv.DataRoot, "svc.failed-move-*")); len(g) > 0 {
		r.t.Fatalf("data moved aside: %v", g)
	}
	if !exists(moveMarker("svc")) {
		r.t.Fatalf("move marker removed after a failed rollback:\n%s", out)
	}
}

func TestRollbackTargetFailures(t *testing.T) {
	for _, tc := range []struct {
		name, kind string
		flags      []string
	}{
		{"stop fails", "nixos", []string{"stop-fails"}},
		{"unit stays active", "podman", []string{"stop-ignored"}},
		{"unit stays active after kill", "nixos", []string{"stop-ignored"}},
		{"machine still registered", "nixos", []string{"machine", "stop-fails"}},
		{"uninstall fails", "nixos", []string{"uninstall-fails"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRollbackRig(t, tc.kind)
			for _, f := range tc.flags {
				r.set(f)
			}
			out, err := r.run(rollbackTargetScript(r.s))
			if err == nil {
				t.Fatalf("rollback succeeded:\n%s", out)
			}
			r.assertUntouched(out)
		})
	}
}

// A machine that stays registered (nsenter-able) after the unit is down
// is not "down" either.
func TestRollbackTargetWaitsForMachine(t *testing.T) {
	r := newRollbackRig(t, "nixos")
	writeExe(t, filepath.Join(r.bin, "machinectl"), "#!"+r.bash+"\nexit 0\n") // always registered
	out, err := r.run(rollbackTargetScript(r.s))
	if err == nil {
		t.Fatalf("rollback succeeded with the machine still registered:\n%s", out)
	}
	r.assertUntouched(out)
}

func TestRollbackTargetKillsStuckUnit(t *testing.T) {
	r := newRollbackRig(t, "podman")
	r.set("stop-ignored")
	r.set("kill-works")
	out, err := r.run(rollbackTargetScript(r.s))
	if err != nil {
		t.Fatalf("rollback: %v\n%s", err, out)
	}
	if !strings.Contains(readFile(t, filepath.Join(r.st, "log")), "kill --signal=SIGKILL") {
		t.Fatal("stuck unit not killed")
	}
}

func TestRollbackTargetHappyPath(t *testing.T) {
	for _, kind := range []string{"nixos", "podman"} {
		t.Run(kind, func(t *testing.T) {
			r := newRollbackRig(t, kind)
			out, err := r.run(rollbackTargetScript(r.s))
			if err != nil {
				t.Fatalf("rollback: %v\n%s", err, out)
			}
			if exists(filepath.Join(inv.DataRoot, "svc")) || exists(moveMarker("svc")) || exists(filepath.Join(r.st, "active")) {
				t.Fatalf("not rolled back:\n%s", out)
			}
			if g, _ := filepath.Glob(filepath.Join(inv.DataRoot, "svc.failed-move-*/data/f")); len(g) != 1 {
				t.Fatalf("data not moved aside: %v", g)
			}
		})
	}
}

func TestSwitchRequiresStoppedSource(t *testing.T) {
	r := newRollbackRig(t, "nixos")
	must(t, os.WriteFile(moveSourceMarker("svc"), nil, 0o644))
	r.set("stop-fails")
	out, err := r.run(switchScript(r.s))
	if err == nil {
		t.Fatalf("switch succeeded with the source up:\n%s", out)
	}
	if !exists(filepath.Join(inv.DataRoot, "svc/data/f")) || !exists(moveSourceMarker("svc")) {
		t.Fatal("source renamed or marker dropped while it may be running")
	}
	must(t, os.Remove(filepath.Join(r.st, "stop-fails")))
	if out, err := r.run(switchScript(r.s)); err != nil {
		t.Fatalf("switch: %v\n%s", err, out)
	}
	if g, _ := filepath.Glob(filepath.Join(inv.DataRoot, "svc.moved-*")); len(g) != 1 || exists(moveSourceMarker("svc")) {
		t.Fatalf("not switched: %v", g)
	}
}

func TestPreflightLeftoverCleanupFailureRefuses(t *testing.T) {
	r := newRollbackRig(t, "nixos")
	r.set("stop-fails")
	// only the leftover part: the rest needs the real host layout
	body := strict + "if [ -e " + q(moveMarker("svc")) + " ]; then\n" + retireTargetBody(r.s) + "fi\n"
	if !strings.Contains(movePreflightTarget(r.s, "dst"), strings.TrimSpace(strings.Split(retireTargetBody(r.s), "\n")[0])) {
		t.Fatal("preflight does not use the confirmed retire")
	}
	if strings.Contains(movePreflightTarget(r.s, "dst"), ") || true\n") {
		t.Fatal("preflight still masks leftover cleanup failures")
	}
	out, err := r.run(body)
	if err == nil {
		t.Fatalf("leftover cleanup succeeded:\n%s", out)
	}
	r.assertUntouched(out)
}

func TestRestartSourceAfterUndo(t *testing.T) {
	for _, c := range []struct{ down, was, want bool }{
		{true, true, true}, {true, false, false}, {false, true, false}, {false, false, false},
	} {
		if got := restartSourceAfterUndo(c.down, c.was); got != c.want {
			t.Errorf("restartSourceAfterUndo(%v, %v) = %v", c.down, c.was, got)
		}
	}
	msg := rollbackFailedMsg(Service{Name: "svc", Kind: "nixos"}, "src", "dst", errors.New("boom"))
	for _, w := range []string{"ROLLBACK ON dst FAILED", "NOT started again on src", "boom", "was-running"} {
		if !strings.Contains(msg, w) {
			t.Errorf("message lacks %q:\n%s", w, msg)
		}
	}
}

// End to end: the target's stop fails during rollback, so the source must
// stay stopped with its was-running marker, and the move fails.
func TestMoveFailedRollbackKeepsSourceStopped(t *testing.T) {
	m := newMoveRig(t)
	moveStopWait = 1
	t.Cleanup(func() { moveStopWait = 60 })
	writeExe(t, filepath.Join(m.bin, "nix"), "#!/bin/sh\nexit 1\n")
	// stop on the target fails (the fake ssh sets FAKE_HOST)
	sc := readFile(t, filepath.Join(m.bin, "systemctl"))
	writeExe(t, filepath.Join(m.bin, "systemctl"), strings.Replace(sc, "  rm -f \"$FAKE_STATE/active-$2\" ;;", "  [ \"$FAKE_HOST\" = dst ] && exit 1; rm -f \"$FAKE_STATE/active-$2\" ;;", 1))
	// the unit is loaded on the target (left from an earlier attempt), so the failing stop counts
	must(t, os.MkdirAll(m.dstState(), 0o755))
	must(t, os.WriteFile(m.dstState()+"/installed-fleet-svc.service", nil, 0o644))
	err := runMove(t)
	if err == nil || !strings.Contains(err.Error(), "ROLLBACK ON dst FAILED") {
		t.Fatalf("got %v\n%s", err, m.calls())
	}
	if exists(m.srcState() + "/active-fleet-svc.service") {
		t.Fatal("source started although the target rollback failed")
	}
	if !exists(m.srcState() + "/vlfc/move-svc.was-running") {
		t.Fatal("was-running marker dropped")
	}
	if !exists(m.dstState() + "/vlfc/move-svc") {
		t.Fatal("target marker dropped")
	}
}

// neverInstalled: deploy failed before the unit existed.
func (r *rollbackRig) neverInstalled() {
	for _, f := range []string{"active", "loaded"} {
		must(r.t, os.Remove(filepath.Join(r.st, f)))
	}
	r.set("uninstall-fails") // must not even be tried
}

func TestRollbackTargetNeverInstalled(t *testing.T) {
	for _, kind := range []string{"nixos", "podman"} {
		t.Run(kind, func(t *testing.T) {
			r := newRollbackRig(t, kind)
			r.neverInstalled()
			out, err := r.run(rollbackTargetScript(r.s))
			if err != nil {
				t.Fatalf("rollback: %v\n%s", err, out)
			}
			if exists(filepath.Join(inv.DataRoot, "svc")) || exists(moveMarker("svc")) {
				t.Fatalf("not rolled back:\n%s", out)
			}
			if g, _ := filepath.Glob(filepath.Join(inv.DataRoot, "svc.failed-move-*/data/f")); len(g) != 1 {
				t.Fatalf("data not moved aside: %v", g)
			}
		})
	}
	// no data at all is fine too
	r := newRollbackRig(t, "nixos")
	r.neverInstalled()
	must(t, os.RemoveAll(filepath.Join(inv.DataRoot, "svc")))
	if out, err := r.run(rollbackTargetScript(r.s)); err != nil || exists(moveMarker("svc")) {
		t.Fatalf("rollback without data: %v\n%s", err, out)
	}
}

func TestRollbackTargetAbsenceNotProven(t *testing.T) {
	for _, tc := range []struct {
		name, kind string
		setup      func(r *rollbackRig)
	}{
		{"machine still registered", "nixos", func(r *rollbackRig) { r.set("machine") }},
		{"container still exists", "podman", func(r *rollbackRig) { r.set("container") }},
		{"unit file present", "nixos", func(r *rollbackRig) {
			must(r.t, os.MkdirAll(mutableUnits, 0o755))
			must(r.t, os.WriteFile(mutableUnits+"/"+unitOf(r.s), nil, 0o644))
		}},
		{"podman broken", "podman", func(r *rollbackRig) {
			writeExe(r.t, filepath.Join(r.bin, "podman"), "#!"+r.bash+"\nexit 125\n")
		}},
		{"loaded unit, stop fails", "nixos", func(r *rollbackRig) { r.set("loaded"); r.set("stop-fails") }},
		{"loaded podman unit, stop fails", "podman", func(r *rollbackRig) { r.set("loaded"); r.set("stop-fails") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRollbackRig(t, tc.kind)
			r.neverInstalled()
			tc.setup(r)
			out, err := r.run(rollbackTargetScript(r.s))
			if err == nil {
				t.Fatalf("rollback succeeded:\n%s", out)
			}
			r.assertUntouched(out)
		})
	}
}
