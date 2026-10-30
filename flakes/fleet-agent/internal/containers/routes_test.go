package containers

import (
	"context"

	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func sp(s string) *string { return &s }

func httpRoute(name string, port int, exposure, auth string) Route {
	return Route{Port: port, Proto: "http", Exposure: exposure, Auth: sp(auth), Via: []string{"edge"},
		Name: sp(name), FQDN: sp(name + ".joshuabell.xyz"), URL: sp("https://" + name + ".joshuabell.xyz"),
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
  # Fail closed: more matching cookies than rounds -> drop the whole header.
  if ($fleet_cookie ~ "_oauth2_proxy") {
    set $fleet_cookie "";
  }
  # Tidy a leftover "; " prefix when the first cookie was stripped.
  if ($fleet_cookie ~ "^;\s*(.*)$") {
    set $fleet_cookie $1;
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
  # Fail closed: more matching cookies than rounds -> drop the whole header.
  if ($fleet_cookie ~ "_oauth2_proxy") {
    set $fleet_cookie "";
  }
  # Tidy a leftover "; " prefix when the first cookie was stripped.
  if ($fleet_cookie ~ "^;\s*(.*)$") {
    set $fleet_cookie $1;
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
  # Fail closed: more matching cookies than rounds -> drop the whole header.
  if ($fleet_cookie ~ "_oauth2_proxy") {
    set $fleet_cookie "";
  }
  # Tidy a leftover "; " prefix when the first cookie was stripped.
  if ($fleet_cookie ~ "^;\s*(.*)$") {
    set $fleet_cookie $1;
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
  # Fail closed: more matching cookies than rounds -> drop the whole header.
  if ($fleet_cookie ~ "_oauth2_proxy") {
    set $fleet_cookie "";
  }
  # Tidy a leftover "; " prefix when the first cookie was stripped.
  if ($fleet_cookie ~ "^;\s*(.*)$") {
    set $fleet_cookie $1;
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
web 100.64.0.0/10
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
	tailnetRoute := httpRoute("localai", 8080, "tailnet", "none")
	pub := httpRoute("chat", 8084, "public", "native")
	tcp := Route{Port: 3032, Proto: "tcp", Exposure: "tailnet", Auth: sp("native")}
	cases := []struct {
		name   string
		routes map[string]Route
		vhost  bool
	}{
		{"tailnet only (localai on joe)", map[string]Route{"web": tailnetRoute}, true},
		{"tcp only", map[string]Route{"hub": tcp}, false},
		{"no routes", nil, false},
		{"tailnet + tcp", map[string]Route{"web": tailnetRoute, "raw": tcp}, true},
		{"public", map[string]Route{"web": pub}, true},
		{"public + tailnet", map[string]Route{"web": pub, "p": tailnetRoute}, true},
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
	if err := cmdAudit([]string{"h001", "h002", "--stdin"}); err != nil {
		t.Fatalf("audit diagnostics must exit zero: %v", err)
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

func TestBackendAddrPrivate(t *testing.T) {
	nixIP := "10.233.5.2"
	podIP := "10.89.250.102"
	cases := []struct {
		name string
		s    Service
		want string
	}{
		{"nixos private", Service{Kind: "nixos", Net: Net{Private: true, IP: &nixIP}}, "10.233.5.2"},
		{"podman private", Service{Kind: "podman", Net: Net{Private: true, IP: &podIP}}, "10.89.250.102"},
		{"nixos host-network", Service{Kind: "nixos", Net: Net{Private: false}}, "127.0.0.1"},
		{"podman host-network", Service{Kind: "podman", Net: Net{Private: false}}, "127.0.0.1"},
	}
	for _, c := range cases {
		if got := backendAddr(c.s); got != c.want {
			t.Errorf("%s: backendAddr = %q, want %q", c.name, got, c.want)
		}
	}
}

// Golden: opengist and localai (podman, net.private) proxy straight to the
// static bridge IP (offset past the .1 gateway and podman's dynamic-IPAM
// low range), no loopback involved (ROUTING-PLAN §8 step 5 podman follow-up).
func TestRoutesVhostPodmanPrivateBackend(t *testing.T) {
	ip := "10.89.250.102"
	r := httpRoute("gist", 6157, "public", "native")
	s := Service{Name: "opengist", Kind: "podman", Net: Net{Private: true, IP: &ip}, Routes: map[string]Route{"web": r}}
	v := routesVhost(s)
	if !strings.Contains(v, "proxy_pass http://10.89.250.102:6157;") {
		t.Errorf("opengist vhost must proxy to the bridge IP, not loopback:\n%s", v)
	}
	if strings.Contains(v, "127.0.0.1") {
		t.Errorf("opengist vhost must not mention loopback:\n%s", v)
	}
}

// prepareScript's net.private host-prerequisite check must match the kind:
// nixos guests need the veth/NAT side (privateNetwork.enable ->
// fleet-net-nat), podman services ride the always-present fleet-noinet
// table (cfg.enable) instead and must not demand privateNetwork.enable.
func TestPrepareScriptPrivateCheckByKind(t *testing.T) {
	ip := "10.89.250.102"
	nixIP := "10.233.5.2"
	podman := Service{Name: "localai", Kind: "podman", Net: Net{Private: true, IP: &ip}}
	nixos := Service{Name: "atuin", Kind: "nixos", Net: Net{Private: true, IP: &nixIP}}

	ps := prepareScript(podman, "joe")
	if !strings.Contains(ps, "nft list table inet fleet-noinet") {
		t.Errorf("podman net.private must check fleet-noinet, got:\n%s", ps)
	}
	if strings.Contains(ps, "fleet-net-nat") || strings.Contains(ps, "privateNetwork.enable") {
		t.Errorf("podman net.private must not require privateNetwork.enable:\n%s", ps)
	}

	ps = prepareScript(nixos, "h001")
	if !strings.Contains(ps, "nft list table ip fleet-net-nat") || !strings.Contains(ps, "privateNetwork.enable") {
		t.Errorf("nixos net.private must still check fleet-net-nat/privateNetwork.enable:\n%s", ps)
	}
	if strings.Contains(ps, "fleet-noinet") {
		t.Errorf("nixos net.private must not check fleet-noinet:\n%s", ps)
	}
}

// srcPortLines is the runtime half of ROUTING-PLAN 8.2: the 80/443
// admission for one service, from its own routes at the host it is being
// deployed to (applyPorts turns the lines into @src/@src6/@src_lan). No
// host-keyed map: a service reaches its own vhost wherever it lands.
func TestSrcPortLines(t *testing.T) {
	old := inv
	defer func() { inv = old }()

	lio, gp3, h001 := "100.64.0.1", "100.64.0.15", "100.64.0.13"
	inv = &Inventory{
		LanSubnet: "10.12.14.0/24",
		Hosts: map[string]Host{
			"lio": {OverlayIP: &lio}, "gp3": {OverlayIP: &gp3}, "h001": {OverlayIP: &h001},
		},
	}
	if got := srcPortLines(Service{Name: "x"}, "h001"); got != nil {
		t.Errorf("no routes: got %v, want nil", got)
	}

	// No allow: the whole tailnet range, the same literal lib.nix uses.
	s := Service{Name: "trilium", Routes: map[string]Route{"web": httpRoute("notes", 8300, "tailnet", "native")}}
	if got, want := strings.Join(srcPortLines(s, "lio"), "|"), "web 100.64.0.0/10"; got != want {
		t.Errorf("no allow: got %q want %q", got, want)
	}

	// allow: exactly the named overlay IPs; unknown names are dropped.
	r := httpRoute("notes", 8300, "tailnet", "native")
	r.Allow = []string{"lio", "nosuch", "gp3"}
	s = Service{Name: "trilium", Routes: map[string]Route{"web": r}}
	if got, want := strings.Join(srcPortLines(s, "lio"), "|"), "web 100.64.0.1|web 100.64.0.15"; got != want {
		t.Errorf("allow: got %q want %q", got, want)
	}

	// Deployed onto a host that declares no services: the lines still come
	// from the service's own routes (the old per-host map wrote nothing).
	if got := srcPortLines(s, "h004"); len(got) == 0 {
		t.Errorf("routes on a host without declared services must still admit: %v", got)
	}

	// local-only: nothing to admit.
	s = Service{Name: "searx", Routes: map[string]Route{"api": httpRoute("searx", 8080, "local", "native")}}
	if got := srcPortLines(s, "h001"); got != nil {
		t.Errorf("local-only: got %v, want nil", got)
	}

	// LAN: a lan route opens @src_lan; a public route via the router does
	// not (its LAN clients arrive with the WAN source, ROUTING-PLAN 8.2).
	r = httpRoute("dash", 8080, "lan", "native")
	r.Via = nil
	s = Service{Name: "dash", Routes: map[string]Route{"web": r}}
	if got, want := strings.Join(srcPortLines(s, "h003"), "|"), "web 100.64.0.0/10|weblan 10.12.14.0/24"; got != want {
		t.Errorf("lan: got %q want %q", got, want)
	}
	r = httpRoute("minecraft", 8080, "public", "native")
	r.Via = []string{"router"}
	s = Service{Name: "minecraft", Routes: map[string]Route{"web": r}}
	if got, want := strings.Join(srcPortLines(s, "h003"), "|"), "web 100.64.0.0/10"; got != want {
		t.Errorf("via router: got %q want %q", got, want)
	}
	// No lanSubnet: no weblan line (an empty element would be a syntax
	// error, and a zero-length CIDR would admit nothing useful).
	inv.LanSubnet = ""
	r = httpRoute("dash", 8080, "lan", "native")
	r.Via = nil
	s = Service{Name: "dash", Routes: map[string]Route{"web": r}}
	if got, want := strings.Join(srcPortLines(s, "h003"), "|"), "web 100.64.0.0/10"; got != want {
		t.Errorf("empty lanSubnet: got %q want %q", got, want)
	}
	// A caller with no http route of its own contributes no lines: the
	// admission it needs is written into the callee's ports file.
	inv.LanSubnet = "10.12.14.0/24"
	life := Service{Name: "life", Host: "h001", Net: Net{Private: true, IP: sp("10.233.4.2"),
		Uses: []string{"zitadel.web"}}}
	if got := srcPortLines(life, "h001"); got != nil {
		t.Errorf("caller: got %v, want nil", got)
	}
}

// prepareScript writes this service's srcPortLines into its own ports file,
// before the prune/reload block, so applyPorts refills the sets from every
// file on each deploy and prunes from the same pass.
func TestPrepareScriptWebSources(t *testing.T) {
	old := inv
	defer func() { inv = old }()
	inv = &Inventory{DataRoot: "/srv/containers", Hosts: map[string]Host{}, LanSubnet: "10.12.14.0/24"}
	s := Service{Name: "sec", Routes: map[string]Route{"web": httpRoute("secrets", 8300, "public", "native-oidc")}}
	ps := prepareScript(s, "h001")
	want := "web 100.64.0.0/10\nweblan 10.12.14.0/24\n"
	printf := strings.Index(ps, "printf %s '")
	prune := strings.Index(ps, "while read -r pr po mode _")
	i := strings.Index(ps, want)
	if printf < 0 || prune < 0 || i < printf || i > prune {
		t.Fatalf("web/weblan lines must be in the ports body, before the prune block:\n%s", ps)
	}
	// A service with no http routes (minecraft's are tcp) writes none.
	s = Service{Name: "mc", Routes: map[string]Route{"game": Route{Port: 25565, Proto: "tcp", Exposure: "public", Via: []string{"router"}}}}
	if ps := prepareScript(s, "h001"); strings.Contains(ps, "web 100.64") || strings.Contains(ps, "weblan") {
		t.Errorf("no http routes, must write no web lines:\n%s", ps)
	}
}

// ---------------------------------------------------------- net.uses admission

// useRig fakes the inventory and the live placement sweep for the net.uses
// tests: hosts answers `installed`, the hosts listed in down fail to answer.
// localHost is pinned away from every test host so the sweep probes them all
// instead of shortcutting to this machine's gcroots.
func useRig(t *testing.T, svcs map[string]Service, installed map[string][]string, down ...string) {
	t.Helper()
	oldInv, oldDry, oldLocal, orig, oldRetired := inv, dryRun, localHost, fleetProbe, retired
	t.Cleanup(func() {
		inv, dryRun, localHost, fleetProbe = oldInv, oldDry, oldLocal, orig
		retired = oldRetired
		resetFleetPlacement()
	})
	lio, gp3, h001, h003 := "100.64.0.1", "100.64.0.15", "100.64.0.13", "100.64.0.31"
	inv = &Inventory{
		LanSubnet:      "10.12.14.0/24",
		Services:       svcs,
		ContainerHosts: []string{"h001", "h003", "gp3"},
		Hosts: map[string]Host{
			"lio": {OverlayIP: &lio}, "gp3": {OverlayIP: &gp3},
			"h001": {OverlayIP: &h001}, "h003": {OverlayIP: &h003},
		},
	}
	localHost = "not-a-fleet-host"
	fleetProbe = fakeFleet(installed, down...)
	dryRun = false
	resetFleetPlacement()
}

// captureStderr runs f and returns what it wrote to stderr.
func captureStderr(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	must(t, err)
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	f()
	w.Close()
	os.Stdout, os.Stderr = oldOut, oldErr
	var b strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		b.Write(buf[:n])
		if err != nil {
			break
		}
	}
	r.Close()
	return b.String()
}

// allowCallee is an http vhost that only lio may read, so every other web
// line in its ports file is a net.uses admission.
func allowCallee(host string) Service {
	r := httpRoute("app", 8300, "tailnet", "native")
	r.Allow = []string{"lio"}
	return Service{Name: "app", Host: host, Routes: map[string]Route{"web": r}}
}

func usingCaller(declared string) Service {
	return Service{Name: "life", Host: declared, Net: Net{Private: true, IP: sp("10.233.4.2"),
		Uses: []string{"app.web"}}}
}

// The callee admits the caller where discovery finds it, not where its
// service.nix says: a moved caller still reaches the vhost.
func TestSrcPortLinesUsesCallerHost(t *testing.T) {
	callee := allowCallee("h003")
	// Declared h001, actually running on gp3: h001's overlay IP must not be
	// admitted, gp3's must.
	useRig(t, map[string]Service{"app": callee, "life": usingCaller("h001")},
		map[string][]string{"h003": {"app+"}, "gp3": {"life+"}})
	if got, want := strings.Join(srcPortLines(callee, "h003"), "|"), "web 100.64.0.1|web 100.64.0.15"; got != want {
		t.Errorf("caller on gp3: got %q want %q", got, want)
	}
}

// A caller installed on two hosts (a stale copy nobody removed, plus the live
// one) may dial out from either, so both hosts are admitted and the declared
// host of neither is not.
func TestSrcPortLinesUsesEveryCallerHost(t *testing.T) {
	callee := allowCallee("h003")
	useRig(t, map[string]Service{"app": callee, "life": usingCaller("h001")},
		map[string][]string{"h003": {"app+"}, "h001": {"life+"}, "gp3": {"life+"}})
	if got, want := strings.Join(srcPortLines(callee, "h003"), "|"), "web 100.64.0.1|web 100.64.0.13|web 100.64.0.15"; got != want {
		t.Errorf("caller on h001 and gp3: got %q want %q", got, want)
	}
}

// A caller on the callee's own host needs nothing in @src: @guest-egress
// already accepts the guest address, and nginx allows the guest IP.
func TestSrcPortLinesUsesSameHost(t *testing.T) {
	callee := allowCallee("h001")
	useRig(t, map[string]Service{"app": callee, "life": usingCaller("h001")},
		map[string][]string{"h001": {"app+", "life+"}})
	if got, want := strings.Join(srcPortLines(callee, "h001"), "|"), "web 100.64.0.1"; got != want {
		t.Errorf("caller on the callee host: got %q want %q", got, want)
	}
	if v := routesVhost(callee); !strings.Contains(v, "allow 10.233.4.2; # net.uses life") {
		t.Errorf("same-host caller must be allowed by guest IP:\n%s", v)
	}
}

// A sweep that lost a host cannot confirm the caller is nowhere, so it is
// admitted by its declared host, with a warning. That holds whether the host
// that failed was the declared one or some other: the caller may be running
// on the box that did not answer.
func TestSrcPortLinesUsesPartialDiscovery(t *testing.T) {
	for _, c := range []struct{ name, down string }{
		{"declared host down", "h001"},
		{"other host down", "gp3"},
	} {
		t.Run(c.name, func(t *testing.T) {
			callee := allowCallee("h003")
			useRig(t, map[string]Service{"app": callee, "life": usingCaller("h001")},
				map[string][]string{"h003": {"app+"}}, c.down)
			var got []string
			out := captureStderr(t, func() { got = srcPortLines(callee, "h003") })
			if want := "web 100.64.0.1|web 100.64.0.13"; strings.Join(got, "|") != want {
				t.Errorf("%s down: got %v want %s", c.down, got, want)
			}
			if !strings.Contains(out, "warning:") || !strings.Contains(out, "did not answer") {
				t.Errorf("stderr lacks a warning that a host did not answer:\n%s", out)
			}
		})
	}
}

// Every host answered and nobody has the caller: it was destroyed (or never
// deployed), so nothing is admitted. Falling back to the declared host here
// would re-admit a service that `cnt destroy` has just withdrawn.
func TestSrcPortLinesUsesAbsentCaller(t *testing.T) {
	callee := allowCallee("h003")
	useRig(t, map[string]Service{"app": callee, "life": usingCaller("h001")},
		map[string][]string{"h003": {"app+"}})
	var got []string
	out := captureStderr(t, func() { got = srcPortLines(callee, "h003") })
	if want := "web 100.64.0.1"; strings.Join(got, "|") != want {
		t.Errorf("absent caller admitted: got %v want %s", got, want)
	}
	if strings.Contains(out, "warning:") {
		t.Errorf("a simply-absent caller is not a warning:\n%s", out)
	}
}

// The two answers above come from one predicate, so pin it directly: only a
// complete sweep may report an absent service as known-absent.
func TestPlacesRequiresCompleteSweep(t *testing.T) {
	cases := []struct {
		name  string
		p     fleetPlacement
		want  []string
		known bool
	}{
		{"complete, absent", fleetPlacement{found: map[string][]string{}, down: map[string]bool{}}, nil, true},
		{"declared host down", fleetPlacement{found: map[string][]string{},
			down: map[string]bool{"h001": true}}, []string{"h001"}, false},
		{"other host down", fleetPlacement{found: map[string][]string{},
			down: map[string]bool{"gp3": true}}, []string{"h001"}, false},
		{"found on one host, another down", fleetPlacement{
			found: map[string][]string{"life": {"gp3"}}, down: map[string]bool{"h001": true}},
			[]string{"gp3"}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, known := c.p.places("life", "h001")
			if strings.Join(got, ",") != strings.Join(c.want, ",") || known != c.known {
				t.Errorf("got (%v, %v) want (%v, %v)", got, known, c.want, c.known)
			}
		})
	}
}

// net.uses of a tcp route, or of a route that does not exist, is not a
// nginx admission: netExceptions covers the former, lib.nix the latter.
func TestSrcPortLinesUsesNonHTTP(t *testing.T) {
	callee := Service{Name: "app", Host: "h001", Routes: map[string]Route{
		"web":  httpRoute("app", 8300, "local", "native"),
		"game": {Port: 25565, Proto: "tcp", Exposure: "public", Via: []string{"router"}},
	}}
	caller := Service{Name: "life", Host: "h001", Net: Net{Private: true, IP: sp("10.233.4.2"),
		Uses: []string{"app.game", "app.nosuch"}}}
	useRig(t, map[string]Service{"app": callee, "life": caller},
		map[string][]string{"h001": {"app+"}, "gp3": {"life+"}})
	if got := srcPortLines(callee, "h001"); got != nil {
		t.Errorf("tcp/missing-route uses: got %v, want nil", got)
	}
}

// --------------------------------------------------- refreshing the ports file

// refreshScript rewrites only the web/weblan lines of a live ports file on the
// callee host: no deploy, no site rewrite, no restart of the callee.
func TestRefreshScript(t *testing.T) {
	// One http route open to the whole tailnet, so the fresh admission is a
	// single predictable line.
	callee := Service{Name: "app", Host: "h001",
		Routes: map[string]Route{"web": httpRoute("app", 8300, "tailnet", "native")}}

	for _, c := range []struct {
		name string
		file string // existing content; "" = no file
		awk  bool   // break awk in PATH
		want string // expected content afterwards
		out  string // substring expected on stderr; "" = no warning
	}{
		{"rewrites web lines and keeps the rest",
			"guest ve-app\ntcp 9000 dnat 10.233.9.2 100.64.0.13\nweb 100.64.0.99\nweblan 10.9.9.0/24\n", false,
			"guest ve-app\ntcp 9000 dnat 10.233.9.2 100.64.0.13\nweb 100.64.0.0/10\n", ""},
		{"keeps a file without a trailing newline",
			"guest ve-app\nweb 100.64.0.99", false,
			"guest ve-app\nweb 100.64.0.0/10\n", ""},
		{"missing file", "", false, "",
			"has no ports file on h001 yet; its net.uses admission is unchanged"},
		{"failed write restores the previous file",
			"guest ve-app\nweb 100.64.0.99\n", true,
			"guest ve-app\nweb 100.64.0.99\n", "kept the previous ports file"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newOverrideRig(t)
			// Computed here: the fresh lines come from the inventory the rig
			// installs (no services, so only the route's own admission).
			script := refreshScript(callee, "h001")
			if strings.Contains(script, "'") {
				t.Errorf("the script is single-quoted by sshArgs, so it cannot contain one:\n%s", script)
			}
			if !strings.Contains(script, "web 100.64.0.0/10") {
				t.Errorf("script does not write the fresh admission:\n%s", script)
			}
			if strings.Contains(script, "nginx") {
				t.Errorf("a ports-only refresh must not touch the nginx site:\n%s", script)
			}
			dir := filepath.Join(r.dir, "ports")
			must(t, os.MkdirAll(dir, 0o755))
			p := filepath.Join(dir, "app")
			if c.file != "" {
				must(t, os.WriteFile(p, []byte(c.file), 0o644))
			}
			if c.awk {
				writeExe(t, filepath.Join(r.bin, "awk"), "#!/bin/sh\nexit 2\n")
			}
			cmd := exec.Command(r.bash, "-c", strings.ReplaceAll(script, "/var/lib/fleet-containers", r.dir))
			cmd.Env = append(os.Environ(), "PATH="+r.bin+":"+os.Getenv("PATH"))
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("script failed: %v\n%s", err, out)
			}
			switch got, err := os.ReadFile(p); {
			case c.want == "" && err == nil:
				t.Errorf("ports file should not exist, got %q", got)
			case c.want != "" && err != nil:
				t.Fatalf("ports file gone, want %q: %v", c.want, err)
			case c.want != "" && string(got) != c.want:
				t.Errorf("ports file:\n%q\nwant\n%q", got, c.want)
			}
			for _, leftover := range []string{"app.bak", "app.new"} {
				if exists(filepath.Join(dir, leftover)) {
					t.Errorf("%s left behind", leftover)
				}
			}
			if c.out != "" && !strings.Contains(string(out), c.out) {
				t.Errorf("output lacks %q:\n%s", c.out, out)
			}
			// Without a ports file there is no set to rebuild on that host,
			// so the refresh must not reload anything either.
			log, _ := os.ReadFile(r.log)
			reloaded := strings.Contains(string(log), "reload-or-restart fleet-containers-ports.service")
			if reloaded != (c.file != "") {
				t.Errorf("reloaded=%v, ports file existed=%v:\n%s", reloaded, c.file != "", log)
			}
		})
	}
}

// refreshCallers goes to the host the callee actually runs on and only
// rewrites its ports file: the callee itself keeps running.
func TestRefreshCallersUsesCalleeHost(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src") // declared src, actually running on dst
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	installed := fakeFleet(map[string][]string{"dst": {"app+", "svc+"}}, "src")
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	fleetProbe = installed
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{"src": {User: "root", OverlayIP: sp("100.64.0.11")},
		"dst": {User: "root", OverlayIP: sp("100.64.0.12")},
		// The callee's own `allow lio` must survive the refresh.
		"lio": {OverlayIP: sp("100.64.0.1")}}
	resetFleetPlacement()

	dir := filepath.Join(r.dst+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.11\n"), 0o644))

	refreshCallers(caller)

	// The stale src overlay IP that the wrong-direction admission wrote is
	// gone; the caller now shares dst with the callee, so @guest-egress
	// covers it and only the route's own admission is rewritten.
	if got, want := readFile(t, p), "guest ve-app\nweb 100.64.0.1\n"; got != want {
		t.Errorf("ports file on dst:\n%q\nwant\n%q", got, want)
	}
	calls := r.calls()
	if !strings.Contains(calls, "ssh dst:") {
		t.Errorf("refresh did not run on the callee host:\n%s", calls)
	}
	if strings.Contains(calls, "ssh src:") {
		t.Errorf("refresh ran on the declared host:\n%s", calls)
	}
	if !strings.Contains(calls, "systemctl reload-or-restart fleet-containers-ports.service") {
		t.Errorf("ports sets not reloaded:\n%s", calls)
	}
	for _, bad := range []string{"systemctl stop", "systemctl start", "nginx", "extra-container"} {
		if strings.Contains(calls, bad) {
			t.Errorf("a ports-only refresh must not run %q:\n%s", bad, calls)
		}
	}
	for _, leftover := range []string{"app.bak", "app.new"} {
		if exists(filepath.Join(dir, leftover)) {
			t.Errorf("%s left behind on dst", leftover)
		}
	}
}

// A callee installed on two hosts is stale on one of them: both ports files
// are refreshed, since either may be the one serving -- and only the host the
// caller is not on needs the caller's overlay IP.
func TestRefreshCallersEveryCalleeHost(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	fleetProbe = fakeFleet(map[string][]string{"src": {"app+"}, "dst": {"app+", "svc+"}})
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{"lio": {OverlayIP: sp("100.64.0.1")}, "dst": {OverlayIP: sp("100.64.0.12")}}
	resetFleetPlacement()

	ports := map[string]string{}
	for _, h := range []string{r.root, r.dst} {
		p := filepath.Join(h+".state", "vlfc", "ports")
		must(t, os.MkdirAll(p, 0o755))
		must(t, os.WriteFile(filepath.Join(p, "app"), []byte("guest ve-app\nweb 100.64.0.99\n"), 0o644))
		ports[h] = filepath.Join(p, "app")
	}

	refreshCallers(caller)

	calls := r.calls()
	for _, h := range []string{"src", "dst"} {
		if !strings.Contains(calls, "ssh "+h+":") {
			t.Errorf("callee not refreshed on %s:\n%s", h, calls)
		}
	}
	for h, want := range map[string]string{
		r.dst:  "guest ve-app\nweb 100.64.0.1\n",                  // caller is here
		r.root: "guest ve-app\nweb 100.64.0.1\nweb 100.64.0.12\n", // caller on dst
	} {
		if got := readFile(t, ports[h]); got != want {
			t.Errorf("ports file on %s:\n%q\nwant\n%q", h, got, want)
		}
	}
}

// Destroying a caller must withdraw its admission from the callee's ports
// file, not re-point it at the caller's declared host: the service is gone.
func TestDestroyWithdrawsCallerAdmission(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	fleetProbe = fakeFleet(map[string][]string{"src": {"app+"}})
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{"lio": {OverlayIP: sp("100.64.0.1")}, "dst": {OverlayIP: sp("100.64.0.12")}}
	resetFleetPlacement()

	dir := filepath.Join(r.root+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.1\nweb 100.64.0.12\n"), 0o644))

	if err := cmdDestroy([]string{"svc", "--host", "dst"}); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	if got, want := readFile(t, p), "guest ve-app\nweb 100.64.0.1\n"; got != want {
		t.Errorf("callee still admits the destroyed caller:\n%q\nwant\n%q", got, want)
	}
}

// The withdraw must survive the next CLI run: service.nix still declares the
// destroyed caller, so a fresh inventory lists it again. Discovery is what
// says it is gone, and that must keep its admission out.
func TestDestroyedCallerStaysWithdrawn(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	// dst keeps the overlay IP the stale copy dialled out as, so admitting the
	// declared host would put the withdrawn address straight back.
	hosts := map[string]Host{"src": {User: "root", OverlayIP: sp("100.64.0.1")},
		"dst": {User: "root", OverlayIP: sp("100.64.0.12")}}
	reload := func() { // what loadInventory does on the next command
		inv = &Inventory{DataRoot: r.root, Hosts: hosts,
			Services: map[string]Service{"app": callee, "svc": caller}}
		resetFleetPlacement()
	}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	// svc is gone from the fleet; every host answers.
	fleetProbe = fakeFleet(map[string][]string{"src": {"app+"}})
	reload()

	dir := filepath.Join(r.root+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.1\nweb 100.64.0.12\n"), 0o644))

	if err := cmdDestroy([]string{"svc", "--host", "dst"}); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	reload()
	refreshCallers(caller)

	if got := readFile(t, p); strings.Contains(got, "100.64.0.12") {
		t.Errorf("a destroyed caller is admitted again on the next run:\n%q", got)
	}
}

// The declared-host fallback must respect the retirement too: destroy the only
// copy and have an unrelated host fail to answer, and the fallback would put
// the removed copy straight back on its declared host.
func TestDestroyedCallerNotReadmittedByFallback(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	inv.ContainerHosts = []string{"src", "dst", "h003"}
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{
		"lio":  {User: "root", OverlayIP: sp("100.64.0.1")}, // the route's allow
		"dst":  {User: "root", OverlayIP: sp("100.64.0.12")},
		"h003": {User: "root", OverlayIP: sp("100.64.0.31")},
	}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	// svc was only on dst; h003 is an unrelated host that fails to answer, so
	// the sweep is inconclusive and would hand the declared host back.
	fleetProbe = fakeFleet(map[string][]string{"src": {"app+"}}, "h003")
	resetFleetPlacement()

	dir := filepath.Join(r.root+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.1\nweb 100.64.0.12\n"), 0o644))

	if err := cmdDestroy([]string{"svc", "--host", "dst"}); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	if got, want := readFile(t, p), "guest ve-app\nweb 100.64.0.1\n"; got != want {
		t.Errorf("the fallback re-admitted a destroyed copy:\n%q\nwant\n%q", got, want)
	}
}

// Destroying one copy of a caller must not withdraw the other: only the
// (service, host) pair that was removed stops being admitted, so a copy still
// running elsewhere keeps reaching the callee. The probe here still reports
// the destroyed copy, as a host that has not caught up would.
func TestDestroyOneCopyKeepsTheOther(t *testing.T) {
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	fleetProbe = fakeFleet(map[string][]string{
		"src":  {"app+"},
		"dst":  {"svc+"}, // the copy about to be destroyed, still reported
		"h003": {"svc+"},
	})
	inv.ContainerHosts = []string{"src", "dst", "h003"}
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{
		"lio":  {User: "root", OverlayIP: sp("100.64.0.1")}, // the route's allow
		"dst":  {User: "root", OverlayIP: sp("100.64.0.12")},
		"h003": {User: "root", OverlayIP: sp("100.64.0.31")},
	}
	resetFleetPlacement()

	dir := filepath.Join(r.root+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.1\nweb 100.64.0.12\nweb 100.64.0.31\n"), 0o644))

	if err := cmdDestroy([]string{"svc", "--host", "dst"}); err != nil {
		t.Fatalf("destroy: %v", err)
	}
	if got, want := readFile(t, p), "guest ve-app\nweb 100.64.0.1\nweb 100.64.0.31\n"; got != want {
		t.Errorf("destroying the dst copy:\n%q\nwant\n%q", got, want)
	}
}

// strayRig binds svc to h001 in the registry with a second copy on h003, and
// fails the test on any registry write: removing a stray must never touch the
// row.
func strayRig(t *testing.T, row placementRow) (*rig, Service, string) {
	t.Helper()
	r := newRig(t)
	callee := allowCallee("src")
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "h001",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.web"}}}
	fleetProbe = fakeFleet(map[string][]string{
		"src":  {"app+"},
		"h001": {"svc+"},
		"h003": {"svc+"},
	})
	inv.ContainerHosts = []string{"src", "h001", "h003"}
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	inv.Hosts = map[string]Host{
		"lio":  {User: "root", OverlayIP: sp("100.64.0.1")}, // the route's allow
		"h001": {User: "root", OverlayIP: sp("100.64.0.11")},
		"h003": {User: "root", OverlayIP: sp("100.64.0.31")},
	}
	placementNow = func(bool) *placementView {
		return &placementView{Host: map[string]string{"svc": row.effective()}, Rows: map[string]placementRow{"svc": row}}
	}
	registryCache = nil
	resetFleetPlacement()
	old := edgeClientFor
	t.Cleanup(func() { edgeClientFor = old })
	edgeClientFor = func() (*edgeClient, error) {
		t.Errorf("destroy reached the registry client")
		return nil, errNoToken
	}
	dir := filepath.Join(r.root+".state", "vlfc", "ports")
	must(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "app")
	must(t, os.WriteFile(p, []byte("guest ve-app\nweb 100.64.0.1\nweb 100.64.0.11\nweb 100.64.0.31\n"), 0o644))
	return r, caller, p
}

// A copy on a host the registry does not bind is a stray: `destroy --host`
// removes it there and only there, leaves the row alone, and the bound copy
// keeps its admission in the callee's ports file.
func TestDestroyStrayCopyLeavesTheBinding(t *testing.T) {
	bound := placementRow{Service: "svc", Host: "h001", State: placementCommitted, Revision: 7}
	r, _, p := strayRig(t, bound)
	if err := cmdDestroy([]string{"svc", "--host", "h003"}); err != nil {
		t.Fatalf("destroy of the stray: %v\n%s", err, r.calls())
	}
	calls := r.calls()
	if !strings.Contains(calls, "ssh h003:") || !strings.Contains(calls, "fleet-uninstall") {
		t.Fatalf("the stray on h003 was not uninstalled:\n%s", calls)
	}
	if strings.Contains(calls, "ssh h001:") {
		t.Fatalf("the bound host h001 was touched:\n%s", calls)
	}
	if got, want := readFile(t, p), "guest ve-app\nweb 100.64.0.1\nweb 100.64.0.11\n"; got != want {
		t.Errorf("callee ports file:\n%q\nwant h001 still admitted, h003 withdrawn:\n%q", got, want)
	}
	if v := registry(); v.Rows["svc"] != bound || v.Host["svc"] != "h001" {
		t.Errorf("row = %+v, want it unchanged on h001", v.Rows["svc"])
	}
	if !retired["svc"]["h003"] || retired["svc"]["h001"] {
		t.Errorf("retired = %v, want only svc on h003", retired)
	}
}

// `destroy --force` of the bound copy removes it, then its registry row
// (dropDestroyedRow): one DELETE, unforced and without a token, guarded by the
// revision read before the destroy. A row rewritten in the meantime refuses
// the guard and is left to whoever rewrote it.
func TestDestroyForcedBoundCopyDropsTheRow(t *testing.T) {
	bound := placementRow{Service: "svc", Host: "h001", State: placementCommitted, Revision: 7}
	for _, c := range []struct {
		name    string
		now     int64 // the row's revision in the registry when the DELETE lands
		wantErr string
	}{
		{"current", 7, ""},
		{"rewritten meanwhile", 9, "its registry row was not"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r, _, _ := strayRig(t, bound)
			reg := newMoveRegistry(t)
			row := bound
			row.Revision = c.now
			reg.mu.Lock()
			reg.rows["svc"] = row
			reg.mu.Unlock()
			usePlacementServer(t, reg.srv)
			err := cmdDestroy([]string{"svc", "--host", "h001", "--force"})
			if c.wantErr == "" && err != nil || c.wantErr != "" && (err == nil || !strings.Contains(err.Error(), c.wantErr)) {
				t.Fatalf("destroy: %v, want error %q\n%s", err, c.wantErr, r.calls())
			}
			if calls := r.calls(); !strings.Contains(calls, "ssh h001:") || !strings.Contains(calls, "fleet-uninstall") {
				t.Fatalf("the bound copy on h001 was not uninstalled:\n%s", calls)
			}
			cs := reg.calls()
			if len(cs) != 1 || cs[0].verb != "DELETE" || cs[0].act != "svc" {
				t.Fatalf("registry calls = %+v, want one DELETE of svc", cs)
			}
			if q := cs[0].query; q.Get("revision") != "7" || q.Has("force") || q.Has("token") {
				t.Errorf("DELETE query = %v, want revision=7, unforced, no token", q)
			}
			reg.mu.Lock()
			got, ok := reg.rows["svc"]
			reg.mu.Unlock()
			if c.wantErr == "" && ok {
				t.Errorf("row = %+v, want it removed", got)
			}
			if c.wantErr != "" && (!ok || got != row) {
				t.Errorf("row = %+v, want the rewritten row left as it was", got)
			}
		})
	}
}

// The refusals: the bound copy without --force, a host with no copy, and a row
// a move still holds. None of them reaches a host beyond the probe.
func TestDestroyRefusals(t *testing.T) {
	committed := placementRow{Service: "svc", Host: "h001", State: placementCommitted, Revision: 7}
	fenced := placementRow{Service: "svc", Host: "h003", State: placementPrepared, Token: "tok-move",
		Previous: &placementBinding{Host: "h001"}, Revision: 8}
	for _, c := range []struct {
		name string
		row  placementRow
		args []string
		want string
	}{
		{"bound host", committed, []string{"svc", "--host", "h001"}, "authoritative copy"},
		{"bound by default", committed, []string{"svc"}, "authoritative copy"},
		{"not installed", committed, []string{"svc", "--host", "src"}, "not installed on src"},
		{"fenced", fenced, []string{"svc", "--host", "h003"}, "is fenced"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r, _, p := strayRig(t, c.row)
			err := cmdDestroy(c.args)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want an error containing %q", err, c.want)
			}
			if calls := r.calls(); strings.Contains(calls, "ssh ") {
				t.Fatalf("a refused destroy reached a host:\n%s", calls)
			}
			if got := readFile(t, p); !strings.Contains(got, "100.64.0.11") || !strings.Contains(got, "100.64.0.31") {
				t.Errorf("a refused destroy changed admissions: %q", got)
			}
		})
	}
}

// A caller whose net.uses names no http route needs no refresh, and must not
// trigger a discovery sweep or any ssh.
func TestRefreshCallersIgnoresNonHTTP(t *testing.T) {
	r := newRig(t)
	callee := Service{Name: "app", Dir: "app", Kind: "podman", Host: "dst",
		Routes: map[string]Route{"game": {Port: 25565, Proto: "tcp", Exposure: "public", Via: []string{"router"}}}}
	caller := Service{Name: "svc", Dir: "svc", Kind: "podman", Host: "dst",
		Net: Net{Private: true, IP: sp("10.233.4.2"), Uses: []string{"app.game", "nosuch.web"}}}
	oldProbe := fleetProbe
	t.Cleanup(func() { fleetProbe = oldProbe; resetFleetPlacement() })
	fleetProbe = func(context.Context, string) ([]row, error) {
		t.Error("discovery ran for a caller with no http net.uses")
		return nil, nil
	}
	inv.Services = map[string]Service{"app": callee, "svc": caller}
	resetFleetPlacement()

	refreshCallers(caller)

	if calls := r.calls(); calls != "" {
		t.Errorf("nothing should run, got:\n%s", calls)
	}
}

func TestRoutingAudit(t *testing.T) {
	var out strings.Builder
	printRoutingAudit(&out, func() (*edgeClient, error) { return nil, errNoToken })
	if out.Len() != 0 {
		t.Fatalf("no key: %s", out.String())
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/api/placements/routing" || r.Header.Get("Authorization") != "Bearer test" {
			t.Errorf("request: %v", r)
		}
		fmt.Fprint(w, `{"checks":[{"layer":"tailnet","fqdn":"photos.example.com","status":"ok","want":"100.64.0.13","got":"100.64.0.13"},{"layer":"edge","fqdn":"photos.example.com","status":"pending","detail":"reload pending"},{"layer":"stream","fqdn":"tcp/3032","status":"ok","want":"h001","got":"h001"},{"layer":"wan","fqdn":"tcp/25565","status":"pending","detail":"written, not applied yet"}],"errors":[]}`)
	}))
	defer srv.Close()
	printRoutingAudit(&out, func() (*edgeClient, error) { return &edgeClient{base: srv.URL, http: srv.Client(), token: "test"}, nil })
	for _, s := range []string{"== routing (h005)", "photos.example.com", "ok", "pending", "reload pending", "stream", "tcp/3032", "wan", "tcp/25565"} {
		if !strings.Contains(out.String(), s) {
			t.Errorf("missing %q: %s", s, out.String())
		}
	}
	out.Reset()
	printRoutingAudit(&out, func() (*edgeClient, error) { return nil, errors.New("unreachable") })
	if !strings.Contains(out.String(), "pending: unreachable") {
		t.Fatal(out.String())
	}
}
