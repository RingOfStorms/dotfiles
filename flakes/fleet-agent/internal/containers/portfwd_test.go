package containers

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fwdTestDir(t *testing.T) {
	t.Helper()
	old := portFwdDir
	portFwdDir = filepath.Join(t.TempDir(), "port-fwd")
	t.Cleanup(func() { portFwdDir = old })
}

func runSh(t *testing.T, script string, env ...string) {
	t.Helper()
	c := exec.Command("sh", "-c", script)
	c.Env = append(os.Environ(), env...)
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("script failed: %v\n%s\n--- script:\n%s", err, out, script)
	}
}

func readFwdState(t *testing.T, svc string) []fwdRec {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(portFwdDir, svc))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return parseFwdState(string(b))
}

func fwdSvc(name, kind, ip string) Service {
	return Service{Name: name, Kind: kind, Net: Net{Private: true, IP: &ip}}
}

// Open records its forward elements, a re-open replaces them, close drops
// exactly the closed ones, expired lines are pruned and an empty file goes.
func TestFwdStateOpenClose(t *testing.T) {
	fwdTestDir(t)
	s := fwdSvc("app", "nixos", "10.233.5.2")
	r := portReq{Svc: "app", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "tailnet"}
	runSh(t, "set -eu\n"+fwdStateAddScript(s, r), "IFACE=tailscale0")
	es := readFwdState(t, "app")
	now := time.Now().Unix()
	if len(es) != 1 || es[0].Map != "cnt-fwd" || es[0].Iface != "tailscale0" || es[0].From != "all" || es[0].Guest != "10.233.5.2" || !es[0].GuestFW || es[0].Until < now+3590 || es[0].Until > now+3601 {
		t.Fatalf("after open: %+v", es)
	}
	// --from: one cnt-fwd4 line per source (normalized like nft prints it).
	r2 := r
	r2.From = []string{"100.64.0.1/32", "10.12.14.0/24"}
	runSh(t, "set -eu\n"+fwdStateAddScript(s, r2), "IFACE=tailscale0")
	// Re-open of the plain forward for longer: replaced, not duplicated.
	r.For = 2 * time.Hour
	runSh(t, "set -eu\n"+fwdStateAddScript(s, r), "IFACE=tailscale0")
	// An expired line is pruned by the next write.
	f, _ := os.OpenFile(filepath.Join(portFwdDir, "app"), os.O_APPEND|os.O_WRONLY, 0o644)
	fmt.Fprintf(f, "%d cnt-fwd tailscale0 udp 9 all 10.233.5.2 1\n", now-5)
	f.Close()
	r3 := portReq{Svc: "app", Port: 9000, Proto: "udp", For: time.Minute, Iface: "any"}
	runSh(t, "set -eu\n"+fwdStateAddScript(s, r3), "IFACE=any")
	es = readFwdState(t, "app")
	var got []string
	for _, e := range es {
		got = append(got, fwdStateID(e.Map, e.Iface, e.Proto, e.Port, e.From))
		if e.Map == "cnt-fwd" && e.Until < now+7190 {
			t.Errorf("re-open did not extend: %+v", e)
		}
	}
	want := "cnt-fwd4 tailscale0 tcp 8000 100.64.0.1|cnt-fwd4 tailscale0 tcp 8000 10.12.14.0/24|cnt-fwd tailscale0 tcp 8000 all|cnt-fwd-any any udp 9000 all"
	if strings.Join(got, "|") != want {
		t.Fatalf("state:\n got %s\nwant %s", strings.Join(got, "|"), want)
	}
	// Close of one --from source (live entry as parsed from nft -j: no /32),
	// the whole close script with nft/logger stubbed.
	closeOne := []portEntry{{Set: "cnt-fwd4", Iface: "tailscale0", Proto: "tcp", Port: "8000", From: "100.64.0.1"}}
	sc := portCloseScript(s, portReq{Svc: "app", Port: 8000, Proto: "tcp"}, "tailscale0", closeOne, false)
	runSh(t, sc, "PATH="+stubBin(t)+":"+os.Getenv("PATH"))
	if es = readFwdState(t, "app"); len(es) != 3 {
		t.Fatalf("after closing one source: %+v", es)
	}
	// Close everything: the file goes.
	var drop []string
	for _, e := range es {
		drop = append(drop, q(fwdStateID(e.Map, e.Iface, e.Proto, e.Port, e.From)))
	}
	runSh(t, "set -eu\n"+fwdStateRewriteScript("app", drop, ""))
	if _, err := os.Stat(filepath.Join(portFwdDir, "app")); !os.IsNotExist(err) {
		t.Fatal("empty state file kept")
	}
	// Closing only host ports (cnt-tmp) leaves the forward state alone.
	if sc := portCloseScript(s, portReq{Svc: "app", Port: 8000, Proto: "tcp"}, "tailscale0", []portEntry{{Set: "cnt-tmp", Iface: "tailscale0", Proto: "tcp", Port: "8000", From: "all"}}, false); strings.Contains(sc, "port-fwd") {
		t.Fatalf("host-port close touches forward state:\n%s", sc)
	}
}

// The open records state only after the forward and the guest element are
// in place (a failed guest element removes the forward and exits first).
func TestPortForwardScriptRecordsState(t *testing.T) {
	fwdTestDir(t)
	s := fwdSvc("app", "nixos", "10.233.5.2")
	sc := portForwardScript(s, portReq{Svc: "app", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "tailnet"}, time.Hour)
	guest, state := strings.Index(sc, "removed the host forward again"), strings.Index(sc, q(portFwdDir+"/app"))
	if guest < 0 || state < guest {
		t.Fatalf("state must be written after the guest step:\n%s", sc)
	}
	if !strings.Contains(sc, `echo "$((now + 3600)) cnt-fwd $IFACE tcp 8000 all 10.233.5.2 1"`) {
		t.Fatalf("state line:\n%s", sc)
	}
	p := fwdSvc("gist", "podman", "10.89.250.102")
	if sc := portForwardScript(p, portReq{Svc: "gist", Port: 22, Proto: "tcp", For: time.Minute, Iface: "lan"}, time.Minute); !strings.Contains(sc, "cnt-fwd $IFACE tcp 22 all 10.89.250.102 0") {
		t.Fatalf("podman state line (no guest firewall):\n%s", sc)
	}
}

type nftCall struct{ leader, script string }

func stubRestore(t *testing.T, tableExists bool, leaders map[string]string) *[]nftCall {
	t.Helper()
	var calls []nftCall
	oR, oT, oM := runNft, fwdTableExists, machineLeader
	runNft = func(l, s string) error { calls = append(calls, nftCall{l, s}); return nil }
	fwdTableExists = func() bool { return tableExists }
	machineLeader = func(svc string) string { return leaders[svc] }
	t.Cleanup(func() { runNft, fwdTableExists, machineLeader = oR, oT, oM })
	return &calls
}

// After a firewall reload (table gone) port-restore loads the table, re-adds
// the live forwards with the time they have left and the guest elements
// (longest left per port), prunes expired lines and skips garbage.
func TestPortRestore(t *testing.T) {
	fwdTestDir(t)
	calls := stubRestore(t, false, map[string]string{"app": "4242"})
	must(t, os.MkdirAll(portFwdDir, 0o755))
	now := time.Now().Unix()
	app := fmt.Sprintf("%d cnt-fwd tailscale0 tcp 8000 all 10.233.5.2 1\n%d cnt-fwd4 eth0 tcp 8000 100.64.0.1 10.233.5.2 1\n%d cnt-fwd tailscale0 udp 53 all 10.233.5.2 1\n%d cnt-fwd tailscale0 tcp 1 all 10.233.5.2; rm -rf / 1\n",
		now+600, now+3600, now-10, now+600)
	must(t, os.WriteFile(filepath.Join(portFwdDir, "app"), []byte(app), 0o644))
	must(t, os.WriteFile(filepath.Join(portFwdDir, "gist"), []byte(fmt.Sprintf("%d cnt-fwd-any any tcp 22 all 10.89.250.102 0\n", now+60)), 0o644))
	must(t, os.WriteFile(filepath.Join(portFwdDir, "gone"), []byte(fmt.Sprintf("%d cnt-fwd tailscale0 tcp 22 all 10.233.9.2 1\n", now-1)), 0o644))
	must(t, cmdPortRestore(nil))
	c := *calls
	if len(c) != 4 || c[0].script != cntPortNft {
		t.Fatalf("want template + app host + app guest + gist host, got %d calls: %+v", len(c), c)
	}
	timeout := regexp.MustCompile(`timeout (\d+)s`)
	secs := func(s string) []int {
		var out []int
		for _, m := range timeout.FindAllStringSubmatch(s, -1) {
			n, _ := strconv.Atoi(m[1])
			out = append(out, n)
		}
		return out
	}
	host := c[1].script
	if c[1].leader != "" || !strings.Contains(host, `add element ip cnt-port cnt-fwd { "tailscale0" . tcp . 8000 timeout `) ||
		!strings.Contains(host, `add element ip cnt-port cnt-fwd4 { "eth0" . tcp . 8000 . 100.64.0.1 timeout `) ||
		strings.Contains(host, "udp . 53") || strings.Contains(host, "rm -rf") || !strings.Contains(host, `comment "svc=app" : 10.233.5.2 }`) {
		t.Fatalf("app host txn:\n%s", host)
	}
	if s := secs(host); len(s) != 2 || s[0] < 590 || s[0] > 600 || s[1] < 3590 || s[1] > 3600 {
		t.Fatalf("app timeouts %v", s)
	}
	guest := c[2].script
	if c[2].leader != "4242" || strings.Count(guest, "add element") != 1 || !strings.Contains(guest, "add element inet nixos-fw cnt-guest { tcp . 8000 timeout ") {
		t.Fatalf("guest txn (leader %q):\n%s", c[2].leader, guest)
	}
	if s := secs(guest); len(s) != 1 || s[0] < 3590 {
		t.Fatalf("guest element must last as long as the longest forward: %v", s)
	}
	if c[3].leader != "" || !strings.Contains(c[3].script, `cnt-fwd-any { tcp . 22 timeout `) {
		t.Fatalf("gist (podman, no guest firewall): %+v", c[3])
	}
	if es := readFwdState(t, "app"); len(es) != 2 {
		t.Fatalf("expired/garbage lines not pruned: %+v", es)
	}
	if _, err := os.Stat(filepath.Join(portFwdDir, "gone")); !os.IsNotExist(err) {
		t.Fatal("all-expired state file kept")
	}
	// Table still there and nothing changed: no template, no rewrite.
	*calls = nil
	fwdTableExists = func() bool { return true }
	before, _ := os.ReadFile(filepath.Join(portFwdDir, "app"))
	must(t, cmdPortRestore(nil))
	after, _ := os.ReadFile(filepath.Join(portFwdDir, "app"))
	if len(*calls) != 3 || (*calls)[0].script == cntPortNft || string(before) != string(after) {
		t.Fatalf("second restore: %+v", *calls)
	}
}

func TestPortRestoreNothingToDo(t *testing.T) {
	fwdTestDir(t)
	calls := stubRestore(t, false, nil)
	must(t, cmdPortRestore(nil))
	if len(*calls) != 0 {
		t.Fatalf("restore without state ran nft: %+v", *calls)
	}
}

// A port-restore during a close must not bring the closed forward back:
// close deletes the elements and drops their state lines in one critical
// section on the lock restore takes. The fake nft deletes, then stalls
// (the window between the delete and the state removal) until released.
func TestPortCloseRestoreRace(t *testing.T) {
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock not available")
	}
	fwdTestDir(t)
	must(t, os.MkdirAll(portFwdDir, 0o755))
	state := filepath.Join(portFwdDir, "gist")
	must(t, os.WriteFile(state, []byte(fmt.Sprintf("%d cnt-fwd enp1s0 tcp 22 all 10.89.250.102 0\n", time.Now().Unix()+3600)), 0o644))
	bin := t.TempDir()
	log, started, release := filepath.Join(bin, "log"), filepath.Join(bin, "started"), filepath.Join(bin, "release")
	must(t, os.WriteFile(filepath.Join(bin, "nft"), []byte(fmt.Sprintf("#!/bin/sh\nsed 's/^/nft: /' >> %s\ntouch %s\nwhile ! [ -e %s ]; do sleep 0.01; done\n",
		q(log), q(started), q(release))), 0o755))
	must(t, os.WriteFile(filepath.Join(bin, "logger"), []byte("#!/bin/sh\nexit 0\n"), 0o755))
	oR, oT, oM := runNft, fwdTableExists, machineLeader
	runNft = func(_, s string) error {
		f, err := os.OpenFile(log, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
		if err != nil {
			return err
		}
		for _, l := range strings.Split(strings.TrimSpace(s), "\n") {
			fmt.Fprintf(f, "restore: %s\n", l)
		}
		return f.Close()
	}
	fwdTableExists = func() bool { return true }
	machineLeader = func(string) string { return "" }
	t.Cleanup(func() { runNft, fwdTableExists, machineLeader = oR, oT, oM })

	s := fwdSvc("gist", "podman", "10.89.250.102")
	sc := portCloseScript(s, portReq{Svc: "gist", Port: 22, Proto: "tcp", Iface: "lan"}, "enp1s0",
		[]portEntry{{Set: "cnt-fwd", Iface: "enp1s0", Proto: "tcp", Port: "22", From: "all"}}, true)
	c := exec.Command("sh", "-c", sc)
	c.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
	var out bytes.Buffer
	c.Stdout, c.Stderr = &out, &out
	must(t, c.Start())
	closed := make(chan error, 1)
	go func() { closed <- c.Wait() }()
	for i := 0; ; i++ {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if i == 1000 {
			c.Process.Kill()
			t.Fatalf("close never reached nft: %v\n%s", <-closed, out.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	restored := make(chan error, 1)
	go func() { restored <- cmdPortRestore(nil) }()
	var rerr error
	done := false
	select {
	case rerr = <-restored:
		done = true
	case <-time.After(300 * time.Millisecond):
	}
	must(t, os.WriteFile(release, nil, 0o644))
	if err := <-closed; err != nil {
		t.Fatalf("close: %v\n%s", err, out.String())
	}
	if !done {
		select {
		case rerr = <-restored:
		case <-time.After(10 * time.Second):
			t.Fatal("restore still blocked after the close finished")
		}
	}
	if rerr != nil {
		t.Fatalf("restore: %v", rerr)
	}
	b, _ := os.ReadFile(log)
	lines := strings.Split(string(b), "\n")
	del := -1
	for i, l := range lines {
		if l == `nft: delete element ip cnt-port cnt-fwd { "enp1s0" . tcp . 22 }` {
			del = i
		}
	}
	if del < 0 {
		t.Fatalf("close did not delete the forward:\n%s", b)
	}
	for _, l := range lines[del+1:] {
		if strings.HasPrefix(l, "restore: ") {
			t.Fatalf("restore re-added the closed forward:\n%s", b)
		}
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatal("state file kept")
	}
}

// A close whose nft delete fails (already expired) still drops the stale
// state line, then reports "not open" and exits 1.
func TestPortCloseFailedDeleteDropsState(t *testing.T) {
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock not available")
	}
	fwdTestDir(t)
	must(t, os.MkdirAll(portFwdDir, 0o755))
	state := filepath.Join(portFwdDir, "gist")
	must(t, os.WriteFile(state, []byte(fmt.Sprintf("%d cnt-fwd enp1s0 tcp 22 all 10.89.250.102 0\n", time.Now().Unix()+3600)), 0o644))
	bin := stubBin(t)
	must(t, os.WriteFile(filepath.Join(bin, "nft"), []byte("#!/bin/sh\ncat >/dev/null\nexit 1\n"), 0o755))
	sc := portCloseScript(fwdSvc("gist", "podman", "10.89.250.102"), portReq{Svc: "gist", Port: 22, Proto: "tcp", Iface: "lan"}, "enp1s0",
		[]portEntry{{Set: "cnt-fwd", Iface: "enp1s0", Proto: "tcp", Port: "22", From: "all"}}, true)
	c := exec.Command("sh", "-c", sc)
	c.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
	out, err := c.CombinedOutput()
	if c.ProcessState.ExitCode() != 1 || !strings.Contains(string(out), "not open (or already expired)") || strings.Contains(string(out), "closed ") {
		t.Fatalf("exit %v:\n%s", err, out)
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatal("stale state line kept")
	}
}

// destroy and the move's source cleanup delete the service's forwards and
// its state, before the nftables restart (port-restore would re-add them).
func TestCleanupDropsForwards(t *testing.T) {
	fwdTestDir(t)
	must(t, os.MkdirAll(portFwdDir, 0o755))
	now := time.Now().Unix()
	must(t, os.WriteFile(filepath.Join(portFwdDir, "app"), []byte(fmt.Sprintf(
		"%d cnt-fwd tailscale0 tcp 8000 all 10.233.5.2 1\n%d cnt-fwd4-any any udp 9000 100.64.0.1 10.233.5.2 1\n", now+60, now+60)), 0o644))
	bin := stubBin(t)
	runSh(t, "set -eu\n"+fwdDropScript("app"), "PATH="+bin+":"+os.Getenv("PATH"))
	b, _ := os.ReadFile(filepath.Join(bin, "log"))
	want := "delete element ip cnt-port cnt-fwd { \"tailscale0\" . tcp . 8000 }\ndelete element ip cnt-port cnt-fwd4-any { udp . 9000 . 100.64.0.1 }\n"
	if string(b) != want {
		t.Fatalf("nft calls:\n%s\nwant:\n%s", b, want)
	}
	if _, err := os.Stat(filepath.Join(portFwdDir, "app")); !os.IsNotExist(err) {
		t.Fatal("state file kept")
	}
	cs := cleanupScript(exposeSvc())
	if d, r := strings.Index(cs, q(portFwdDir+"/"+exposeSvc().Name)), strings.Index(cs, "nftables.service"); d < 0 || d > r {
		t.Fatalf("cleanup must drop forwards before the nftables restart:\n%s", cs)
	}
}

// stubBin is a PATH dir whose nft and logger log their arguments to
// <dir>/log and succeed (nft reads its stdin away).
func stubBin(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	log := filepath.Join(bin, "log")
	must(t, os.WriteFile(filepath.Join(bin, "nft"), []byte("#!/bin/sh\necho \"$*\" >> "+log+"\n[ \"$*\" != '-f -' ] || cat >/dev/null\n"), 0o755))
	must(t, os.WriteFile(filepath.Join(bin, "logger"), []byte("#!/bin/sh\nexit 0\n"), 0o755))
	return bin
}
