package containers

// Private container networking (ROUTING-PLAN §8 step 5).

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func privSvc(name string, idx int) Service {
	ip := "10.233." + strconv.Itoa(idx) + ".2"
	return Service{Name: name, Kind: "nixos", Host: "h001", Net: Net{Private: true, Index: &idx, IP: &ip}}
}

func TestPrivateVhostUpstream(t *testing.T) {
	s := privSvc("puzzles", 2)
	s.Routes = map[string]Route{"web": httpRoute("puzzles", 8093, "public", "native")}
	v := routesVhost(s)
	if !strings.Contains(v, "proxy_pass http://10.233.2.2:8093;") {
		t.Fatalf("private vhost should proxy to the guest IP:\n%s", v)
	}
	if strings.Contains(v, "127.0.0.1") {
		t.Fatalf("private vhost must not mention loopback:\n%s", v)
	}
	// host network: unchanged
	h := Service{Name: "puzzles", Routes: s.Routes}
	if !strings.Contains(routesVhost(h), "proxy_pass http://127.0.0.1:8093;") {
		t.Fatal("host-network vhost should keep 127.0.0.1")
	}
}

func TestPortsFileLines(t *testing.T) {
	f := false
	s := privSvc("forgejo", 3)
	s.Internet = &f
	s.Routes = map[string]Route{
		"web": httpRoute("forgejo", 3000, "public", "native"),
		"ssh": {Port: 3032, Proto: "tcp", Exposure: "public"},
		"ml":  {Port: 3003, Proto: "tcp", Exposure: "local"},
		"mc":  {Port: 25565, Proto: "tcp", Exposure: "lan"},
	}
	got := strings.Join(portsFileLines(s, "h001"), "\n")
	want := "guest ve-forgejo\ntcp 25565 dnat 10.233.3.2 lan\ntcp 3032 dnat 10.233.3.2\nnoinet ve-forgejo"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	h := Service{Name: "x", TCPPorts: []int{8090}, Routes: map[string]Route{"ssh": {Port: 3032, Proto: "tcp", Exposure: "tailnet"}}}
	if got := strings.Join(portsFileLines(h, "h001"), "\n"); got != "tcp 8090\ntcp 3032" {
		t.Fatalf("host network: got %q", got)
	}
}

func TestAuditPrivateStale(t *testing.T) {
	s := privSvc("puzzles", 2)
	s.Routes = map[string]Route{"web": httpRoute("puzzles", 8093, "public", "native")}
	ss := `tcp   LISTEN 0      4096       127.0.0.1:8093       0.0.0.0:*    users:(("puzzles-server",pid=7,fd=3))
`
	rows := auditListeners(parseSS(ss), []Service{s}, "h001")
	if len(rows) != 1 || rows[0].Status != "STALE" {
		t.Fatalf("host listener on a private route port should be STALE: %+v", rows)
	}
	// Another host on the same port: not ours.
	if rows := auditListeners(parseSS(ss), []Service{s}, "h003"); len(rows) != 0 {
		t.Fatalf("other host: %+v", rows)
	}
}

func TestPortGuardPrivate(t *testing.T) {
	s := privSvc("puzzles", 2)
	if _, err := portGuards(s, portReq{Port: 9000, Proto: "tcp"}, "h001", nil); err == nil {
		t.Fatal("cnt port open must refuse a net.private service")
	}
}

func TestNetExceptionsAndCallers(t *testing.T) {
	old := inv
	defer func() { inv = old }()
	ov := "100.64.0.13"
	ov3 := "100.64.0.17"
	ow := privSvc("open-webui", 6)
	ow.Net.Uses = []string{"litellm.web", "searx.api", "remote.web"}
	ow.Net.Egress = []string{"10.12.14.181:9010/tcp"}
	lit := privSvc("litellm", 7)
	lit.Routes = map[string]Route{"web": httpRoute("litellm", 8094, "tailnet", "native")}
	sx := privSvc("searx", 8)
	sx.Routes = map[string]Route{"api": {Port: 8889, Proto: "tcp", Exposure: "tailnet"}}
	rem := Service{Name: "remote", Host: "h003", Routes: map[string]Route{"web": httpRoute("remote", 1, "public", "native")}}
	inv = &Inventory{
		Services: map[string]Service{"open-webui": ow, "litellm": lit, "searx": sx, "remote": rem},
		Hosts:    map[string]Host{"h001": {OverlayIP: &ov}, "h003": {OverlayIP: &ov3}},
	}
	got := strings.Join(netExceptions(ow, "h001"), "\n")
	want := strings.Join([]string{
		"allow ve-open-webui 10.233.7.2 tcp 8094",
		"allow ve-open-webui 10.233.0.1 tcp 80",
		"allow ve-open-webui 10.233.0.1 tcp 443",
		"allow ve-open-webui 100.64.0.13 tcp 80",
		"allow ve-open-webui 100.64.0.13 tcp 443",
		"allow ve-open-webui 10.233.8.2 tcp 8889",
		"allow ve-open-webui 10.233.0.1 tcp 8889",
		"allow ve-open-webui 100.64.0.13 tcp 8889",
		"allow ve-open-webui 100.64.0.17 tcp 80",
		"allow ve-open-webui 100.64.0.17 tcp 443",
		"allow ve-open-webui 10.12.14.181 tcp 9010",
	}, "\n")
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	v := routesVhost(lit)
	if !strings.Contains(v, "allow 10.233.6.2; # net.uses open-webui\n  include /etc/fleet-containers/nginx-acl-tailnet.conf;") {
		t.Fatalf("caller allow missing or after the ACL:\n%s", v)
	}
	if strings.Contains(routesVhost(rem), "allow 10.233.") {
		t.Fatal("remote-host callers must not be allowed by guest IP")
	}
}

func TestPortsFileTailnetDnat(t *testing.T) {
	old := inv
	defer func() { inv = old }()
	ov := "100.64.0.13"
	inv = &Inventory{Services: map[string]Service{}, Hosts: map[string]Host{"h001": {OverlayIP: &ov}}}
	s := privSvc("beszel", 12)
	s.Routes = map[string]Route{"hub": {Port: 8090, Proto: "tcp", Exposure: "tailnet"}}
	got := strings.Join(portsFileLines(s, "h001"), "\n")
	if want := "guest ve-beszel\ntcp 8090 dnat 10.233.12.2 100.64.0.13"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	// Unknown overlay IP: no DNAT at all (fail closed), never any-address.
	if got := strings.Join(portsFileLines(s, "h009"), "\n"); got != "guest ve-beszel" {
		t.Fatalf("no overlay: got %q", got)
	}
}

func TestPortsFileTailnetAllow(t *testing.T) {
	old := inv
	defer func() { inv = old }()
	ov, lio := "100.64.0.13", "100.64.0.1"
	inv = &Inventory{Services: map[string]Service{}, Hosts: map[string]Host{"h001": {OverlayIP: &ov}, "lio": {OverlayIP: &lio}}}
	s := privSvc("immich", 15)
	s.Routes = map[string]Route{
		"pg":  {Port: 5432, Proto: "tcp", Exposure: "tailnet", Allow: []string{"lio", "nosuch"}},
		"bad": {Port: 9, Proto: "tcp", Exposure: "public", Allow: []string{"lio"}},
	}
	got := strings.Join(portsFileLines(s, "h001"), "\n")
	if want := "guest ve-immich\ntcp 5432 dnat 10.233.15.2 100.64.0.13 100.64.0.1"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

// A deploy that drops a port deletes it from temp-ports (applyPorts only
// ever adds); ports still opened by any ports file and DNAT lines stay.
func TestDeployPrunesDroppedPorts(t *testing.T) {
	r := newOverrideRig(t)
	s := Service{Name: "app", Kind: "nixos", TCPPorts: []int{8090}}
	ps := prepareScript(s, "h001")
	i, j := strings.Index(ps, "old_ports="), strings.Index(ps, "systemctl reload-or-restart fleet-containers-ports")
	if i < 0 || j < i || !strings.Contains(ps[i:j], prunePortsScript) {
		t.Fatalf("prepareScript must prune between the ports write and the reload:\n%s", ps)
	}
	snippet := "set -euo pipefail\n" + ps[i:j]
	nftLog := filepath.Join(r.dir, "nft.log")
	// nft fails like a missing element does; the deploy must not care.
	writeExe(t, filepath.Join(r.bin, "nft"), "#!"+r.bash+"\necho \"$*\" >> "+nftLog+"\nexit 1\n")
	pd := filepath.Join(r.dir, "ports")
	must(t, os.MkdirAll(pd, 0o755))
	run := func() string {
		t.Helper()
		os.Remove(nftLog)
		must(t, r.run(snippet))
		b, _ := os.ReadFile(nftLog)
		return string(b)
	}
	// No previous file: nothing to delete.
	if got := run(); got != "" {
		t.Errorf("missing old file: nft called: %q", got)
	}
	must(t, os.WriteFile(filepath.Join(pd, "app"), []byte("tcp 8090\ntcp 8081\nudp 9000\ntcp 3032 dnat 10.233.1.2\nguest ve-app\ntcp 7000"), 0o644))
	must(t, os.WriteFile(filepath.Join(pd, "other"), []byte("udp 9000\n"), 0o644))
	want := "delete element inet nixos-fw temp-ports { tcp . 8081 }\ndelete element inet nixos-fw temp-ports { tcp . 7000 }\n"
	if got := run(); got != want {
		t.Errorf("nft calls:\n%s\nwant:\n%s", got, want)
	}
	if b, _ := os.ReadFile(filepath.Join(pd, "app")); string(b) != "tcp 8090\n" {
		t.Errorf("new ports file: %q", b)
	}
	// Idempotent: a second deploy of the same file deletes nothing.
	if got := run(); got != "" {
		t.Errorf("redeploy: nft called: %q", got)
	}
}
