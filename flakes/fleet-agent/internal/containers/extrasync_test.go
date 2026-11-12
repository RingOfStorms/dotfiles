package containers

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// These tests exercise restic's real subtree, filter, overwrite and deletion
// semantics. Everything, including both sides of the same absolute path, lives
// under t.TempDir; no root privileges or network repository are needed.
type extraSyncResticRig struct {
	t      *testing.T
	root   string
	repo   string
	bash   string
	restic string
	env    []string
}

func newExtraSyncResticRig(t *testing.T) *extraSyncResticRig {
	t.Helper()
	restic, err := exec.LookPath("restic")
	if err != nil {
		t.Skip("restic not available")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	r := &extraSyncResticRig{t: t, root: t.TempDir(), bash: bash, restic: restic}
	r.repo = filepath.Join(r.root, "repo")
	bin := filepath.Join(r.root, "bin")
	must(t, os.MkdirAll(bin, 0o700))
	// Keep the production command shape, but replace only the fleet credential
	// wrapper. All backup and restore work is performed by the real restic.
	writeExe(t, filepath.Join(bin, "fleet-restic"), "#!"+bash+`
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --subject) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec `+q(restic)+` "${args[@]}"
`)
	// Do not inherit an operator's repository, password-command, host filter,
	// or other restic settings, and never use their normal cache directory.
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "RESTIC_") && !strings.HasPrefix(e, "PATH=") {
			r.env = append(r.env, e)
		}
	}
	r.env = append(r.env, "PATH="+bin+":"+os.Getenv("PATH"), "RESTIC_PASSWORD=extra-sync-test-password", "RESTIC_CACHE_DIR="+filepath.Join(r.root, "cache"))
	r.resticRun("init")
	return r
}

func (r *extraSyncResticRig) resticRun(args ...string) string {
	r.t.Helper()
	cmd := exec.Command(r.restic, append([]string{"-r", r.repo}, args...)...)
	cmd.Env = r.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("restic %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func (r *extraSyncResticRig) backup(s Service, when string, also ...string) string {
	r.t.Helper()
	args := []string{"backup", "--json", "--tag", "svc:" + s.Name, "--time", when}
	var paths []string
	for _, e := range s.Backup.ExtraPaths {
		paths = append(paths, e.Path)
		for _, exclude := range e.Exclude {
			args = append(args, "--exclude", filepath.Join(e.Path, exclude))
		}
	}
	args = append(args, paths...)
	args = append(args, also...)
	out := r.resticRun(args...)
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var entry struct {
			MessageType string `json:"message_type"`
			SnapshotID  string `json:"snapshot_id"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			r.t.Fatalf("decoding restic backup output: %v\n%s", err, out)
		}
		if entry.MessageType == "summary" && entry.SnapshotID != "" {
			return entry.SnapshotID
		}
	}
	r.t.Fatalf("restic backup did not return a snapshot ID:\n%s", out)
	return ""
}

func (r *extraSyncResticRig) run(s Service, snap, into string) (string, error) {
	r.t.Helper()
	var paths []string
	for _, e := range s.Backup.ExtraPaths {
		paths = append(paths, e.Path)
	}
	cmd := exec.Command(r.bash, "-c", extraRestoreScript(s, r.repo, snap, paths, into))
	cmd.Env = r.env
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (r *extraSyncResticRig) sync(s Service, snap, into string) {
	r.t.Helper()
	if out, err := r.run(s, snap, into); err != nil {
		r.t.Fatalf("sync %s into %q: %v\n%s", snap, into, err, out)
	}
}

func (r *extraSyncResticRig) write(path, content string) {
	r.t.Helper()
	must(r.t, os.MkdirAll(filepath.Dir(path), 0o755))
	must(r.t, os.WriteFile(path, []byte(content), 0o644))
}

func (r *extraSyncResticRig) file(path, want string) {
	r.t.Helper()
	if got := readFile(r.t, path); got != want {
		r.t.Errorf("%s = %q, want %q", path, got, want)
	}
}

func (r *extraSyncResticRig) absent(path string) {
	r.t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		r.t.Errorf("%s should not exist, stat error: %v", path, err)
	}
}

func (r *extraSyncResticRig) mode(path string, want os.FileMode) {
	r.t.Helper()
	st, err := os.Stat(path)
	must(r.t, err)
	if got := st.Mode().Perm(); got != want {
		r.t.Errorf("%s mode = %04o, want %04o", path, got, want)
	}
}

func TestExtraSyncResticPrecopyAndStampedDelta(t *testing.T) {
	r := newExtraSyncResticRig(t)
	p := filepath.Join(r.root, "parent", "extra data")
	s := Service{Name: "sync-test", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{{
		Path: p, Exclude: []string{"cache", "nested/cache"},
	}}}}
	for name, content := range map[string]string{
		"changed":                  "before quiesce",
		"stable":                   "unchanged data",
		"deleted":                  "removed before final backup",
		"deleted-dir/file":         "removed directory",
		"nested/deleted":           "removed nested data",
		"cache/source-only":        "excluded source cache",
		"nested/cache/source-only": "excluded nested source cache",
	} {
		r.write(filepath.Join(p, name), content)
	}
	must(t, os.Chmod(p, 0o751))
	sibling := filepath.Join(filepath.Dir(p), "sibling", "keep")
	r.write(sibling, "sibling in snapshot")
	r.backup(s, "2026-01-01 01:00:00", filepath.Dir(sibling))
	// A newer snapshot for another subject must not win the latest lookup.
	r.write(filepath.Join(p, "changed"), "wrong subject snapshot")
	other := s
	other.Name = "another-service"
	r.backup(other, "2026-01-01 02:00:00", filepath.Dir(sibling))
	r.write(filepath.Join(p, "changed"), "before quiesce")

	// Vacate the source's absolute path so it becomes the destination. Keep
	// the real source aside for the later, post-quiesce backup at that path.
	source := filepath.Join(r.root, "source-held")
	must(t, os.Rename(p, source))
	must(t, os.Mkdir(p, 0o700))
	r.write(sibling, "destination sibling must stay")
	unbackedSibling := filepath.Join(filepath.Dir(p), "not-in-snapshot", "keep")
	r.write(unbackedSibling, "unbacked sibling must stay")
	r.sync(s, "latest", "")
	r.file(filepath.Join(p, "changed"), "before quiesce")
	r.file(filepath.Join(p, "stable"), "unchanged data")
	r.file(filepath.Join(p, "deleted"), "removed before final backup")
	r.absent(filepath.Join(p, "cache", "source-only"))
	r.absent(filepath.Join(p, "nested", "cache", "source-only"))
	r.mode(p, 0o751)
	marker := filepath.Join(p, ".cnt-sync-"+s.Name)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("pre-sync did not retain its ownership marker: %v", err)
	}
	r.file(sibling, "destination sibling must stay")
	r.file(unbackedSibling, "unbacked sibling must stay")

	// Destination-local caches, including a nested excluded directory, must
	// survive --delete. Give the marker content to detect deletion/recreation.
	r.write(marker, "resume this sync")
	r.write(filepath.Join(p, "cache", "local-only"), "keep local cache")
	r.write(filepath.Join(p, "nested", "cache", "local-only"), "keep nested local cache")
	r.write(filepath.Join(p, "destination-only"), "delete this stale file")
	must(t, os.Chmod(p, 0o700))
	r.write(filepath.Join(source, "changed"), "changed after quiesce, from stamped snapshot")
	r.write(filepath.Join(source, "added", "file"), "added after pre-sync")
	must(t, os.Remove(filepath.Join(source, "deleted")))
	must(t, os.RemoveAll(filepath.Join(source, "deleted-dir")))
	must(t, os.Remove(filepath.Join(source, "nested", "deleted")))

	// Restic records absolute paths: swap the source back only while backing
	// it up, then put the partially synchronized destination back in place.
	destination := filepath.Join(r.root, "destination-held")
	must(t, os.Rename(p, destination))
	must(t, os.Rename(source, p))
	stamp := backupStamp{Snapshot: r.backup(s, "2026-01-01 03:00:00", filepath.Dir(sibling)), Repo: r.repo}
	// The final phase must use the stamp, not a newer snapshot of this service.
	r.write(filepath.Join(p, "changed"), "wrong newer snapshot after stamp")
	r.backup(s, "2026-01-01 04:00:00", filepath.Dir(sibling))
	must(t, os.Rename(p, source))
	must(t, os.Rename(destination, p))
	r.sync(s, stamp.Snapshot, "")

	r.file(filepath.Join(p, "changed"), "changed after quiesce, from stamped snapshot")
	r.file(filepath.Join(p, "stable"), "unchanged data")
	r.file(filepath.Join(p, "added", "file"), "added after pre-sync")
	for _, name := range []string{"deleted", "deleted-dir", "nested/deleted", "destination-only", "cache/source-only", "nested/cache/source-only"} {
		r.absent(filepath.Join(p, name))
	}
	r.file(filepath.Join(p, "cache", "local-only"), "keep local cache")
	r.file(filepath.Join(p, "nested", "cache", "local-only"), "keep nested local cache")
	r.file(marker, "resume this sync")
	r.mode(p, 0o751)
	r.file(sibling, "destination sibling must stay")
	r.file(unbackedSibling, "unbacked sibling must stay")
}

func TestExtraSyncResticRefusesForeignDestinationAndResumesMarker(t *testing.T) {
	r := newExtraSyncResticRig(t)
	p := filepath.Join(r.root, "parent", "extra")
	s := Service{Name: "sync-test", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{{Path: p}}}}
	r.write(filepath.Join(p, "wanted"), "snapshot data")
	id := r.backup(s, "2026-01-01 01:00:00")
	must(t, os.Rename(p, filepath.Join(r.root, "source-held")))
	r.write(filepath.Join(p, "foreign"), "foreign data must not be deleted")
	marker := filepath.Join(p, ".cnt-sync-"+s.Name)
	if out, err := r.run(s, id, ""); err == nil {
		t.Fatalf("accepted a nonempty, unowned destination:\n%s", out)
	}
	r.file(filepath.Join(p, "foreign"), "foreign data must not be deleted")
	r.absent(filepath.Join(p, "wanted"))
	r.absent(marker)

	// Another service's marker is foreign data, not permission to overwrite.
	otherMarker := filepath.Join(p, ".cnt-sync-another-service")
	r.write(otherMarker, "another service")
	if out, err := r.run(s, id, ""); err == nil {
		t.Fatalf("accepted another service's marker:\n%s", out)
	}
	r.file(filepath.Join(p, "foreign"), "foreign data must not be deleted")
	r.file(otherMarker, "another service")
	r.absent(marker)

	must(t, os.Remove(otherMarker))
	r.write(marker, "interrupted sync marker")
	r.write(filepath.Join(p, "wanted"), "partial data")
	r.sync(s, id, "")
	r.file(filepath.Join(p, "wanted"), "snapshot data")
	r.file(marker, "interrupted sync marker")
	r.absent(filepath.Join(p, "foreign"))
}

func TestExtraSyncResticIntoMirrorsOnlyRequestedPath(t *testing.T) {
	r := newExtraSyncResticRig(t)
	p := filepath.Join(r.root, "parent", "extra")
	s := Service{Name: "sync-test", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{{
		Path: p, Exclude: []string{"cache", "nested/cache"},
	}}}}
	r.write(filepath.Join(p, "wanted"), "snapshot data")
	r.write(filepath.Join(p, "cache", "source-only"), "excluded cache")
	r.write(filepath.Join(p, "nested", "cache", "source-only"), "excluded nested cache")
	must(t, os.Chmod(p, 0o751))
	sibling := filepath.Join(filepath.Dir(p), "sibling", "keep")
	r.write(sibling, "sibling in snapshot")
	id := r.backup(s, "2026-01-01 01:00:00", filepath.Dir(sibling))
	r.write(filepath.Join(p, "wanted"), "live source must not change")

	into := filepath.Join(r.root, "scratch")
	target := filepath.Join(into, strings.TrimPrefix(p, string(filepath.Separator)))
	r.write(filepath.Join(target, "obsolete"), "scratch is allowed to be nonempty")
	r.write(filepath.Join(target, "cache", "local-only"), "keep scratch cache")
	r.write(filepath.Join(target, "nested", "cache", "local-only"), "keep nested scratch cache")
	must(t, os.Chmod(target, 0o700))
	scratchSibling := filepath.Join(filepath.Dir(target), "sibling", "keep")
	r.write(scratchSibling, "scratch sibling must stay")
	r.sync(s, id, into)

	r.file(filepath.Join(target, "wanted"), "snapshot data")
	r.absent(filepath.Join(target, "obsolete"))
	r.absent(filepath.Join(target, "cache", "source-only"))
	r.absent(filepath.Join(target, "nested", "cache", "source-only"))
	r.file(filepath.Join(target, "cache", "local-only"), "keep scratch cache")
	r.file(filepath.Join(target, "nested", "cache", "local-only"), "keep nested scratch cache")
	if _, err := os.Stat(filepath.Join(target, ".cnt-sync-"+s.Name)); err != nil {
		t.Fatalf("scratch sync did not retain its ownership marker: %v", err)
	}
	r.mode(target, 0o751)
	r.file(scratchSibling, "scratch sibling must stay")
	r.file(filepath.Join(p, "wanted"), "live source must not change")
	r.absent(filepath.Join(p, ".cnt-sync-"+s.Name))
	r.file(sibling, "sibling in snapshot")
}

func TestExtraSyncResticMissingSnapshotPathFailsSafely(t *testing.T) {
	r := newExtraSyncResticRig(t)
	p := filepath.Join(r.root, "parent", "extra")
	s := Service{Name: "sync-test", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{{Path: p}}}}
	sibling := filepath.Join(filepath.Dir(p), "sibling", "keep")
	r.write(sibling, "unrelated snapshot data")
	onlySibling := s
	onlySibling.Backup.ExtraPaths = []BackupExtraPath{{Path: filepath.Dir(sibling)}}
	id := r.backup(onlySibling, "2026-01-01 01:00:00")
	must(t, os.Mkdir(p, 0o700))
	if out, err := r.run(s, id, ""); err == nil {
		t.Fatalf("accepted a snapshot missing the requested path:\n%s", out)
	}
	marker := filepath.Join(p, ".cnt-sync-"+s.Name)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("failed sync did not leave its marker for resumption: %v", err)
	}

	r.write(marker, "failed sync marker")
	r.write(filepath.Join(p, "partial"), "partial data must survive failed restore")
	if out, err := r.run(s, id, ""); err == nil {
		t.Fatalf("resumed against a snapshot missing the requested path:\n%s", out)
	}
	r.file(marker, "failed sync marker")
	r.file(filepath.Join(p, "partial"), "partial data must survive failed restore")
	r.file(sibling, "unrelated snapshot data")
}

func TestExtraSyncResticRefusesMarkedSymlinkDestination(t *testing.T) {
	r := newExtraSyncResticRig(t)
	p := filepath.Join(r.root, "parent", "extra")
	s := Service{Name: "sync-test", Backup: BackupSpec{ExtraPaths: []BackupExtraPath{{Path: p}}}}
	r.write(filepath.Join(p, "wanted"), "snapshot data")
	id := r.backup(s, "2026-01-01 01:00:00")
	must(t, os.Rename(p, filepath.Join(r.root, "source-held")))
	foreign := filepath.Join(r.root, "foreign-target")
	r.write(filepath.Join(foreign, "foreign"), "symlink target must stay")
	marker := filepath.Join(foreign, ".cnt-sync-"+s.Name)
	r.write(marker, "marked foreign target")
	must(t, os.Symlink(foreign, p))
	if out, err := r.run(s, id, ""); err == nil {
		t.Fatalf("accepted a marked symlink destination:\n%s", out)
	}
	if target, err := os.Readlink(p); err != nil || target != foreign {
		t.Fatalf("destination symlink changed: target=%q, error=%v", target, err)
	}
	r.file(filepath.Join(foreign, "foreign"), "symlink target must stay")
	r.file(marker, "marked foreign target")
	r.absent(filepath.Join(foreign, "wanted"))
}
