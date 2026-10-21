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

// Golden: sec's route as lib.nix normalizes it (maxBody 64k). Public via
// edge: internal server plus edge server.
const secVhostGolden = `# route web: exposure public, auth native-oidc; internal listener
server {
  listen 80;
  listen [::]:80;
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name secrets.joshuabell.xyz;
  include /etc/fleet-containers/nginx-tls.conf;
  if ($fleet_edge_block_internal) {
    return 444;
  }
  client_max_body_size 64k;
  # Strip oauth2-proxy cookies before the backend (ROUTING-PLAN §4).
  set $fleet_cookie $http_cookie;
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  location / {
    proxy_pass http://127.0.0.1:8300;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Cookie $fleet_cookie;
    proxy_set_header X-Auth-Request-User "";
    proxy_set_header X-Auth-Request-Email "";
    proxy_set_header X-Auth-Request-Groups "";
    proxy_buffering on;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
}

# route web: edge listener (only the edge peer; X-Forwarded-For trusted)
server {
  listen 8443;
  listen [::]:8443;
  server_name secrets.joshuabell.xyz;
  include /etc/fleet-containers/nginx-edge-realip.conf;
  if ($fleet_edge_peer = 0) {
    return 444;
  }
  client_max_body_size 64k;
  # Strip oauth2-proxy cookies before the backend (ROUTING-PLAN §4).
  set $fleet_cookie $http_cookie;
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  location / {
    proxy_pass http://127.0.0.1:8300;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Cookie $fleet_cookie;
    proxy_set_header X-Auth-Request-User "";
    proxy_set_header X-Auth-Request-Email "";
    proxy_set_header X-Auth-Request-Groups "";
    proxy_buffering on;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
}
`

// Golden: a tailnet route gets only the internal server.
const litellmVhostGolden = `# route web: exposure tailnet, auth native; internal listener
server {
  listen 80;
  listen [::]:80;
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name litellm.joshuabell.xyz;
  include /etc/fleet-containers/nginx-tls.conf;
  if ($fleet_edge_block_internal) {
    return 444;
  }
  include /etc/fleet-containers/nginx-acl-tailnet.conf;
  client_max_body_size 100m;
  # Strip oauth2-proxy cookies before the backend (ROUTING-PLAN §4).
  set $fleet_cookie $http_cookie;
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  location / {
    proxy_pass http://127.0.0.1:8094;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Cookie $fleet_cookie;
    proxy_set_header X-Auth-Request-User "";
    proxy_set_header X-Auth-Request-Email "";
    proxy_set_header X-Auth-Request-Groups "";
    proxy_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
  }
}
`

// Golden: a gated tailnet route (notes-like): oauth2-proxy locations on the
// internal listener only, allowed_groups, an unauthenticated bypass prefix.
const notesVhostGolden = `# route web: exposure tailnet, auth oauth2-proxy; internal listener
server {
  listen 80;
  listen [::]:80;
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name notes.joshuabell.xyz;
  include /etc/fleet-containers/nginx-tls.conf;
  if ($fleet_edge_block_internal) {
    return 444;
  }
  include /etc/fleet-containers/nginx-acl-tailnet.conf;
  client_max_body_size 0;
  # Strip oauth2-proxy cookies before the backend (ROUTING-PLAN §4).
  set $fleet_cookie $http_cookie;
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  if ($fleet_cookie ~ "^(.*?)(?:^|;\s*)_oauth2_proxy[A-Za-z0-9_]*=[^;]*(.*)$") {
    set $fleet_cookie $1$2;
  }
  # auth = oauth2-proxy: fleet oauth2-proxy on h005 (ROUTING-PLAN §8 step 6).
  location = /oauth2/auth {
    proxy_pass http://100.64.0.3:4180/oauth2/auth?allowed_groups=notes;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Uri $request_uri;
  }
  location /oauth2/ {
    proxy_pass http://100.64.0.3:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Uri $request_uri;
  }
  location @fleet_oauth2_signin {
    return 302 https://sso-proxy.joshuabell.xyz/oauth2/start?rd=https://$host$request_uri;
  }
  location / {
    auth_request /oauth2/auth;
    error_page 401 = @fleet_oauth2_signin;
    auth_request_set $fleet_auth_user $upstream_http_x_auth_request_user;
    auth_request_set $fleet_auth_email $upstream_http_x_auth_request_email;
    auth_request_set $fleet_auth_groups $upstream_http_x_auth_request_groups;
    auth_request_set $fleet_auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $fleet_auth_cookie;
    proxy_pass http://127.0.0.1:9111;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Cookie $fleet_cookie;
    proxy_set_header X-Auth-Request-User $fleet_auth_user;
    proxy_set_header X-Auth-Request-Email $fleet_auth_email;
    proxy_set_header X-Auth-Request-Groups $fleet_auth_groups;
    proxy_buffering on;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
  location ^~ /api/ {
    proxy_pass http://127.0.0.1:9111;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Cookie $fleet_cookie;
    proxy_set_header X-Auth-Request-User "";
    proxy_set_header X-Auth-Request-Email "";
    proxy_set_header X-Auth-Request-Groups "";
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
		t.Fatalf("public vhost mismatch:\n%s\nwant:\n%s", got, secVhostGolden)
	}
	l := httpRoute("litellm", 8094, "tailnet", "native")
	l.Via, l.Buffering, l.Timeouts = nil, false, "600s"
	if got := routesVhost(Service{Name: "litellm", Routes: map[string]Route{"web": l}}); got != litellmVhostGolden {
		t.Fatalf("tailnet vhost mismatch:\n%s\nwant:\n%s", got, litellmVhostGolden)
	}
}

func TestRoutesVhostEdgeOnlyForPublicViaEdge(t *testing.T) {
	off := false
	cases := []struct {
		name string
		r    Route
		edge bool
	}{
		{"public edge", httpRoute("a", 1, "public", "native"), true},
		{"lan", func() Route { r := httpRoute("a", 1, "lan", "native"); r.Via = nil; return r }(), false},
		{"public router only", func() Route { r := httpRoute("a", 1, "public", "native"); r.Via = []string{"router"}; return r }(), false},
		{"public edge+router", func() Route {
			r := httpRoute("a", 1, "public", "native")
			r.Via = []string{"router", "edge"}
			r.RequestBuffering = &off
			return r
		}(), true},
	}
	for _, c := range cases {
		v := routesVhost(Service{Name: "x", Routes: map[string]Route{"web": c.r}})
		if got := strings.Contains(v, "listen 8443;"); got != c.edge {
			t.Errorf("%s: edge server=%v want %v\n%s", c.name, got, c.edge, v)
		}
		if strings.Count(v, "nginx-edge-realip.conf") != map[bool]int{true: 1, false: 0}[c.edge] {
			t.Errorf("%s: real_ip must be on the edge server only\n%s", c.name, v)
		}
		if c.r.RequestBuffering != nil && strings.Count(v, "proxy_request_buffering off;") != 2 {
			t.Errorf("%s: requestBuffering=false must reach both servers\n%s", c.name, v)
		}
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

func TestPrepareScriptNginxGating(t *testing.T) {
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}}
	priv := httpRoute("localai", 8080, "tailnet", "none")
	priv.Zone = sp("private")
	pub := httpRoute("chat", 8084, "public", "native")
	tcp := Route{Port: 3032, Proto: "tcp", Exposure: "tailnet", Auth: sp("native")}
	cases := []struct {
		name   string
		routes map[string]Route
		vhost  bool
	}{
		{"private only (localai on joe)", map[string]Route{"web": priv}, false},
		{"tcp only", map[string]Route{"hub": tcp}, false},
		{"no routes", nil, false},
		{"private + tcp", map[string]Route{"web": priv, "raw": tcp}, false},
		{"public", map[string]Route{"web": pub}, true},
		{"public + private", map[string]Route{"web": pub, "p": priv}, true},
	}
	for _, c := range cases {
		ps := prepareScript(Service{Name: "svc", Routes: c.routes}, "joe")
		if got := strings.Contains(ps, "nginx -t"); got != c.vhost {
			t.Errorf("%s: nginx -t present=%v, want %v\n%s", c.name, got, c.vhost, ps)
		}
		if !c.vhost && !strings.Contains(ps, "rm -f /var/lib/fleet-containers/nginx/svc.conf.broken") {
			t.Errorf("%s: should clear stale .broken site", c.name)
		}
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

func TestSiteScriptVhostOnly(t *testing.T) {
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}}
	s := Service{Name: "sec", Routes: map[string]Route{"web": httpRoute("secrets", 8300, "public", "native-oidc")}}
	ss := siteScript(s, "h001")
	if !strings.Contains(ss, "listen 8443;") || !strings.Contains(ss, "nginx -t") {
		t.Errorf("site script lacks edge server or validation:\n%s", ss)
	}
	if strings.Contains(ss, "ports/") || strings.Contains(ss, "/srv/containers") {
		t.Errorf("site script must only touch nginx:\n%s", ss)
	}
	if ps := prepareScript(s, "h001"); !strings.Contains(ps, ss) {
		t.Error("prepareScript must embed siteScript")
	}
}

func TestRoutesVhostOauth2Proxy(t *testing.T) {
	n := httpRoute("notes", 9111, "tailnet", "oauth2-proxy")
	n.Via, n.MaxBody = nil, "0"
	n.Groups, n.Bypass = []string{"notes"}, []string{"/api/"}
	if got := routesVhost(Service{Name: "trilium", Routes: map[string]Route{"web": n}}); got != notesVhostGolden {
		t.Fatalf("gated vhost mismatch:\n%s\nwant:\n%s", got, notesVhostGolden)
	}
	// Public + gated: both listeners get the gate; no groups -> no query.
	p := httpRoute("app", 1, "public", "oauth2-proxy")
	v := routesVhost(Service{Name: "app", Routes: map[string]Route{"web": p}})
	if strings.Count(v, "auth_request /oauth2/auth;") != 2 || strings.Count(v, "location = /oauth2/auth {") != 2 ||
		strings.Contains(v, "allowed_groups") || strings.Count(v, "return 302 https://sso-proxy.joshuabell.xyz/oauth2/start?rd=https://$host$request_uri;") != 2 {
		t.Errorf("public gated vhost:\n%s", v)
	}
	// Ungated routes still strip the cookie and blank identity headers.
	u := routesVhost(Service{Name: "a", Routes: map[string]Route{"web": httpRoute("a", 1, "tailnet", "native")}})
	if strings.Contains(u, "auth_request") || !strings.Contains(u, "proxy_set_header Cookie $fleet_cookie;") ||
		!strings.Contains(u, `proxy_set_header X-Auth-Request-User "";`) {
		t.Errorf("ungated vhost:\n%s", u)
	}
}

func TestValidateRoutesOauth2(t *testing.T) {
	g := httpRoute("a", 80, "tailnet", "oauth2-proxy")
	g.Groups, g.Bypass = []string{"notes"}, []string{"/api/"}
	for name, c := range map[string]struct {
		mut func(*Route)
		err string
	}{
		"ok":            {func(r *Route) {}, ""},
		"groups+native": {func(r *Route) { r.Auth = sp("native") }, "only apply"},
		"bad group":     {func(r *Route) { r.Groups = []string{"a,b"} }, "group"},
		"bad bypass":    {func(r *Route) { r.Bypass = []string{"api; x"} }, "bypass"},
	} {
		r := g
		c.mut(&r)
		err := validateRoutes(Service{Name: "a", Routes: map[string]Route{"web": r}})
		if c.err == "" && err != nil || c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)) {
			t.Errorf("%s: err = %v, want %q", name, err, c.err)
		}
	}
}

// Exposure ACL (ROUTING-PLAN §2.1): tailnet/lan internal servers include
// their host-module ACL at server level, after the edge-peer 444 and before
// any location (so /oauth2/ and auth_request inherit it); public internal
// and edge servers get none.
func TestRoutesVhostExposureACL(t *testing.T) {
	for _, c := range []struct {
		exposure, auth, acl string
	}{
		{"tailnet", "native", "/etc/fleet-containers/nginx-acl-tailnet.conf"},
		{"tailnet", "oauth2-proxy", "/etc/fleet-containers/nginx-acl-tailnet.conf"},
		{"lan", "native", "/etc/fleet-containers/nginx-acl-lan.conf"},
		{"lan", "oauth2-proxy", "/etc/fleet-containers/nginx-acl-lan.conf"},
		{"public", "native", ""},
		{"public", "oauth2-proxy", ""},
	} {
		r := httpRoute("a", 1, c.exposure, c.auth)
		if c.exposure != "public" {
			r.Via = nil
		}
		v := routesVhost(Service{Name: "x", Routes: map[string]Route{"web": r}})
		name := c.exposure + "/" + c.auth
		if c.acl == "" {
			if strings.Contains(v, "nginx-acl-") || strings.Contains(v, "deny ") {
				t.Errorf("%s: public route must have no ACL\n%s", name, v)
			}
			if !strings.Contains(v, "listen 8443;") {
				t.Errorf("%s: public edge server missing\n%s", name, v)
			}
			continue
		}
		if strings.Count(v, "nginx-acl-") != 1 || strings.Count(v, "server {") != 1 {
			t.Errorf("%s: want exactly one internal server with one ACL\n%s", name, v)
			continue
		}
		inc := strings.Index(v, "  include "+c.acl+";\n")
		block := strings.Index(v, "$fleet_edge_block_internal")
		loc := strings.Index(v, "  location ")
		if inc < 0 || block < 0 || loc < 0 || !(block < inc && inc < loc) {
			t.Errorf("%s: ACL must be server level, after edge block, before locations\n%s", name, v)
		}
	}
}

func TestValidateRoutesRejectsLocationACL(t *testing.T) {
	for _, x := range []string{"allow 0.0.0.0/0;", "  deny all;", "satisfy any;"} {
		r := httpRoute("a", 1, "tailnet", "native")
		r.ExtraConfig = "send_timeout 1s;\n" + x
		err := validateRoutes(Service{Name: "a", Routes: map[string]Route{"web": r}})
		if err == nil || !strings.Contains(err.Error(), "exposure is the ACL") {
			t.Errorf("%q: err=%v", x, err)
		}
	}
}
