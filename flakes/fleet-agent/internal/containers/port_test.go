package containers

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

var portHosts = map[string]Host{
	"lio":  {OverlayIP: sp("100.64.0.1")},
	"h005": {OverlayIP: sp("100.64.0.3"), OverlayIP6: sp("fd7a:115c:a1e0::3")},
	"juni": {LanIP: sp("10.12.14.181")},
}

func TestParsePortArgs(t *testing.T) {
	r, err := parsePortArgs([]string{"mc", "25565/tcp", "--for", "2h", "--from", "lio", "--from=10.0.0.0/8", "--from", "h005", "--host", "h003"}, false, portHosts)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"100.64.0.1/32", "10.0.0.0/8", "100.64.0.3/32", "fd7a:115c:a1e0::3/128"}
	if r.Svc != "mc" || r.Port != 25565 || r.Proto != "tcp" || r.For != 2*time.Hour || r.Iface != "tailnet" || r.Host != "h003" || strings.Join(r.From, " ") != strings.Join(want, " ") {
		t.Errorf("got %+v", r)
	}
	bad := [][]string{
		{"mc", "25565/tcp"},                                // no --for
		{"mc", "25565", "--for", "1h"},                     // no proto
		{"mc", "25565/icmp", "--for", "1h"},                // bad proto
		{"mc", "0/tcp", "--for", "1h"},                     // bad port
		{"mc", "70000/udp", "--for", "1h"},                 // bad port
		{"mc", "1/tcp", "--for", "1h", "--iface", "wan"},   // bad iface
		{"mc", "1/tcp", "--for", "1h", "--from", "nohost"}, // unknown host
		{"mc", "1/tcp", "--for", "1h", "--from", "juni"},   // no overlay ip
		{"mc", "1/tcp", "--for", "1h", "--from", "0.0.0.0/0"},
		{"mc", "1/tcp", "--for", "1h", "--from"},
		{"mc", "--for", "1h"},
	}
	for _, a := range bad {
		if _, err := parsePortArgs(a, false, portHosts); err == nil {
			t.Errorf("%v: expected error", a)
		}
	}
	if r, err := parsePortArgs([]string{"mc", "9/udp", "--iface", "lan", "--from", "1.2.3.4"}, true, portHosts); err != nil || r.Iface != "lan" || r.From[0] != "1.2.3.4/32" {
		t.Errorf("close: %+v %v", r, err)
	}
	if _, err := parsePortArgs([]string{"mc", "9/udp", "--for", "1h"}, true, portHosts); err == nil {
		t.Error("close with --for should fail")
	}
}

func TestParseForCap(t *testing.T) {
	for in, ok := range map[string]bool{"24h": true, "1s": true, "90m": true, "24h1s": false, "48h": false, "": false, "500ms": false, "1d": false, "-1h": false} {
		_, err := parseFor(in)
		if (err == nil) != ok {
			t.Errorf("parseFor(%q) err=%v want ok=%v", in, err, ok)
		}
	}
}

func TestPortOpenScriptCombos(t *testing.T) {
	s := Service{Name: "mc", Kind: "nixos"}
	cases := []struct {
		iface string
		from  []string
		want  []string
		not   []string
	}{
		{"tailnet", nil, []string{"IFACE=tailscale0", `add element inet nixos-fw cnt-tmp { "$IFACE" . tcp . 8000 timeout 3600s comment "svc=mc" }`}, []string{"cnt-tmp4", "cnt-tmp6"}},
		{"any", nil, []string{"IFACE=any\n", `cnt-tmp { "$IFACE" . tcp . 8000 timeout`}, nil},
		{"lan", nil, []string{"IFACE=$(cat /etc/fleet-containers/lan-interface", "lanInterface set"}, nil},
		{"tailnet", []string{"100.64.0.1/32", "fd7a:115c:a1e0::3/128"}, []string{
			`add element inet nixos-fw cnt-tmp4 { "$IFACE" . tcp . 8000 . 100.64.0.1/32 timeout 3600s comment "svc=mc" }`,
			`delete element inet nixos-fw cnt-tmp4 { "$IFACE" . tcp . 8000 . 100.64.0.1/32 }`,
			`add element inet nixos-fw cnt-tmp6 { "$IFACE" . tcp . 8000 . fd7a:115c:a1e0::3/128 timeout 3600s`,
		}, []string{"cnt-tmp {"}},
		{"lan", []string{"10.0.0.0/8"}, []string{"lan-interface", `cnt-tmp4 { "$IFACE" . tcp . 8000 . 10.0.0.0/8`}, nil},
		{"any", []string{"10.0.0.0/8"}, []string{"IFACE=any", "cnt-tmp4"}, nil},
	}
	for _, c := range cases {
		r := portReq{Svc: "mc", Port: 8000, Proto: "tcp", For: time.Hour, Iface: c.iface, From: c.from}
		sc := portOpenScript(s, r)
		for _, w := range append(c.want, "logger -t cnt-port", "/etc/systemd-mutable/system/container@mc.service", "already open (declared)", "ss -lnH -t 'sport = :8000'") {
			if !strings.Contains(sc, w) {
				t.Errorf("%s %v: missing %q in\n%s", c.iface, c.from, w, sc)
			}
		}
		for _, n := range c.not {
			if strings.Contains(sc, n) {
				t.Errorf("%s %v: unexpected %q", c.iface, c.from, n)
			}
		}
	}
}

func TestPortGuards(t *testing.T) {
	bindServices(t, map[string]string{"sec": "h001", "mc": "h001"})
	svcs := map[string]Service{
		"sec": {Name: "sec", Routes: map[string]Route{"web": httpRoute("secrets", 8300, "public", "native-oidc")}},
		"mc":  {Name: "mc", TCPPorts: []int{25565}, Routes: map[string]Route{"q": {Port: 25566, Proto: "udp", Exposure: "tailnet"}}},
	}
	mc := svcs["mc"]
	if _, err := portGuards(mc, portReq{Port: 8300, Proto: "tcp"}, "h001", svcs); err == nil || !strings.Contains(err.Error(), "sec.web") {
		t.Errorf("backend guard: %v", err)
	}
	if m, err := portGuards(mc, portReq{Port: 8300, Proto: "tcp", Force: true}, "h001", svcs); err != nil || m != "" {
		t.Errorf("force: %q %v", m, err)
	}
	if _, err := portGuards(mc, portReq{Port: 8300, Proto: "tcp"}, "h003", svcs); err != nil {
		t.Errorf("other host is not a backend: %v", err)
	}
	if _, err := portGuards(mc, portReq{Port: 8300, Proto: "udp"}, "h001", svcs); err != nil {
		t.Errorf("udp is not an http backend: %v", err)
	}
	for _, r := range []portReq{{Port: 25565, Proto: "tcp"}, {Port: 25566, Proto: "udp"}} {
		if m, err := portGuards(mc, r, "h001", svcs); err != nil || !strings.Contains(m, "already open (declared)") {
			t.Errorf("declared %+v: %q %v", r, m, err)
		}
	}
	if m, _ := portGuards(mc, portReq{Port: 25565, Proto: "udp"}, "h001", svcs); m != "" {
		t.Errorf("udp/25565 is not declared: %q", m)
	}
	if m, err := portGuards(mc, portReq{Port: 8300, Proto: "tcp", Closer: true}, "h001", svcs); m != "" || err != nil {
		t.Errorf("close skips guards: %q %v", m, err)
	}
	// service must be on the host: checked on the host itself
	sc := portOpenScript(Service{Name: "pod", Kind: "podman"}, portReq{Port: 1, Proto: "udp", For: time.Minute, Iface: "tailnet"})
	if !strings.Contains(sc, "/nix/var/nix/gcroots/fleet-containers/pod") || !strings.Contains(sc, "not installed on this host") || !strings.Contains(sc, "ss -lnH -u") {
		t.Errorf("podman script:\n%s", sc)
	}
}

// Real output of nft 1.1.6 (`nft -j list set` for two sets).
const nftJSON = `{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cnt-tmp", "table": "nixos-fw", "type": ["ifname", "inet_proto", "inet_service"], "handle": 2, "flags": ["timeout"], "elem": [{"elem": {"val": {"concat": ["any", "udp", 9]}, "timeout": 1800, "expires": 1799, "comment": "svc=y"}}]}}]}
{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cnt-tmp4", "table": "nixos-fw", "type": ["ifname", "inet_proto", "inet_service", "ipv4_addr"], "handle": 3, "flags": ["interval", "timeout"], "elem": [{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000, {"prefix": {"addr": "100.64.0.0", "len": 10}}]}, "timeout": 3600, "expires": 3599, "comment": "svc=x"}}, {"elem": {"val": {"concat": ["tailscale0", "udp", 9, "1.2.3.4"]}, "timeout": 1800, "expires": 1799, "comment": "svc=y"}}]}}]}
{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cnt-tmp6", "table": "nixos-fw", "type": ["ifname", "inet_proto", "inet_service", "ipv6_addr"], "handle": 4, "flags": ["interval", "timeout"]}}]}
`

func TestParseNftSetJSON(t *testing.T) {
	es, err := parseNftSetJSON(nftJSON)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 3 {
		t.Fatalf("got %d: %+v", len(es), es)
	}
	if e := es[0]; e.Iface != "any" || e.Proto != "udp" || e.Port != "9" || e.From != "all" || e.Svc != "y" || e.Expires != 1799*time.Second {
		t.Errorf("0: %+v", e)
	}
	if e := es[1]; e.Set != "cnt-tmp4" || e.From != "100.64.0.0/10" || e.Svc != "x" || e.Port != "8000" {
		t.Errorf("1: %+v", e)
	}
	if es[2].From != "1.2.3.4" {
		t.Errorf("2: %+v", es[2])
	}
	tbl := portLsTable("h001", es)
	for _, w := range []string{"SVC", "8000/tcp", "100.64.0.0/10", "59m59s", "29m59s", "any"} {
		if !strings.Contains(tbl, w) {
			t.Errorf("table missing %q:\n%s", w, tbl)
		}
	}
	if _, err := parseNftSetJSON("not json"); err == nil {
		t.Error("expected error")
	}
	if es, err := parseNftSetJSON(""); err != nil || len(es) != 0 {
		t.Errorf("empty: %v %v", es, err)
	}
}

// ---- audit --stdin

func runAuditStdin(t *testing.T, input string) error {
	t.Helper()
	oldInv := inv
	t.Cleanup(func() { inv = oldInv })
	inv = &Inventory{Services: map[string]Service{}}
	r, w, _ := os.Pipe()
	w.WriteString(input)
	w.Close()
	old := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = old }()
	return cmdAudit([]string{"h001", "--stdin"})
}

func TestCmdAuditStdinEmpty(t *testing.T) {
	for _, in := range []string{"", "\n", "sudo: a password is required\n"} {
		if err := runAuditStdin(t, in); err != nil {
			t.Errorf("input %q: err = %v", in, err)
		}
	}
}

func TestNeedsRootMsg(t *testing.T) {
	m := needsRootMsg("lio")
	for _, w := range []string{"sudo ss -ltnupH > /tmp/lio.ss && cnt audit lio --stdin < /tmp/lio.ss", "ssh -t", "no TTY"} {
		if !strings.Contains(m, w) {
			t.Errorf("missing %q in %s", w, m)
		}
	}
}

// Real `nft -j list set` output (h001, nft 1.1.6): mc has a bare element and
// v4/v6 --from elements on tailscale0, plus one on the lan iface; other svc
// "zz" shares the port.
const closeJSON = `{"nftables": [{"metainfo": {"version": "1.1.6"}}, {"set": {"family": "inet", "name": "cnt-tmp", "table": "nixos-fw", "elem": [{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000]}, "timeout": 30, "expires": 29, "comment": "svc=mc"}}, {"elem": {"val": {"concat": ["tailscale0", "tcp", 8000]}, "expires": 9, "comment": "svc=zz"}}]}}]}
{"nftables": [{"set": {"family": "inet", "name": "cnt-tmp4", "table": "nixos-fw", "elem": [{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000, "100.64.0.1"]}, "expires": 29, "comment": "svc=mc"}}, {"elem": {"val": {"concat": ["tailscale0", "tcp", 8000, {"prefix": {"addr": "10.0.0.0", "len": 8}}]}, "expires": 29, "comment": "svc=mc"}}, {"elem": {"val": {"concat": ["enp1s0", "tcp", 8000, "100.64.0.1"]}, "expires": 29, "comment": "svc=mc"}}, {"elem": {"val": {"concat": ["tailscale0", "udp", 8000, "100.64.0.1"]}, "expires": 29, "comment": "svc=mc"}}]}}]}
{"nftables": [{"set": {"family": "inet", "name": "cnt-tmp6", "table": "nixos-fw", "elem": [{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000, "fd7a:115c:a1e0::3"]}, "expires": 29, "comment": "svc=mc"}}]}}]}
`

func TestPortCloseTargets(t *testing.T) {
	es, err := parseNftSetJSON(closeJSON)
	if err != nil {
		t.Fatal(err)
	}
	keys := func(ts []portEntry) string {
		var out []string
		for _, e := range ts {
			out = append(out, e.Set+":"+e.From)
		}
		return strings.Join(out, " ")
	}
	r := portReq{Svc: "mc", Port: 8000, Proto: "tcp", Iface: "tailnet"}
	// No --from: every mc tcp/8000 element on tailscale0, all three sets;
	// not zz's, not udp, not the lan iface.
	if got := keys(closeTargets(es, r, "tailscale0")); got != "cnt-tmp:all cnt-tmp4:100.64.0.1 cnt-tmp4:10.0.0.0/8 cnt-tmp6:fd7a:115c:a1e0::3" {
		t.Errorf("no --from: %s", got)
	}
	// --from (resolved CIDRs, /32 and /128 as the CLI produces them): only those.
	r.From = []string{"100.64.0.1/32", "fd7a:115c:a1e0::3/128"}
	if got := keys(closeTargets(es, r, "tailscale0")); got != "cnt-tmp4:100.64.0.1 cnt-tmp6:fd7a:115c:a1e0::3" {
		t.Errorf("--from: %s", got)
	}
	r.From = []string{"10.0.0.0/8"}
	if got := keys(closeTargets(es, r, "tailscale0")); got != "cnt-tmp4:10.0.0.0/8" {
		t.Errorf("--from cidr: %s", got)
	}
	r.From = nil
	if got := keys(closeTargets(es, r, "enp1s0")); got != "cnt-tmp4:100.64.0.1" {
		t.Errorf("lan iface: %s", got)
	}
	r.Svc = "nope"
	if ts := closeTargets(es, r, "tailscale0"); len(ts) != 0 {
		t.Errorf("other svc: %v", ts)
	}

	r = portReq{Svc: "mc", Port: 8000, Proto: "tcp", Iface: "tailnet"}
	sc := portCloseScript(Service{Name: "mc"}, r, "tailscale0", closeTargets(es, r, "tailscale0"), false)
	for _, w := range []string{
		`delete element inet nixos-fw cnt-tmp { "tailscale0" . tcp . 8000 }`,
		`delete element inet nixos-fw cnt-tmp4 { "tailscale0" . tcp . 8000 . 100.64.0.1 }`,
		`delete element inet nixos-fw cnt-tmp4 { "tailscale0" . tcp . 8000 . 10.0.0.0/8 }`,
		`delete element inet nixos-fw cnt-tmp6 { "tailscale0" . tcp . 8000 . fd7a:115c:a1e0::3 }`,
		"logger -t cnt-port", "n=4",
	} {
		if !strings.Contains(sc, w) {
			t.Errorf("missing %q in\n%s", w, sc)
		}
	}
	if strings.Contains(sc, "add element") || strings.Contains(sc, "enp1s0") || strings.Contains(sc, "udp") {
		t.Errorf("close script touches too much:\n%s", sc)
	}
}

func TestPortNeedsRootMsg(t *testing.T) {
	m := portNeedsRootMsg("lio")
	if !strings.Contains(m, "lio") || !strings.Contains(m, "password") {
		t.Errorf("msg: %s", m)
	}
}

// ---- net.private: temporary forwards (table ip cnt-port)

func TestPortForwardScript(t *testing.T) {
	s := privSvc("puzzles", 15)
	cases := []struct {
		iface string
		from  []string
		want  []string
		not   []string
	}{
		{"tailnet", nil, []string{"IFACE=tailscale0",
			`add element ip cnt-port cnt-fwd { "$IFACE" . tcp . 8000 timeout 3600s comment "svc=puzzles" : 10.233.15.2 }`,
			`delete element ip cnt-port cnt-fwd { "$IFACE" . tcp . 8000 }`,
		}, []string{"ip cnt-port cnt-fwd4 ", "ip cnt-port cnt-fwd-any "}},
		{"any", nil, []string{"IFACE=any\n",
			`add element ip cnt-port cnt-fwd-any { tcp . 8000 timeout 3600s comment "svc=puzzles" : 10.233.15.2 }`,
		}, []string{`"$IFACE" . tcp`}},
		{"lan", []string{"100.64.0.1/32", "10.0.0.0/8"}, []string{"lan-interface",
			`add element ip cnt-port cnt-fwd4 { "$IFACE" . tcp . 8000 . 100.64.0.1/32 timeout 3600s comment "svc=puzzles" : 10.233.15.2 }`,
			`add element ip cnt-port cnt-fwd4 { "$IFACE" . tcp . 8000 . 10.0.0.0/8 timeout 3600s`,
		}, []string{"ip cnt-port cnt-fwd {"}},
		{"any", []string{"100.64.0.1/32"}, []string{
			`add element ip cnt-port cnt-fwd4-any { tcp . 8000 . 100.64.0.1/32 timeout 3600s comment "svc=puzzles" : 10.233.15.2 }`,
		}, []string{"ip cnt-port cnt-fwd {", `"$IFACE" . tcp`}},
	}
	for _, c := range cases {
		r := portReq{Svc: "puzzles", Port: 8000, Proto: "tcp", For: time.Hour, Iface: c.iface, From: c.from}
		sc := portForwardScript(s, r, 2*time.Hour)
		for _, w := range append(c.want, "/etc/systemd-mutable/system/container@puzzles.service",
			"nft list table ip cnt-port >/dev/null 2>&1 || nft -f - <<'NFT'\n"+cntPortNft+"NFT\n",
			"if ss -lnH -t 'sport = :8000' | grep -Evq", "a host process listens on it",
			"LEADER=$(machinectl show -p Leader --value 'puzzles' 2>/dev/null || true)\n",
			"puzzles is not running on this host",
			"nsenter -t \"$LEADER\" -n nft list set inet nixos-fw cnt-guest >/dev/null 2>&1 || {",
			"networking.nftables.enable = false, as arr does",
			"if ! nsenter -t \"$LEADER\" -n nft -f - <<EOF\nadd element inet nixos-fw cnt-guest { tcp . 8000 timeout 7200s comment \"svc=puzzles\" }\ndelete element inet nixos-fw cnt-guest { tcp . 8000 }\n",
			"removed the host forward again",
			"logger -t cnt-port \"forward svc=puzzles 8000/tcp", "to=10.233.15.2") {
			if !strings.Contains(sc, w) {
				t.Errorf("%s %v: missing %q in\n%s", c.iface, c.from, w, sc)
			}
		}
		// A forward never opens a host port.
		for _, n := range append(c.not, "inet nixos-fw cnt-tmp", "already open (declared)") {
			if strings.Contains(sc, n) {
				t.Errorf("%s %v: unexpected %q in\n%s", c.iface, c.from, n, sc)
			}
		}
		// Order: refuse before touching the host, guest element after the
		// forward, and a failed guest element deletes every forward element.
		leader, host, guest := strings.Index(sc, "LEADER="), strings.Index(sc, "nft -f - <<EOF\nadd element ip cnt-port"), strings.Index(sc, "if ! nsenter")
		if leader < 0 || host < leader || guest < host {
			t.Errorf("%s %v: order leader=%d host=%d guest=%d", c.iface, c.from, leader, host, guest)
		}
		undo := sc[guest:strings.Index(sc, "logger -t")]
		for _, e := range fwdElems(r) {
			if d := fmt.Sprintf("delete element ip cnt-port %s { %s }\n", e[0], e[1]); !strings.Contains(undo, d) {
				t.Errorf("%s %v: undo misses %q in\n%s", c.iface, c.from, d, undo)
			}
		}
	}
	if sc := portForwardScript(s, portReq{Svc: "puzzles", Port: 53, Proto: "udp", For: time.Minute, Iface: "tailnet"}, time.Minute); !strings.Contains(sc, "ss -lnH -u 'sport = :53'") || !strings.Contains(sc, "udp . 53 timeout 60s") || !strings.Contains(sc, "cnt-guest { udp . 53 timeout 60s") {
		t.Errorf("udp:\n%s", sc)
	}
	// Podman has no guest firewall: the DNAT alone reaches it.
	pod := privSvc("hello", 20)
	pod.Kind = "podman"
	if sc := portForwardScript(pod, portReq{Svc: "hello", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "tailnet"}, time.Hour); strings.Contains(sc, "machinectl") || strings.Contains(sc, "nsenter") || strings.Contains(sc, "cnt-guest") || !strings.Contains(sc, "add element ip cnt-port cnt-fwd ") {
		t.Errorf("podman:\n%s", sc)
	}
}

// The shadow check ignores loopback-only listeners and refuses others.
func TestHostListenerRE(t *testing.T) {
	if _, err := exec.LookPath("grep"); err != nil {
		t.Skip("grep not in PATH")
	}
	for in, shadows := range map[string]bool{
		"LISTEN 0      4096       127.0.0.1:8000       0.0.0.0:*\n":          false,
		"LISTEN 0      4096           [::1]:8000          [::]:*\n":          false,
		"UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*\n":          false,
		"LISTEN 0      4096         0.0.0.0:8000       0.0.0.0:*\n":          true,
		"LISTEN 0      4096     100.64.0.13:8000       0.0.0.0:*\n":          true,
		"LISTEN 0      4096               *:8000             *:*\n":          true,
		"LISTEN 0 1 127.0.0.1:8000 0.0.0.0:*\nLISTEN 0 1 [::]:8000 [::]:*\n": true,
		"": false,
	} {
		cmd := exec.Command("grep", "-Evq", hostListenerRE)
		cmd.Stdin = strings.NewReader(in)
		if got := cmd.Run() == nil; got != shadows {
			t.Errorf("%q: shadows=%v want %v", in, got, shadows)
		}
	}
}

func TestForwardFrom(t *testing.T) {
	s := Service{Name: "puzzles"}
	if f, note, err := forwardFrom(s, nil); err != nil || note != "" || len(f) != 0 {
		t.Errorf("no --from: %v %q %v", f, note, err)
	}
	f, note, err := forwardFrom(s, []string{"100.64.0.3/32", "fd7a:115c:a1e0::3/128", "10.0.0.0/8"})
	if err != nil || strings.Join(f, " ") != "100.64.0.3/32 10.0.0.0/8" || !strings.Contains(note, "fd7a:115c:a1e0::3/128") {
		t.Errorf("mixed: %v %q %v", f, note, err)
	}
	// Every source v6: refusing beats silently opening to everyone.
	if f, _, err := forwardFrom(s, []string{"fd7a:115c:a1e0::3/128"}); err == nil || len(f) != 0 {
		t.Errorf("v6 only: %v %v", f, err)
	}
}

// The prerouting chain keeps the guards: never from guests, only to this
// host's addresses, and it runs after fleet-net-nat so declared routes win.
func TestCntPortNftGuards(t *testing.T) {
	pre := between(cntPortNft, "chain prerouting {", "\n  }")
	if !strings.Contains(pre, "priority dstnat + 10;") {
		t.Errorf("must run after fleet-net-nat (dstnat):\n%s", pre)
	}
	for _, g := range []string{`iifname "ve-*" return`, `iifname "podman*" return`, `iifname "fleet-noinet" return`} {
		if i, j := strings.Index(pre, g), strings.Index(pre, "dnat"); i < 0 || i > j {
			t.Errorf("guard %q missing or after the first dnat:\n%s", g, pre)
		}
	}
	dnats := 0
	for _, l := range strings.Split(pre, "\n") {
		if strings.Contains(l, " dnat ") {
			dnats++
			if !strings.HasPrefix(strings.TrimSpace(l), "fib daddr type local dnat ip to ") {
				t.Errorf("dnat without the local-address guard: %s", l)
			}
		}
	}
	if dnats != len(fwdMaps) {
		t.Errorf("want one dnat per map:\n%s", pre)
	}
	for _, m := range fwdMaps {
		if !strings.Contains(cntPortNft, "map "+m+" {") || !strings.Contains(pre+"\n", "@"+m+"\n") {
			t.Errorf("map %s not declared or not used", m)
		}
	}
}

// Real output of nft 1.1.6 (`nft -j list map` of the four forward maps).
const fwdJSON = `{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "cnt-fwd", "table": "cnt-port", "type": ["ifname", "inet_proto", "inet_service"], "handle": 2, "map": "ipv4_addr", "flags": ["timeout"], "elem": [[{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000]}, "timeout": 30, "expires": 29, "comment": "svc=a"}}, "10.233.15.2"]]}}]}
{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "cnt-fwd4", "table": "cnt-port", "type": ["ifname", "inet_proto", "inet_service", "ipv4_addr"], "handle": 3, "map": "ipv4_addr", "flags": ["interval", "timeout"], "elem": [[{"elem": {"val": {"concat": ["tailscale0", "tcp", 8000, "10.12.14.5"]}, "timeout": 2, "expires": 1, "comment": "svc=a"}}, "10.233.15.2"]]}}]}
{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "cnt-fwd-any", "table": "cnt-port", "type": ["inet_proto", "inet_service"], "handle": 4, "map": "ipv4_addr", "flags": ["timeout"]}}]}
{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"map": {"family": "ip", "name": "cnt-fwd4-any", "table": "cnt-port", "type": ["inet_proto", "inet_service", "ipv4_addr"], "handle": 5, "map": "ipv4_addr", "flags": ["interval", "timeout"], "elem": [[{"elem": {"val": {"concat": ["udp", 9000, "100.64.0.1"]}, "timeout": 60, "expires": 59, "comment": "svc=b"}}, "10.233.16.2"], [{"elem": {"val": {"concat": ["udp", 9000, {"prefix": {"addr": "10.12.14.0", "len": 24}}]}, "timeout": 60, "expires": 59, "comment": "svc=b"}}, "10.233.16.2"]]}}]}
`

func TestParseFwdJSONAndClose(t *testing.T) {
	es, err := parseNftSetJSON(nftJSON + fwdJSON)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 7 {
		t.Fatalf("got %d: %+v", len(es), es)
	}
	if e := es[3]; e.Set != "cnt-fwd" || e.Iface != "tailscale0" || e.Port != "8000" || e.From != "all" || e.To != "10.233.15.2" || e.Svc != "a" || e.Expires != 29*time.Second {
		t.Errorf("cnt-fwd: %+v", e)
	}
	if e := es[5]; e.Set != "cnt-fwd4-any" || e.Iface != "any" || e.Proto != "udp" || e.Port != "9000" || e.From != "100.64.0.1" || e.To != "10.233.16.2" {
		t.Errorf("cnt-fwd4-any: %+v", e)
	}
	if es[0].To != "" || es[6].From != "10.12.14.0/24" {
		t.Errorf("host port / prefix: %+v %+v", es[0], es[6])
	}
	tbl := portLsTable("h001", es)
	for _, w := range []string{"TO", "10.233.16.2", "10.12.14.0/24", "9000/udp"} {
		if !strings.Contains(tbl, w) {
			t.Errorf("table missing %q:\n%s", w, tbl)
		}
	}

	keys := func(ts []portEntry) string {
		var out []string
		for _, e := range ts {
			out = append(out, e.Set+":"+e.From)
		}
		return strings.Join(out, " ")
	}
	// --iface any: only the *-any map (and cnt-tmp "any"); --from narrows.
	r := portReq{Svc: "b", Port: 9000, Proto: "udp", Iface: "any"}
	if got := keys(closeTargets(es, r, "any")); got != "cnt-fwd4-any:100.64.0.1 cnt-fwd4-any:10.12.14.0/24" {
		t.Errorf("any: %s", got)
	}
	r.From = []string{"10.12.14.0/24"}
	ts := closeTargets(es, r, "any")
	if got := keys(ts); got != "cnt-fwd4-any:10.12.14.0/24" {
		t.Errorf("any --from: %s", got)
	}
	if lastForward(es, ts, r) {
		t.Errorf("b's other --from forward stays: not the last")
	}
	sc := portCloseScript(privSvc("b", 16), r, "any", ts, lastForward(es, ts, r))
	if !strings.Contains(sc, "delete element ip cnt-port cnt-fwd4-any { udp . 9000 . 10.12.14.0/24 }\n") || strings.Contains(sc, "100.64.0.1") || strings.Contains(sc, "nixos-fw") {
		t.Errorf("close any --from:\n%s", sc)
	}
	// An unscoped forward isn't removed by a --from close.
	r = portReq{Svc: "a", Port: 8000, Proto: "tcp", Iface: "tailnet", From: []string{"10.12.14.5/32"}}
	if got := keys(closeTargets(es, r, "tailscale0")); got != "cnt-fwd4:10.12.14.5" {
		t.Errorf("tailnet --from: %s", got)
	}
	r.From = nil
	ts = closeTargets(es, r, "tailscale0")
	if !lastForward(es, ts, r) {
		t.Errorf("closing a's tailscale0 forwards closes its last")
	}
	sc = portCloseScript(privSvc("a", 15), r, "tailscale0", ts, true)
	for _, w := range []string{
		`delete element ip cnt-port cnt-fwd { "tailscale0" . tcp . 8000 }`,
		`delete element ip cnt-port cnt-fwd4 { "tailscale0" . tcp . 8000 . 10.12.14.5 }`,
		"LEADER=$(machinectl show -p Leader --value 'a' 2>/dev/null || true)\n",
		`*) nsenter -t "$LEADER" -n nft delete element inet nixos-fw cnt-guest '{ tcp . 8000 }' 2>/dev/null || true;;`,
	} {
		if !strings.Contains(sc, w) {
			t.Errorf("missing %q in\n%s", w, sc)
		}
	}
	r.From = []string{"10.12.14.5/32"}
	if lastForward(es, closeTargets(es, r, "tailscale0"), r) {
		t.Errorf("closing one --from of a leaves its cnt-fwd: not the last")
	}
	if mc := (portReq{Svc: "mc", Port: 8000, Proto: "tcp"}); lastForward(es, closeTargets(es, mc, "tailscale0"), mc) {
		t.Errorf("host-port close touches the guest")
	}
	// The shared guest element lasts as long as the longest live forward.
	for d, want := range map[time.Duration]time.Duration{10 * time.Second: 29 * time.Second, time.Hour: time.Hour} {
		if got := guestFor(es, portReq{Svc: "a", Port: 8000, Proto: "tcp", For: d}); got != want {
			t.Errorf("guestFor(%s) = %s, want %s", d, got, want)
		}
	}
	if got := guestFor(es, portReq{Svc: "b", Port: 8000, Proto: "tcp", For: time.Second}); got != time.Second {
		t.Errorf("guestFor other svc = %s", got)
	}
	if !strings.Contains(portLsScript, "nft -j list map ip cnt-port \"$m\"") || !strings.Contains(portLsScript, "cnt-fwd4-any") {
		t.Errorf("ls script skips the forwards:\n%s", portLsScript)
	}
}

// nsShell is a root shell in a private user+net namespace, kept across
// steps (a fresh namespace would start with an empty ruleset).
type nsShell struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

func newNsShell(t *testing.T) *nsShell {
	t.Helper()
	for _, b := range []string{"nft", "unshare", "sh"} {
		if _, err := exec.LookPath(b); err != nil {
			t.Skipf("%s not in PATH", b)
		}
	}
	if out, err := exec.Command("unshare", "-rn", "nft", "list", "ruleset").CombinedOutput(); err != nil {
		t.Skipf("no user namespaces / nft: %v %s", err, out)
	}
	cmd := exec.Command("unshare", "-rn", "sh")
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	s := &nsShell{cmd: cmd, in: in, out: bufio.NewReader(out)}
	t.Cleanup(func() { in.Close(); cmd.Wait() })
	return s
}

// run executes script in a subshell (so set -e and exit stay local) and
// returns its output; it fails the test on a nonzero exit.
func (s *nsShell) run(t *testing.T, script string) string {
	t.Helper()
	out, rc := s.runRC(t, script)
	if rc != "0" {
		t.Fatalf("exit %s:\n%s\n--- script:\n%s", rc, out, script)
	}
	return out
}

// runRC is run without the exit check: output and exit status.
func (s *nsShell) runRC(t *testing.T, script string) (string, string) {
	t.Helper()
	fmt.Fprintf(s.in, "(\n%s\n) 2>&1\necho \"__END__ $?\"\n", script)
	var b strings.Builder
	for {
		l, err := s.out.ReadString('\n')
		if err != nil {
			t.Fatalf("shell died: %v\n%s", err, b.String())
		}
		if rc, ok := strings.CutPrefix(l, "__END__ "); ok {
			return b.String(), strings.TrimSpace(rc)
		}
		b.WriteString(l)
	}
}

// cutAt returns sc up to the first of ends present in it.
func cutAt(t *testing.T, sc string, ends ...string) string {
	t.Helper()
	for _, e := range ends {
		if j := strings.Index(sc, e); j >= 0 {
			return sc[:j]
		}
	}
	t.Fatalf("unexpected script:\n%s", sc)
	return ""
}

// The host nft parts of the open/ls/close scripts against a real kernel:
// open (twice: the table bootstrap is skipped and the timeout re-armed),
// list, scoped close, and kernel expiry. The guest half (machinectl,
// nsenter, cnt-guest) is TestPortForwardPackets.
func TestPortForwardLive(t *testing.T) {
	sh := newNsShell(t)
	// The host module's sets (host-module.nix), so portLsScript runs as is.
	sh.run(t, `nft -f - <<'EOF'
table inet nixos-fw {
  set cnt-tmp { type ifname . inet_proto . inet_service; flags timeout; }
  set cnt-tmp4 { type ifname . inet_proto . inet_service . ipv4_addr; flags interval,timeout; }
  set cnt-tmp6 { type ifname . inet_proto . inet_service . ipv6_addr; flags interval,timeout; }
}
EOF`)
	nftPart := func(sc string) string {
		i := strings.Index(sc, "nft list table ip cnt-port")
		if i < 0 {
			t.Fatalf("unexpected script:\n%s", sc)
		}
		return cutAt(t, sc[i:], "if ! nsenter", "logger -t")
	}
	ls := func() []portEntry {
		es, err := parseNftSetJSON(sh.run(t, portLsScript))
		if err != nil {
			t.Fatal(err)
		}
		return es
	}
	keys := func(es []portEntry) string {
		var out []string
		for _, e := range es {
			out = append(out, fmt.Sprintf("%s:%s:%s/%s:%s>%s", e.Set, e.Iface, e.Port, e.Proto, e.From, e.To))
		}
		return strings.Join(out, " ")
	}
	// Before any open the table is absent and ls still works.
	if es := ls(); len(es) != 0 {
		t.Fatalf("empty: %+v", es)
	}
	a, b := privSvc("a", 15), privSvc("b", 16)
	ra := portReq{Svc: "a", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "tailnet", From: []string{"100.64.0.1/32", "10.0.0.0/8"}}
	sh.run(t, "IFACE=tailscale0\n"+nftPart(portForwardScript(a, ra, ra.For)))
	sh.run(t, "IFACE=tailscale0\n"+nftPart(portForwardScript(a, ra, ra.For)))
	sh.run(t, "IFACE=enp1s0\n"+nftPart(portForwardScript(a, portReq{Svc: "a", Port: 8000, Proto: "tcp", For: time.Hour, Iface: "lan"}, time.Hour)))
	rb := portReq{Svc: "b", Port: 9000, Proto: "udp", For: time.Second, Iface: "any"}
	sh.run(t, "IFACE=any\n"+nftPart(portForwardScript(b, rb, rb.For)))
	if n := strings.Count(sh.run(t, "nft list chain ip cnt-port prerouting"), " dnat "); n != len(fwdMaps) {
		t.Errorf("bootstrap ran twice: %d dnat rules", n)
	}
	want := "cnt-fwd:enp1s0:8000/tcp:all>10.233.15.2 cnt-fwd4:tailscale0:8000/tcp:100.64.0.1>10.233.15.2 cnt-fwd4:tailscale0:8000/tcp:10.0.0.0/8>10.233.15.2 cnt-fwd-any:any:9000/udp:all>10.233.16.2"
	es := ls()
	if got := keys(es); got != want {
		t.Fatalf("after open:\n got %s\nwant %s", got, want)
	}
	for _, e := range es {
		// Expires is whole seconds left: b's 1s timeout may already show 0.
		if e.Svc != map[string]string{"10.233.15.2": "a", "10.233.16.2": "b"}[e.To] || (e.Svc == "a" && e.Expires <= 0) {
			t.Errorf("comment/expiry: %+v", e)
		}
	}

	closeNft := func(svc Service, r portReq, iface string) {
		es := ls()
		ts := closeTargets(es, r, iface)
		if len(ts) == 0 {
			t.Fatalf("nothing to close for %+v", r)
		}
		sh.run(t, cutAt(t, portCloseScript(svc, r, iface, ts, lastForward(es, ts, r)), "LEADER=", "logger -t"))
	}
	// close --from: only that source; the lan forward stays.
	closeNft(a, portReq{Svc: "a", Port: 8000, Proto: "tcp", Iface: "tailnet", From: []string{"100.64.0.1/32"}}, "tailscale0")
	if got := keys(ls()); got != strings.Replace(want, "cnt-fwd4:tailscale0:8000/tcp:100.64.0.1>10.233.15.2 ", "", 1) {
		t.Fatalf("after close --from: %s", got)
	}
	// close without --from on tailnet: the rest of tailscale0, not enp1s0.
	closeNft(a, portReq{Svc: "a", Port: 8000, Proto: "tcp", Iface: "tailnet"}, "tailscale0")
	if got := keys(ls()); got != "cnt-fwd:enp1s0:8000/tcp:all>10.233.15.2 cnt-fwd-any:any:9000/udp:all>10.233.16.2" {
		t.Fatalf("after close: %s", got)
	}
	// Expiry: b's 1s forward is gone without a close.
	time.Sleep(2 * time.Second)
	if got := keys(ls()); got != "cnt-fwd:enp1s0:8000/tcp:all>10.233.15.2" {
		t.Fatalf("after expiry: %s", got)
	}
}
