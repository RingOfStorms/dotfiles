package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The tests run the real backup/move code paths. `ssh` is replaced by a
// script that runs the remote command locally, and systemctl/extra-container
// are stubs that log their calls. A "break" dir can shadow tar/zstd to inject
// failures on one side only.

type rig struct {
	t      *testing.T
	root   string // fake /srv/containers on "src"
	dst    string // fake /srv/containers on "dst"
	log    string
	bin    string
	breaks map[string]string // host -> dir with broken tools
}

func newRig(t *testing.T) *rig {
	t.Helper()
	for _, tool := range []string{"tar", "zstd", "bash", "find", "sha256sum"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not available", tool)
		}
	}
	d := t.TempDir()
	r := &rig{t: t, root: filepath.Join(d, "src"), dst: filepath.Join(d, "dst"), log: filepath.Join(d, "calls.log"), bin: filepath.Join(d, "bin"), breaks: map[string]string{}}
	for _, p := range []string{r.root + "/svc/data/sub", r.dst, r.bin} {
		must(t, os.MkdirAll(p, 0o755))
	}
	for i, body := range []string{"hello", strings.Repeat("x", 100000), "db"} {
		must(t, os.WriteFile(filepath.Join(r.root, "svc/data", []string{"a", "b", "sub/c"}[i]), []byte(body), 0o644))
	}
	// Fake ssh: args are [...opts, target, "bash -c '<script>'"]. Each host maps
	// its data root via sed so src and dst are separate dirs.
	ssh := "#!" + realPath(t, "bash") + `
target=""; for a in "$@"; do last="$a"; done
for a in "$@"; do case "$a" in -o|-t) ;; *@*) target="${a#*@}";; esac; done
echo "ssh $target: $last" >> ` + r.log + `
host="$target"
script="$last"
script="${script//\/etc\/systemd-mutable\/system/\/}"
if [ "$host" = dst ]; then s='` + r.root + `'; d='` + r.dst + `'; script="${script//"$s"/"$d"}"; fi
brk="BREAK_$host"; extra="${!brk:-}"
PATH="${extra:+$extra:}` + r.bin + `:$PATH" eval "$script"
`
	writeExe(t, filepath.Join(r.bin, "ssh"), ssh)
	for _, stub := range []string{"systemctl", "extra-container", "nixos-container", "nginx"} {
		writeExe(t, filepath.Join(r.bin, stub), "#!/bin/sh\necho \""+stub+" $*\" >> "+r.log+"\ncase \"$1\" in is-active) exit 3;; esac\nexit 0\n")
	}
	t.Setenv("PATH", r.bin+":"+os.Getenv("PATH"))

	sshUser = "root"
	dryRun = false
	inv = &Inventory{
		DataRoot: r.root,
		Services: map[string]Service{"svc": {Name: "svc", Dir: "svc", Kind: "podman", Host: "src"}},
		Hosts:    map[string]Host{"src": {User: "root"}, "dst": {User: "root"}},
	}
	return r
}

// breakTool makes `tool` fail on host (after partially working, like a real
// read/disk error).
func (r *rig) breakTool(host, tool, script string) {
	dir := filepath.Join(filepath.Dir(r.bin), "break-"+host)
	must(r.t, os.MkdirAll(dir, 0o755))
	writeExe(r.t, filepath.Join(dir, tool), script)
	r.t.Setenv("BREAK_"+host, dir)
}

func (r *rig) calls() string {
	b, _ := os.ReadFile(r.log)
	return string(b)
}

func writeExe(t *testing.T, p, body string) {
	t.Helper()
	must(t, os.WriteFile(p, []byte(body), 0o755))
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func realPath(t *testing.T, tool string) string {
	p, err := exec.LookPath(tool)
	must(t, err)
	return p
}

// A failing producer on the left of a pipe must not be masked.
func TestPackScriptPropagatesTarFailure(t *testing.T) {
	r := newRig(t)
	r.breakTool("src", "tar", "#!/bin/sh\necho partial\necho 'tar: data/b: Cannot open: Input/output error' >&2\nexit 2\n")
	// Sanity: the naive pipeline (what the code used before) reports success.
	naive := exec.Command("ssh", "root@src", "bash -c 'tar -C "+r.root+" -cf - svc | zstd -q -c'")
	naive.Stdout = nil
	if err := naive.Run(); err != nil {
		t.Fatalf("expected naive pipeline to hide the failure, got %v", err)
	}
	c := exec.Command("ssh", sshArgs("src", false, packScript(r.root, "svc"), true)...)
	if err := c.Run(); err == nil {
		t.Fatal("packScript succeeded although tar failed")
	}
}

func TestBackupFailsOnSourceReadError(t *testing.T) {
	r := newRig(t)
	r.breakTool("src", "tar", "#!/bin/sh\nprintf 'partial-archive'\necho 'tar: Cannot open: Input/output error' >&2\nexit 2\n")
	out := filepath.Join(t.TempDir(), "b.tar.zst")
	err := cmdBackup([]string{"svc", "-o", out})
	if err == nil {
		t.Fatal("backup reported success with a failing tar")
	}
	assertNoArchive(t, out)
	if !strings.Contains(r.calls(), "systemctl start") && strings.Contains(r.calls(), "was-running") {
		t.Error("service was not restarted after the failed backup")
	}
}

func TestBackupFailsOnCompressionError(t *testing.T) {
	newRig(t)
	dir := t.TempDir()
	writeExe(t, filepath.Join(dir, "zstd"), "#!/bin/sh\nhead -c 100 >/dev/null; printf 'trunc'; echo 'zstd: write error' >&2; exit 1\n")
	t.Setenv("BREAK_src", dir)
	out := filepath.Join(t.TempDir(), "b.tar.zst")
	if err := cmdBackup([]string{"svc", "-o", out}); err == nil {
		t.Fatal("backup reported success with a failing compressor")
	}
	assertNoArchive(t, out)
}

func TestBackupSucceedsAndRoundTrips(t *testing.T) {
	newRig(t)
	out := filepath.Join(t.TempDir(), "b.tar.zst")
	must(t, cmdBackup([]string{"svc", "-o", out}))
	x := t.TempDir()
	cmd := exec.Command("bash", "-c", "zstd -d -q -c "+out+" | tar -xf - -C "+x)
	must(t, cmd.Run())
	got, err := os.ReadFile(filepath.Join(x, "svc/data/b"))
	must(t, err)
	if len(got) != 100000 {
		t.Fatalf("round trip lost data: %d bytes", len(got))
	}
}

func assertNoArchive(t *testing.T, out string) {
	t.Helper()
	if _, err := os.Stat(out); err == nil {
		t.Errorf("archive %s exists after a failed backup", out)
	}
	m, _ := filepath.Glob(filepath.Join(filepath.Dir(out), ".*partial*"))
	if len(m) > 0 {
		t.Errorf("partial temp files left behind: %v", m)
	}
}

// For move, a failure anywhere in the transfer must stop before deploy and
// before the source data is renamed/removed.
func assertSourceKept(t *testing.T, r *rig) {
	t.Helper()
	if !strings.Contains(r.calls(), "ssh dst: bash -c 'set -euo pipefail\n'\\''zstd -d") && !strings.Contains(r.calls(), "zstd -d -q -c | tar") {
		t.Fatalf("copy step never ran; test is vacuous:\n%s", r.calls())
	}
	if _, err := os.Stat(filepath.Join(r.root, "svc/data/b")); err != nil {
		t.Fatalf("source data was touched: %v", err)
	}
	if m, _ := filepath.Glob(filepath.Join(r.root, "svc.moved-*")); len(m) > 0 {
		t.Fatalf("source was retired: %v", m)
	}
	s := inv.Services["svc"]
	c := r.calls()
	for what, marker := range map[string]string{
		"deploy on target":  firstLine(prepareScript(s, "dst")),
		"uninstall on src":  firstLine(uninstallScript(s)),
		"cleanup on source": firstLine(cleanupScript(s)),
	} {
		if marker != "" && strings.Contains(c, marker) {
			t.Fatalf("move ran %s after a failed copy (%q):\n%s", what, marker, c)
		}
	}
}

func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "set ") {
			// the log holds the shell-quoted script; stop before any quote
			if i := strings.IndexAny(l, "'\""); i > 0 {
				l = l[:i]
			}
			return l
		}
	}
	return ""
}

func runMove(t *testing.T) error {
	return cmdMove([]string{"svc", "--to", "dst", "--from", "src"})
}

func TestMoveStopsOnSourceReadError(t *testing.T) {
	r := newRig(t)
	r.breakTool("src", "tar", "#!/bin/sh\n"+realPath(t, "tar")+" \"$@\" | head -c 2000\nexit 2\n")
	if err := runMove(t); err == nil {
		t.Fatal("move succeeded with a failing source tar")
	}
	assertSourceKept(t, r)
}

func TestMoveStopsOnCompressionError(t *testing.T) {
	r := newRig(t)
	r.breakTool("src", "zstd", "#!/bin/sh\nhead -c 10 >/dev/null; exit 1\n")
	if err := runMove(t); err == nil {
		t.Fatal("move succeeded with a failing compressor")
	}
	assertSourceKept(t, r)
}

func TestMoveStopsOnExtractionError(t *testing.T) {
	r := newRig(t)
	r.breakTool("dst", "tar", "#!/bin/sh\ncat >/dev/null\necho 'tar: No space left on device' >&2\nexit 2\n")
	if err := runMove(t); err == nil {
		t.Fatal("move succeeded with a failing extract")
	}
	assertSourceKept(t, r)
}

// Extraction that "succeeds" but drops a file is caught by the manifest.
func TestMoveStopsOnSilentlyIncompleteCopy(t *testing.T) {
	r := newRig(t)
	r.breakTool("dst", "tar", "#!/bin/sh\n"+realPath(t, "tar")+" \"$@\" && rm -f "+r.dst+"/svc/data/b\n")
	if err := runMove(t); err == nil {
		t.Fatal("move succeeded although a file went missing")
	}
	assertSourceKept(t, r)
}

// Positive control: with a good copy, move verifies and proceeds to deploy,
// so the markers used by assertSourceKept really do appear in the log.
func TestMoveProceedsAfterGoodCopy(t *testing.T) {
	r := newRig(t)
	t.Log(runMove(t)) // deploy itself fails (no nix on the fake host); fine
	marker := firstLine(prepareScript(inv.Services["svc"], "dst"))
	if !strings.Contains(r.calls(), marker) {
		t.Fatalf("expected deploy marker %q after a good copy:\n%s", marker, r.calls())
	}
	got, err := os.ReadFile(filepath.Join(r.dst, "svc/data/b"))
	must(t, err)
	if len(got) != 100000 {
		t.Fatalf("copy incomplete: %d bytes", len(got))
	}
}
