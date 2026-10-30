package containers

import (
	"os"
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
	svcs := map[string]Service{
		"sec": {Name: "sec", Host: "h001", Routes: map[string]Route{"web": httpRoute("secrets", 8300, "public", "native-oidc")}},
		"mc":  {Name: "mc", Host: "h001", TCPPorts: []int{25565}, Routes: map[string]Route{"q": {Port: 25566, Proto: "udp", Exposure: "tailnet"}}},
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

// ---- Task A: audit --stdin

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
	sc := portCloseScript(Service{Name: "mc"}, r, "tailscale0", closeTargets(es, r, "tailscale0"))
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
