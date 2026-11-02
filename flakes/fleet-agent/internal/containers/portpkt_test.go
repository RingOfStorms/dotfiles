package containers

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// pktHelperEnv turns the test binary into the listener or client of
// TestPortForwardPackets ("listen <addr>" / "dial <addr>"), run inside its
// namespaces.
const pktHelperEnv = "CNT_PKT_HELPER"

// TestPortPktHelper is that listener/client; a normal run skips it.
func TestPortPktHelper(t *testing.T) {
	mode, addr, ok := strings.Cut(os.Getenv(pktHelperEnv), " ")
	if !ok {
		t.Skip("helper process of TestPortForwardPackets")
	}
	switch mode {
	case "listen":
		l, err := net.Listen("tcp", addr)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		for {
			c, err := l.Accept()
			if err != nil {
				os.Exit(2)
			}
			c.Write([]byte("ok\n"))
			c.Close()
		}
	case "dial":
		// Dropped SYNs never answer: a short timeout is a refusal.
		c, err := net.DialTimeout("tcp", addr, 800*time.Millisecond)
		if err != nil {
			fmt.Println("dial:", err)
			os.Exit(1)
		}
		c.SetDeadline(time.Now().Add(time.Second))
		if l, err := bufio.NewReader(c).ReadString('\n'); l != "ok\n" {
			fmt.Printf("read %q: %v\n", l, err)
			os.Exit(1)
		}
		fmt.Println("connected")
		os.Exit(0)
	}
	os.Exit(2)
}

// `cnt port open` on a net.private NixOS guest, packet by packet. Three
// network namespaces: client (192.0.2.2) --vc-- host (192.0.2.1)
// --ve-a/eth0-- guest (10.233.15.2, as nixos-containers sets it up). The
// guest loads the real cnt-guest.nft into a nixos-fw shaped table (policy
// drop, lo and established, one declared port, lib.nix's extraInputRules
// `jump cnt-guest-input`). A listener on the undeclared port 8000 must be
// unreachable from the client before open, through a bare host DNAT,
// after close and after a 1s expiry, and reachable while open. The open
// and close scripts run as generated; only the installed check is cut,
// machinectl is a stub that prints the guest's PID, and an nsenter wrapper
// can fail the guest transaction to exercise the undo.
func TestPortForwardPackets(t *testing.T) {
	sh := newNsShell(t)
	for _, b := range []string{"ip", "ss", "grep", "nsenter", "readlink", "sleep"} {
		if _, err := exec.LookPath(b); err != nil {
			t.Skipf("%s not in PATH", b)
		}
	}
	exe, err := os.Executable()
	must(t, err)
	guestNft, err := os.ReadFile("cnt-guest.nft")
	must(t, err)
	shPath, _ := exec.LookPath("sh")
	realNsenter, _ := exec.LookPath("nsenter")
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	must(t, os.Mkdir(bin, 0o755))
	leader := filepath.Join(dir, "leader")
	guestFails := filepath.Join(dir, "guest-fails")
	writeExe(t, filepath.Join(bin, "machinectl"), "#!"+shPath+"\n[ -s "+q(leader)+" ] || { echo 'Could not get path to machine' >&2; exit 1; }\ncat "+q(leader)+"\n")
	writeExe(t, filepath.Join(bin, "nsenter"), "#!"+shPath+"\ncase \"$*\" in *'nft -f -'*) [ ! -e "+q(guestFails)+" ] || exit 1;; esac\nexec "+q(realNsenter)+" \"$@\"\n")
	env := "PATH=" + q(bin) + ":$PATH\n"

	// Two child netns (guest, client), each held by a sleep; wait until
	// unshare has switched it.
	out := sh.run(t, `spawn() {
  unshare -n sleep 600 </dev/null >/dev/null 2>&1 &
  p=$! i=0
  while [ "$(readlink /proc/$p/ns/net)" = "$(readlink /proc/self/ns/net)" ]; do
    i=$((i+1)); [ $i -lt 100 ] || { echo "no netns for $p" >&2; exit 1; }
    sleep 0.05
  done
  echo $p
}
set -e
g=$(spawn); c=$(spawn); echo "$g $c"`)
	var pids []int
	t.Cleanup(func() {
		for _, p := range pids {
			syscall.Kill(p, syscall.SIGKILL)
		}
	})
	for _, f := range strings.Fields(out) {
		p, err := strconv.Atoi(f)
		if err != nil {
			t.Fatalf("spawn: %q", out)
		}
		pids = append(pids, p)
	}
	if len(pids) != 2 {
		t.Fatalf("spawn: %q", out)
	}
	g, c := pids[0], pids[1]

	// The host's nixos-fw sets (portLsScript lists them), the links, and
	// the guest firewall.
	sh.run(t, fmt.Sprintf(`set -eu
nft -f - <<'EOF'
table inet nixos-fw {
  set cnt-tmp { type ifname . inet_proto . inet_service; flags timeout; }
  set cnt-tmp4 { type ifname . inet_proto . inet_service . ipv4_addr; flags interval,timeout; }
  set cnt-tmp6 { type ifname . inet_proto . inet_service . ipv6_addr; flags interval,timeout; }
}
EOF
ip link set lo up
ip link add ve-a type veth peer name eth0 netns %[1]d
ip link add vc type veth peer name eth0 netns %[2]d
ip addr add 10.233.0.1/32 dev ve-a
ip link set ve-a up
ip route add 10.233.15.2 dev ve-a
ip addr add 192.0.2.1/24 dev vc
ip link set vc up
echo 1 > /proc/sys/net/ipv4/ip_forward
nsenter -t %[1]d -n sh -euc 'ip link set lo up; ip link set eth0 up; ip addr add 10.233.15.2/32 dev eth0; ip route add 10.233.0.1 dev eth0; ip route add default via 10.233.0.1 dev eth0'
nsenter -t %[2]d -n sh -euc 'ip link set lo up; ip link set eth0 up; ip addr add 192.0.2.2/24 dev eth0; ip route add default via 192.0.2.1'
nsenter -t %[1]d -n nft -f - <<'EOF'
table inet nixos-fw {
%[3]s
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state vmap { invalid : drop, established : accept, related : accept, new : jump input-allow, untracked : jump input-allow }
  }
  chain input-allow {
    tcp dport 25565 accept comment "a declared route port"
    jump cnt-guest-input
  }
}
EOF`, g, c, guestNft))

	helper := func(ns int, arg string) string {
		return fmt.Sprintf("%s=%s nsenter -t %d -n %s -test.run='^TestPortPktHelper$'", pktHelperEnv, q(arg), ns, q(exe))
	}
	out = sh.run(t, helper(g, "listen 0.0.0.0:8000")+" </dev/null >/dev/null 2>&1 &\necho $!")
	lp, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil {
		t.Fatalf("listener: %q", out)
	}
	pids = append(pids, lp)
	// Ready once the guest's own loopback (always accepted) connects.
	sh.run(t, "i=0; until "+helper(g, "dial 127.0.0.1:8000")+" >/dev/null; do i=$((i+1)); [ $i -lt 50 ] || exit 1; sleep 0.1; done")

	reach := func() bool {
		out, rc := sh.runRC(t, helper(c, "dial 192.0.2.1:8000"))
		if (rc == "0") != strings.Contains(out, "connected") {
			t.Fatalf("client: rc %s: %s", rc, out)
		}
		return rc == "0"
	}
	setLeader := func(pid string) { must(t, os.WriteFile(leader, []byte(pid), 0o644)) }
	listMap := func() string { return sh.run(t, "nft list map ip cnt-port cnt-fwd-any") }
	guestSetList := func() string {
		return sh.run(t, fmt.Sprintf("nsenter -t %d -n nft list set inet nixos-fw cnt-guest", g))
	}

	s := privSvc("puzzles", 15)
	open := func(d time.Duration) (string, string) {
		sc := portForwardScript(s, portReq{Svc: "puzzles", Port: 8000, Proto: "tcp", For: d, Iface: "any"}, d)
		pre := "set -eu\n" + installedCheck(s)
		if !strings.HasPrefix(sc, pre) {
			t.Fatalf("unexpected script:\n%s", sc)
		}
		return sh.runRC(t, "set -eu\n"+env+cutAt(t, sc[len(pre):], "logger -t"))
	}

	if reach() {
		t.Fatal("reachable before open")
	}
	// The bug this guards: the host DNAT alone ends at the guest firewall.
	host := portForwardScript(s, portReq{Svc: "puzzles", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "any"}, time.Hour)
	sh.run(t, "IFACE=any\n"+cutAt(t, host[strings.Index(host, "nft list table ip cnt-port"):], "if ! nsenter"))
	if !strings.Contains(listMap(), "tcp . 8000") {
		t.Fatalf("no host forward:\n%s", listMap())
	}
	if reach() {
		t.Fatal("a bare host forward got through the guest firewall")
	}
	sh.run(t, "nft delete element ip cnt-port cnt-fwd-any '{ tcp . 8000 }'")

	// Refusals leave the host untouched.
	for _, tc := range []struct{ leader, want string }{
		{"", "puzzles is not running on this host"},
		{strconv.Itoa(c), "its guest firewall has no set inet nixos-fw cnt-guest"}, // a netns without it
	} {
		setLeader(tc.leader)
		if out, rc := open(time.Hour); rc == "0" || !strings.Contains(out, tc.want) {
			t.Errorf("leader %q: rc %s, want %q in:\n%s", tc.leader, rc, tc.want, out)
		}
		if m := listMap(); strings.Contains(m, "tcp . 8000") {
			t.Errorf("leader %q: host forward added:\n%s", tc.leader, m)
		}
	}
	// A failing guest transaction removes the forward it just added.
	setLeader(strconv.Itoa(g))
	must(t, os.WriteFile(guestFails, nil, 0o644))
	if out, rc := open(time.Hour); rc == "0" || !strings.Contains(out, "removed the host forward again") {
		t.Errorf("guest failure: rc %s:\n%s", rc, out)
	}
	if m := listMap(); strings.Contains(m, "tcp . 8000") {
		t.Errorf("guest failure: host forward left:\n%s", m)
	}
	must(t, os.Remove(guestFails))

	// open, then close.
	if out, rc := open(time.Hour); rc != "0" {
		t.Fatalf("open: rc %s:\n%s", rc, out)
	}
	if gs := guestSetList(); !strings.Contains(gs, "tcp . 8000") || !strings.Contains(gs, `comment "svc=puzzles"`) {
		t.Errorf("guest element:\n%s", gs)
	}
	if !reach() {
		t.Fatal("unreachable while open")
	}
	r := portReq{Svc: "puzzles", Port: 8000, Proto: "tcp", Iface: "any"}
	es, err := parseNftSetJSON(sh.run(t, portLsScript))
	must(t, err)
	ts := closeTargets(es, r, anyIface)
	if len(ts) != 1 || !lastForward(es, ts, r) {
		t.Fatalf("close targets: %+v", ts)
	}
	sh.run(t, "set -eu\n"+env+cutAt(t, portCloseScript(s, r, anyIface, ts, true), "logger -t"))
	if gs := guestSetList(); strings.Contains(gs, "tcp . 8000") {
		t.Errorf("guest element after close:\n%s", gs)
	}
	if reach() {
		t.Fatal("reachable after close")
	}

	// open for 1s, then let the kernel expire both elements.
	if out, rc := open(time.Second); rc != "0" {
		t.Fatalf("open 1s: rc %s:\n%s", rc, out)
	}
	if !reach() {
		t.Fatal("unreachable right after a 1s open")
	}
	time.Sleep(2 * time.Second)
	if m, gs := listMap(), guestSetList(); strings.Contains(m, "tcp . 8000") || strings.Contains(gs, "tcp . 8000") {
		t.Errorf("not expired:\n%s\n%s", m, gs)
	}
	if reach() {
		t.Fatal("reachable after expiry")
	}
}
