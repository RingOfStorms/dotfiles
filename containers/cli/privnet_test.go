package main

// Private container networking (ROUTING-PLAN §8 step 5).

import (
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
	}
	got := strings.Join(portsFileLines(s), "\n")
	want := "tcp 3032 dnat 10.233.3.2\nnoinet ve-forgejo"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	h := Service{Name: "x", TCPPorts: []int{8090}, Routes: map[string]Route{"ssh": {Port: 3032, Proto: "tcp", Exposure: "tailnet"}}}
	if got := strings.Join(portsFileLines(h), "\n"); got != "tcp 8090\ntcp 3032" {
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
