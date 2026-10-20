package main

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func sp(s string) *string { return &s }

func httpRoute(name string, port int, exposure, auth string) Route {
	return Route{Port: port, Proto: "http", Exposure: exposure, Auth: sp(auth), Via: []string{"edge"},
		Name: sp(name), Zone: sp("main"), FQDN: sp(name + ".joshuabell.xyz"), URL: sp("https://" + name + ".joshuabell.xyz"),
		Websockets: true, MaxBody: "100m", Buffering: true, Timeouts: "60s", ForwardedProto: "https"}
}

// Golden: sec's route as lib.nix normalizes it (maxBody 64k).
const secVhostGolden = `# route web: exposure public, auth native-oidc
server {
  listen 80;
  listen [::]:80;
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name secrets.joshuabell.xyz;
  ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
  ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
  client_max_body_size 64k;
  location / {
    proxy_pass http://127.0.0.1:8300;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    # TODO(ROUTING-PLAN §8 step 6): strip _oauth2_proxy* cookies before the backend.
    proxy_buffering on;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
}
`

func TestRoutesVhostGolden(t *testing.T) {
	r := httpRoute("secrets", 8300, "public", "native-oidc")
	r.MaxBody = "64k"
	s := Service{Name: "sec", Routes: map[string]Route{"web": r}}
	if got := routesVhost(s); got != secVhostGolden {
		t.Fatalf("vhost mismatch:\n%s\nwant:\n%s", got, secVhostGolden)
	}
}

func TestRoutesVhostKnobsAndLocal(t *testing.T) {
	web := httpRoute("photos", 2283, "tailnet", "native")
	web.Websockets, web.Buffering, web.Timeouts, web.MaxBody = false, false, "1h", "50G"
	web.ExtraConfig = "proxy_request_buffering off;\n  add_header X-A b;\n"
	ml := Route{Port: 3003, Proto: "http", Exposure: "local", Name: sp("immich-ml"), FQDN: sp("immich-ml.joshuabell.xyz")}
	db := Route{Port: 5432, Proto: "tcp", Exposure: "tailnet", Auth: sp("native")}
	udp := Route{Port: 51820, Proto: "udp", Exposure: "local"}
	s := Service{Name: "immich", Routes: map[string]Route{"web": web, "ml": ml, "db": db, "wg": udp}}
	v := routesVhost(s)
	for _, want := range []string{"server_name photos.joshuabell.xyz;", "proxy_buffering off;", "proxy_read_timeout 1h;",
		"client_max_body_size 50G;", "    proxy_request_buffering off;\n    add_header X-A b;\n  }"} {
		if !strings.Contains(v, want) {
			t.Errorf("missing %q in\n%s", want, v)
		}
	}
	if strings.Contains(v, "Upgrade") || strings.Contains(v, "immich-ml") || strings.Count(v, "server {") != 1 {
		t.Errorf("unexpected vhost:\n%s", v)
	}
	if p := routePorts(s); len(p) != 1 || p[0] != "tcp 5432" {
		t.Errorf("routePorts = %v", p)
	}
	if routesVhost(Service{Name: "x", Routes: map[string]Route{"ml": ml}}) != "" {
		t.Error("local-only service must render no vhost")
	}
}

func TestPrepareScriptRoutes(t *testing.T) {
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}}
	s := Service{Name: "sec", TCPPorts: []int{7000}, Routes: map[string]Route{
		"web": httpRoute("secrets", 8300, "public", "native-oidc"),
		"raw": {Port: 9000, Proto: "udp", Exposure: "lan", Auth: sp("native")},
	}}
	ps := prepareScript(s, "h001")
	if !strings.Contains(ps, "(generated from routes)") || !strings.Contains(ps, "server_name secrets.joshuabell.xyz;") {
		t.Errorf("no generated vhost:\n%s", ps)
	}
	if !strings.Contains(ps, `printf %s 'tcp 7000
udp 9000
' > /var/lib/fleet-containers/ports/sec`) {
		t.Errorf("ports file wrong:\n%s", ps)
	}
	// Only a local route: no vhost, old site removed.
	s.Routes = map[string]Route{"web": {Port: 1, Proto: "http", Exposure: "local"}}
	if ps := prepareScript(s, "h001"); !strings.Contains(ps, "rm -f /var/lib/fleet-containers/nginx/sec.conf") {
		t.Errorf("local-only should remove site:\n%s", ps)
	}
}

func TestValidateRoutes(t *testing.T) {
	ok := httpRoute("a", 80, "public", "native")
	cases := map[string]struct {
		s   Service
		err string
	}{
		"ok":          {Service{Name: "a", Routes: map[string]Route{"web": ok}}, ""},
		"both":        {Service{Name: "a", Nginx: sp("server {}"), Routes: map[string]Route{"web": ok}}, "not both"},
		"public none": {Service{Name: "a", Routes: map[string]Route{"web": func() Route { r := ok; r.Auth = sp("none"); return r }()}}, "publicWithoutAuth"},
		"public none ok": {Service{Name: "a", Routes: map[string]Route{"web": func() Route {
			r := ok
			r.Auth, r.PublicWithoutAuth = sp("none"), true
			return r
		}()}}, ""},
		"no auth":      {Service{Name: "a", Routes: map[string]Route{"web": func() Route { r := ok; r.Auth = nil; return r }()}}, "auth is required"},
		"private":      {Service{Name: "a", Routes: map[string]Route{"web": func() Route { r := ok; r.Zone = sp("private"); return r }()}}, "private zone"},
		"injection":    {Service{Name: "a", Routes: map[string]Route{"web": func() Route { r := ok; r.MaxBody = "1m; evil"; return r }()}}, "not allowed"},
		"bad port":     {Service{Name: "a", Routes: map[string]Route{"web": func() Route { r := ok; r.Port = 0; return r }()}}, "bad port"},
		"local noauth": {Service{Name: "a", Routes: map[string]Route{"ml": {Port: 3003, Proto: "http", Exposure: "local", FQDN: sp("x")}}}, ""},
	}
	for name, c := range cases {
		err := validateRoutes(c.s)
		if c.err == "" && err != nil || c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)) {
			t.Errorf("%s: err = %v, want %q", name, err, c.err)
		}
	}
}

const ssSample = `tcp   LISTEN 0      4096         0.0.0.0:8989       0.0.0.0:*    users:(("Sonarr",pid=1234,fd=12))
tcp   LISTEN 0      511          0.0.0.0:443        0.0.0.0:*    users:(("nginx",pid=99,fd=7),("nginx",pid=98,fd=7))
tcp   LISTEN 0      511             [::]:443           [::]:*    users:(("nginx",pid=99,fd=8))
tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=5,fd=3))
tcp   LISTEN 0      4096       127.0.0.1:8300       0.0.0.0:*    users:(("secrets_manager",pid=7,fd=3))
tcp   LISTEN 0      4096           [::1]:8085          [::]:*    users:(("zitadel",pid=8,fd=3))
tcp   LISTEN 0      4096   100.64.0.13%tailscale0:8094 0.0.0.0:* users:(("litellm",pid=9,fd=3))
tcp   LISTEN 0      4096               *:3032             *:*    users:(("forgejo",pid=10,fd=3))
tcp   LISTEN 0      4096         0.0.0.0:3003       0.0.0.0:*    users:(("python",pid=11,fd=3))
udp   UNCONN 0      0            0.0.0.0:41641      0.0.0.0:*    users:(("tailscaled",pid=12,fd=3))
udp   UNCONN 0      0            0.0.0.0:25565      0.0.0.0:*
`

func TestParseSS(t *testing.T) {
	ls := parseSS(ssSample)
	if len(ls) != 11 {
		t.Fatalf("got %d listeners: %+v", len(ls), ls)
	}
	want := map[int]listener{
		0:  {"tcp", "0.0.0.0", "8989", "Sonarr"},
		2:  {"tcp", "::", "443", "nginx"},
		5:  {"tcp", "::1", "8085", "zitadel"},
		6:  {"tcp", "100.64.0.13", "8094", "litellm"},
		7:  {"tcp", "*", "3032", "forgejo"},
		10: {"udp", "0.0.0.0", "25565", ""},
	}
	for i, w := range want {
		if ls[i] != w {
			t.Errorf("line %d: %+v, want %+v", i, ls[i], w)
		}
	}
}

func TestAuditListeners(t *testing.T) {
	svcs := []Service{
		{Name: "forgejo", Host: "h001", TCPPorts: []int{3032}},
		{Name: "immich", Host: "h001", Routes: map[string]Route{"ml": {Port: 3003, Proto: "http", Exposure: "local"}}},
		{Name: "mc", Host: "h003", Routes: map[string]Route{"game": {Port: 25565, Proto: "udp", Exposure: "public"}}},
	}
	rows := auditListeners(parseSS(ssSample), svcs, "h001")
	got := map[string]string{}
	for _, r := range rows {
		got[r.Proto+"/"+r.Port+"@"+r.Addr] = r.Status
	}
	want := map[string]string{
		"tcp/8989@0.0.0.0":     "UNDECLARED",
		"tcp/443@0.0.0.0":      "host",
		"tcp/443@::":           "host",
		"tcp/22@0.0.0.0":       "host",
		"tcp/8094@100.64.0.13": "UNDECLARED",
		"tcp/3032@*":           "declared",
		"tcp/3003@0.0.0.0":     "UNDECLARED", // declared local, yet on the network
		"udp/41641@0.0.0.0":    "host",
		"udp/25565@0.0.0.0":    "UNDECLARED", // mc is declared on h003, not here
	}
	if len(got) != len(want) {
		t.Errorf("rows: %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %q, want %q", k, got[k], v)
		}
	}
	if rows[0].Status != "UNDECLARED" {
		t.Errorf("undeclared should sort first: %+v", rows[0])
	}
	if tbl := auditTable(rows); !strings.Contains(tbl, "4 undeclared") {
		t.Errorf("table:\n%s", tbl)
	}
}

func TestAuditListenersHTTPBackendMustBeLoopback(t *testing.T) {
	svcs := []Service{
		{Name: "sec", Host: "h001", Routes: map[string]Route{
			"web": {Port: 8300, Proto: "http", Exposure: "public", Auth: sp("native-oidc")},
		}},
		{Name: "mc", Host: "h001", Routes: map[string]Route{
			"game": {Port: 25565, Proto: "tcp", Exposure: "public"},
		}},
	}

	// (1) http backend bound to 0.0.0.0 must be flagged, even though its
	// route is "public" (that exposure governs the nginx vhost, not a raw
	// listen address).
	exposed := `tcp   LISTEN 0      4096         0.0.0.0:8300       0.0.0.0:*    users:(("secrets_manager",pid=7,fd=3))
`
	rows := auditListeners(parseSS(exposed), svcs, "h001")
	if len(rows) != 1 || rows[0].Status != "UNDECLARED" {
		t.Fatalf("want 1 UNDECLARED row, got %+v", rows)
	}
	wantOwner := "sec.web is an http backend; must listen on loopback only (nginx proxies it)"
	if rows[0].Owner != wantOwner {
		t.Errorf("owner = %q, want %q", rows[0].Owner, wantOwner)
	}

	// (2) the same port bound to loopback is fine: no row at all.
	loopback := `tcp   LISTEN 0      4096       127.0.0.1:8300       0.0.0.0:*    users:(("secrets_manager",pid=7,fd=3))
`
	if rows := auditListeners(parseSS(loopback), svcs, "h001"); len(rows) != 0 {
		t.Errorf("loopback http backend should not be listed: %+v", rows)
	}

	// (3) a public tcp route (not http) still counts as declared.
	tcpPublic := `tcp   LISTEN 0      4096         0.0.0.0:25565      0.0.0.0:*    users:(("mc",pid=9,fd=3))
`
	rows = auditListeners(parseSS(tcpPublic), svcs, "h001")
	if len(rows) != 1 || rows[0].Status != "declared" {
		t.Fatalf("want 1 declared row, got %+v", rows)
	}
}

func TestAuditListenersHostProcesses(t *testing.T) {
	ss := `tcp   LISTEN 0      4096     100.64.0.13:43119      0.0.0.0:*    users:(("tailscaled",pid=5,fd=20))
tcp   LISTEN 0      4096  [fd7a:115c:a1e0::d]:42415    [::]:*    users:(("tailscaled",pid=5,fd=21))
tcp   LISTEN 0      4096     100.64.0.13:41000      0.0.0.0:*    users:((".tailscaled-wra",pid=5,fd=22))
tcp   LISTEN 0      4096     10.12.14.20:43120      0.0.0.0:*    users:(("tailscaled",pid=5,fd=23))
tcp   LISTEN 0      4096     100.64.0.13:43121      0.0.0.0:*    users:(("evil",pid=6,fd=3))
tcp   LISTEN 0      4096         0.0.0.0:5355       0.0.0.0:*    users:(("systemd-resolve",pid=8,fd=12))
udp   UNCONN 0      0               [::]:5355          [::]:*    users:(("systemd-resolve",pid=8,fd=13))
tcp   LISTEN 0      4096         0.0.0.0:5355       0.0.0.0:*    users:(("other",pid=9,fd=3))
`
	rows := auditListeners(parseSS(ss), nil, "h001")
	got := map[string]auditRow{}
	for _, r := range rows {
		got[r.Proto+"/"+r.Port+"@"+r.Addr+"#"+r.Process] = r
	}
	want := map[string]string{
		"tcp/43119@100.64.0.13#tailscaled":       "host",
		"tcp/42415@fd7a:115c:a1e0::d#tailscaled": "host",
		"tcp/41000@100.64.0.13#.tailscaled-wra":  "host",
		"tcp/43120@10.12.14.20#tailscaled":       "UNDECLARED", // LAN IP: not tailnet
		"tcp/43121@100.64.0.13#evil":             "UNDECLARED", // tailnet addr, wrong process
		"tcp/5355@0.0.0.0#systemd-resolve":       "host",
		"udp/5355@::#systemd-resolve":            "host",
	}
	for k, v := range want {
		if r, ok := got[k]; !ok || r.Status != v {
			t.Errorf("%s: %+v, want %s", k, r, v)
		}
	}
	if o := got["tcp/5355@0.0.0.0#systemd-resolve"].Owner; !strings.Contains(o, "llmnr") {
		t.Errorf("llmnr owner = %q", o)
	}
	if o := got["tcp/43119@100.64.0.13#tailscaled"].Owner; !strings.Contains(o, "tailscaled") {
		t.Errorf("tailscaled owner = %q", o)
	}
	// The second 5355 listener (other process) is deduped by addr; make sure
	// a non-resolved process on 5355 alone stays UNDECLARED.
	other := `tcp   LISTEN 0      4096         0.0.0.0:5355       0.0.0.0:*    users:(("other",pid=9,fd=3))
`
	if r := auditListeners(parseSS(other), nil, "h001"); len(r) != 1 || r[0].Status != "UNDECLARED" {
		t.Errorf("5355 by another process: %+v", r)
	}
}

func TestRoutesTable(t *testing.T) {
	tbl := routesTable([]Service{{Name: "sec", Host: "h001", Routes: map[string]Route{"web": httpRoute("secrets", 8300, "public", "native-oidc")}}})
	if !strings.Contains(tbl, "secrets.joshuabell.xyz") || !strings.Contains(tbl, "native-oidc") || !strings.Contains(tbl, "edge") {
		t.Errorf("table:\n%s", tbl)
	}
}

func TestSudoNeedsPassword(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{errors.New("exit status 1: sudo: a password is required"), true},
		{errors.New("exit status 255: ssh: connect to host h001 port 22: Connection refused"), false},
	}
	for _, c := range cases {
		if got := sudoNeedsPassword(c.err); got != c.want {
			t.Errorf("sudoNeedsPassword(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestCmdAuditStdin(t *testing.T) {
	oldInv := inv
	t.Cleanup(func() { inv = oldInv })
	inv = &Inventory{Services: map[string]Service{
		"mc": {Name: "mc", Host: "h001", TCPPorts: []int{25565}},
	}}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.WriteString(`tcp   LISTEN 0      4096       0.0.0.0:25565      0.0.0.0:*    users:(("java",pid=1,fd=5))
`)
	w.Close()
	oldStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = oldStdin })

	oldStdout := os.Stdout
	outR, outW, _ := os.Pipe()
	os.Stdout = outW
	err = cmdAudit([]string{"h001", "--stdin"})
	outW.Close()
	os.Stdout = oldStdout
	if err != nil {
		t.Fatalf("cmdAudit: %v", err)
	}
	buf := make([]byte, 4096)
	n, _ := outR.Read(buf)
	out := string(buf[:n])
	if !strings.Contains(out, "declared") || !strings.Contains(out, "25565") {
		t.Errorf("output:\n%s", out)
	}
}

func TestCmdAuditStdinRequiresOneHost(t *testing.T) {
	oldInv := inv
	t.Cleanup(func() { inv = oldInv })
	inv = &Inventory{Services: map[string]Service{}}
	if err := cmdAudit([]string{"h001", "h002", "--stdin"}); err == nil {
		t.Fatal("expected error for --stdin with multiple hosts")
	}
}
