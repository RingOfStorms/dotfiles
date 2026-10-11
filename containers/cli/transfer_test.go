package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
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
script="${script//test -d \/etc\/systemd-mutable\/system/test -d \/}"
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
		DataRoot:       r.root,
		Services:       map[string]Service{"svc": {Name: "svc", Dir: "svc", Kind: "podman", Host: "src"}},
		Hosts:          map[string]Host{"src": {User: "root"}, "dst": {User: "root"}},
		ContainerHosts: []string{"src", "dst"},
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

// Regression: a source dir enlarged by files that were later deleted keeps a
// larger st_size than its freshly extracted copy. That must not fail the move.
func TestMoveIgnoresDirectorySizeHistory(t *testing.T) {
	r := newRig(t)
	big := filepath.Join(r.root, "svc/data/sub")
	for i := range 2000 {
		must(t, os.WriteFile(filepath.Join(big, "tmp-"+strings.Repeat("x", 40)+string(rune('a'+i%26))+itoa(i)), nil, 0o644))
	}
	for i := range 2000 {
		must(t, os.Remove(filepath.Join(big, "tmp-"+strings.Repeat("x", 40)+string(rune('a'+i%26))+itoa(i))))
	}
	st, err := os.Stat(big)
	must(t, err)
	fresh := t.TempDir()
	fst, err := os.Stat(fresh)
	must(t, err)
	if st.Size() == fst.Size() {
		t.Skipf("filesystem does not keep grown directory sizes (%d); regression not exercised", st.Size())
	}
	err = runMove(t)
	if err != nil && strings.Contains(err.Error(), "mismatch") {
		t.Fatalf("copy verification failed on directory size: %v", err)
	}
	marker := firstLine(prepareScript(inv.Services["svc"], "dst"))
	if !strings.Contains(r.calls(), marker) {
		t.Fatalf("move did not reach deploy after a complete copy: %v\n%s", err, r.calls())
	}
}

func itoa(i int) string { return fmt.Sprint(i) }

func TestSSHUserFallback(t *testing.T) {
	defer func(u string, i *Inventory) { sshUser, inv = u, i }(sshUser, inv)
	inv = &Inventory{Hosts: map[string]Host{"h003": {User: "luser"}}}
	sshUser = ""
	a := sshArgs("h003", false, "true", true)
	if !slices.Contains(a, "luser@h003") || !strings.HasPrefix(a[len(a)-1], "sudo -n ") {
		t.Fatalf("fleet user not used: %v", a)
	}
	if a := sshArgs("other", false, "true", false); !slices.Contains(a, "other") {
		t.Fatalf("unknown host should use ssh default user: %v", a)
	}
	sshUser = "root"
	a = sshArgs("h003", false, "true", true)
	if !slices.Contains(a, "root@h003") || strings.HasPrefix(a[len(a)-1], "sudo") {
		t.Fatalf("--ssh-user must override fleet user: %v", a)
	}
}

// Discovery must find services that are installed but stopped, disabled and
// no longer loaded in systemd (so absent from `list-units --all`).
func TestProbeFindsInstalledButUnloaded(t *testing.T) {
	r := newRig(t)
	root := t.TempDir()
	must(t, os.MkdirAll(root+"/etc/systemd-mutable/system", 0o755))
	must(t, os.MkdirAll(root+"/nix/var/nix/gcroots/fleet-containers", 0o755))
	must(t, os.WriteFile(root+"/etc/systemd-mutable/system/container@mc.service", nil, 0o644))
	must(t, os.WriteFile(root+"/etc/systemd-mutable/system/container@.service", nil, 0o644))
	must(t, os.Symlink(root, root+"/nix/var/nix/gcroots/fleet-containers/web"))
	// systemctl knows nothing: list-units prints only an unrelated helper,
	// show prints nothing (as for an unloaded unit).
	writeExe(t, filepath.Join(r.bin, "systemctl"), "#!/bin/sh\ncase \"$1\" in list-units) echo 'fleet-containers-ports.service loaded active exited x';; esac\nexit 0\n")
	t.Setenv("CONTAINERS_PROBE_ROOT", root)
	rows, err := probe(context.Background(), "src")
	must(t, err)
	got := map[string]string{}
	for _, x := range rows {
		got[x.svc] = x.kind + "/" + x.state
	}
	want := map[string]string{"mc": "nixos/inactive", "web": "podman/inactive"}
	if !maps.Equal(got, want) {
		t.Fatalf("probe = %v, want %v", got, want)
	}
}

// fakeFleet is a probe over an in-memory fleet: host -> installed services.
// Hosts listed in down return an error, as an ssh failure would.
func fakeFleet(installed map[string][]string, down ...string) func(context.Context, string) ([]row, error) {
	return func(_ context.Context, h string) ([]row, error) {
		if slices.Contains(down, h) {
			return nil, errors.New("ssh: connect to host " + h + ": No route to host")
		}
		var rows []row
		for _, n := range installed[h] {
			rows = append(rows, row{host: h, svc: n, state: "inactive"})
		}
		return rows, nil
	}
}

func TestPlacementThroughLocate(t *testing.T) {
	s := Service{Name: "mc", Dir: "mc", Host: "h003"}
	inv = &Inventory{
		Services:       map[string]Service{"mc": s},
		ContainerHosts: []string{"h001", "h003"},
	}
	cases := []struct {
		name      string
		installed map[string][]string
		down      []string
		refuse    string // substring of the error, "" = allowed
	}{
		{"first deploy, all hosts answer", nil, nil, ""},
		{"only on declared host", map[string][]string{"h003": {"mc"}}, nil, ""},
		{"moved, service.nix stale", map[string][]string{"h001": {"mc"}}, nil, `host = "h001"`},
		// The duplicate must be seen even though the declared host has it.
		{"declared host has it and so does another", map[string][]string{"h003": {"mc"}, "h001": {"mc"}}, nil, "h001, h003"},
		// Moved to h001, which is now down: must not reinstall on h003.
		{"moved target unreachable", nil, []string{"h001"}, "h001 did not answer"},
		{"declared has it, other host unreachable", map[string][]string{"h003": {"mc"}}, []string{"h001"}, "h001 did not answer"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := checkPlacement(s, locate(s, fakeFleet(c.installed, c.down...)))
			switch {
			case c.refuse == "" && err != nil:
				t.Fatalf("refused: %v", err)
			case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
				t.Fatalf("want refusal containing %q, got %v", c.refuse, err)
			}
		})
	}
}

func TestMoveSourceThroughLocate(t *testing.T) {
	s := Service{Name: "mc", Dir: "mc", Host: "h003"}
	inv = &Inventory{Services: map[string]Service{"mc": s}, ContainerHosts: []string{"h001", "h003", "lio"}}
	if from, err := moveSource(s, locate(s, fakeFleet(map[string][]string{"h001": {"mc"}}))); err != nil || from != "h001" {
		t.Errorf("source should be where it is installed: %q %v", from, err)
	}
	if _, err := moveSource(s, locate(s, fakeFleet(map[string][]string{"h003": {"mc"}}, "lio"))); err == nil {
		t.Error("must refuse when a host is unreachable")
	}
	if _, err := moveSource(s, locate(s, fakeFleet(map[string][]string{"h003": {"mc"}, "lio": {"mc"}}))); err == nil {
		t.Error("must refuse when installed on several hosts")
	}
}

func TestMoveWarning(t *testing.T) {
	s := Service{Name: "mc", Dir: "mc", Host: "h003"}
	if w := moveWarning(s, "h001"); !strings.Contains(w, `host = "h001"`) || !strings.Contains(w, "containers/mc/service.nix") {
		t.Errorf("warning lacks the edit to make:\n%s", w)
	}
}

// A rejected update must not lose the last good site: after valid deploy ->
// invalid update -> an unrelated deploy that reloads nginx, the first
// service's route must still be the valid one.
func TestNginxRejectedUpdateKeepsLastGoodSite(t *testing.T) {
	bash := realPath(t, "bash")
	dir, bin := t.TempDir(), t.TempDir()
	log := filepath.Join(bin, "reloads")
	// nginx -t fails if any loaded site contains BAD; reload records which
	// sites nginx would serve now.
	writeExe(t, filepath.Join(bin, "nginx"), "#!"+bash+"\n! grep -l BAD "+dir+"/*.conf\n")
	writeExe(t, filepath.Join(bin, "systemctl"), "#!"+bash+"\ncat "+dir+"/*.conf >> "+log+"; echo --- >> "+log+"\n")
	run := func(name, conf string) error {
		c := exec.Command(bash, "-c", "set -euo pipefail\n"+nginxSiteScript(dir, name, conf))
		c.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
		out, err := c.CombinedOutput()
		t.Logf("%s: %s", name, out)
		return err
	}
	must(t, run("mc", "server { good; }"))
	if err := run("mc", "server { BAD; }"); err == nil {
		t.Fatal("invalid site was accepted")
	}
	must(t, run("other", "server { other; }"))

	got, err := os.ReadFile(filepath.Join(dir, "mc.conf"))
	must(t, err)
	if !strings.Contains(string(got), "good") {
		t.Fatalf("mc.conf after rejected update = %q, want the last good site", got)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "mc.conf.broken")); !strings.Contains(string(b), "BAD") {
		t.Errorf("rejected site not kept as .broken: %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "mc.conf.prev")); err == nil {
		t.Error("mc.conf.prev left behind")
	}
	reloads, _ := os.ReadFile(log)
	last := strings.Split(strings.TrimSuffix(string(reloads), "---\n"), "---\n")
	if final := last[len(last)-1]; !strings.Contains(final, "good") || !strings.Contains(final, "other") {
		t.Errorf("last reload served %q, want both the good mc site and other", final)
	}
}

func TestStatusColumnsAlign(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	for _, s := range []string{"STATE", "active", "inactive", "failed", "not installed"} {
		if n := len(colorState(s)) - len(s); n != 9 {
			t.Errorf("colorState(%q) adds %d bytes, want 9 for every cell", s, n)
		}
	}
}

func TestHostCmdLocal(t *testing.T) {
	old := localHost
	t.Cleanup(func() { localHost = old })
	localHost = "h003"
	if c := hostCmd(context.Background(), "h003", false, false, "echo hi"); filepath.Base(c.Path) != "bash" || c.Args[len(c.Args)-1] != "echo hi" {
		t.Errorf("local host should run bash directly, got %v", c.Args)
	}
	if c := hostCmd(context.Background(), "h003", false, true, "id"); os.Geteuid() != 0 && filepath.Base(c.Path) != "sudo" {
		t.Errorf("local root as non-root should use sudo, got %v", c.Args)
	}
	if c := hostCmd(context.Background(), "lio", false, false, "x"); filepath.Base(c.Path) != "ssh" {
		t.Errorf("other host should use ssh, got %v", c.Args)
	}
}

// stop must drop the boot-time wants link (stays stopped after reboot);
// start must restore it, but only for an installed unit.
func TestStopStaysStoppedAcrossReboot(t *testing.T) {
	old := mutableUnits
	t.Cleanup(func() { mutableUnits = old })
	mutableUnits = t.TempDir()
	bash := realPath(t, "bash")
	sh := func(script string) {
		out, err := exec.Command(bash, "-c", "set -euo pipefail\n"+script).CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	for _, s := range []Service{{Name: "mc", Kind: "nixos"}, {Name: "web", Kind: "podman"}} {
		link := wantsLink(s)
		sh(enableScript(s)) // not installed: must not create a dangling link
		if _, err := os.Lstat(link); err == nil {
			t.Fatalf("%s: enable created a link for an uninstalled unit", s.Name)
		}
		must(t, os.WriteFile(filepath.Join(mutableUnits, unitOf(s)), nil, 0o644))
		sh(enableScript(s))
		if dst, err := os.Readlink(link); err != nil || dst != "../"+unitOf(s) {
			t.Fatalf("%s: start did not enable boot start: %q %v", s.Name, dst, err)
		}
		sh(disableScript(s))
		if _, err := os.Lstat(link); err == nil {
			t.Fatalf("%s: stop left boot start enabled", s.Name)
		}
		sh(disableScript(s)) // idempotent
	}
}

// stop -> deploy of the same build must re-enable boot start. The fake
// extra-container mimics the pinned one: it links the unit and wants only
// when the build changed, but always starts.
func TestRedeployUnchangedReenablesBootStart(t *testing.T) {
	old := mutableUnits
	t.Cleanup(func() { mutableUnits = old })
	mutableUnits = t.TempDir()
	bash := realPath(t, "bash")
	bin, out := t.TempDir(), t.TempDir()
	s := Service{Name: "hello-nixos", Kind: "nixos"}
	u := unitOf(s)
	must(t, os.MkdirAll(filepath.Join(out, "bin"), 0o755))
	writeExe(t, filepath.Join(out, "bin", "container"), "#!"+bash+`
m=`+mutableUnits+`
if [ "$(cat $m/.built 2>/dev/null)" != v1 ]; then
  mkdir -p $m/machines.target.wants
  : > $m/real.unit; ln -sfn $m/real.unit $m/`+u+`
  ln -sfn ../`+u+` $m/machines.target.wants/`+u+`
  echo v1 > $m/.built
fi
`)
	writeExe(t, filepath.Join(bin, "systemctl"), "#!/bin/sh\nexit 0\n")
	sh := func(script string) {
		c := exec.Command(bash, "-c", "set -euo pipefail\nout="+q(out)+"\n"+script)
		c.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
		if o, err := c.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, o)
		}
	}
	sh(installScript(s)) // first deploy
	sh(disableScript(s)) // cnt stop
	sh(installScript(s)) // redeploy, same build: extra-container relinks nothing
	if _, err := os.Lstat(wantsLink(s)); err != nil {
		t.Fatalf("redeploy of an unchanged build left boot start disabled: %v", err)
	}
}

func TestBackupDestDefaultsToHomeBackups(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	got, err := backupDest("", "svc.tar.zst", true)
	if err != nil || got != filepath.Join(home, "backups", "svc.tar.zst") {
		t.Fatalf("default: %q %v", got, err)
	}
	if st, err := os.Stat(filepath.Join(home, "backups")); err != nil || !st.IsDir() {
		t.Fatalf("~/backups not created: %v", err)
	}
	got, _ = backupDest("~/x/", "svc.tar.zst", true)
	if got != filepath.Join(home, "x", "svc.tar.zst") {
		t.Fatalf("-o dir: %q", got)
	}
	got, _ = backupDest(filepath.Join(home, "y", "f.tar.zst"), "svc.tar.zst", true)
	if got != filepath.Join(home, "y", "f.tar.zst") {
		t.Fatalf("-o file: %q", got)
	}
}

// status <svc>: run the real detail script against a fake host tree.
func TestStatusDetail(t *testing.T) {
	bash := realPath(t, "bash")
	d := t.TempDir()
	oldM, oldN, oldInv := mutableUnits, nginxDir, inv
	t.Cleanup(func() { mutableUnits, nginxDir, inv = oldM, oldN, oldInv })
	mutableUnits, nginxDir = d+"/units", d+"/nginx"
	inv = &Inventory{DataRoot: d + "/srv"}
	s := Service{Name: "hello-podman", Kind: "podman", Description: "test", Host: "lio",
		Persist: map[string]string{"data": "/data", "gone": "/x"}, TCPPorts: []int{8082}}
	for _, p := range []string{mutableUnits + "/multi-user.target.wants", nginxDir, d + "/srv/hello-podman/data"} {
		must(t, os.MkdirAll(p, 0o755))
	}
	must(t, os.WriteFile(mutableUnits+"/"+unitOf(s), nil, 0o644))
	must(t, os.WriteFile(nginxDir+"/hello-podman.conf", []byte("server { listen 1.2.3.4:80; }\n"), 0o644))
	must(t, os.WriteFile(d+"/srv/hello-podman/data/f", []byte("hello"), 0o644))
	bin := t.TempDir()
	writeExe(t, filepath.Join(bin, "systemctl"), "#!/bin/sh\ncase \"$3\" in ActiveState) echo active;; SubState) echo running;; MemoryCurrent) echo 1048576;; NRestarts) echo 0;; esac\n")
	script := strings.ReplaceAll(detailScript(s), "/var/lib/fleet-containers/ports", d)
	must(t, os.WriteFile(d+"/hello-podman", []byte("tcp 8082\n"), 0o644))
	c := exec.Command(bash, "-c", script)
	c.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	r := renderDetail(s, "lio", string(out))
	for _, want := range []string{"state       active (running)", "on boot     no", "8082/tcp", "listen 1.2.3.4:80", "data        /data", "missing"} {
		if !strings.Contains(strings.Join(strings.Fields(r), " "), strings.Join(strings.Fields(want), " ")) {
			t.Errorf("missing %q in:\n%s", want, r)
		}
	}
}
