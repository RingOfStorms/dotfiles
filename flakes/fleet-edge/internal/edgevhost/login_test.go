package edgevhost

import (
	"strings"
	"testing"
)

func TestLoginPathsRetainGlobalLimitAndProxy(t *testing.T) {
	c := testCfg(t)
	c.LoginZone, c.LoginLog, c.LoginLogFormat, c.AccessLog = "fleet_edge_login", "/var/log/nginx/login.log", "fleet_login", "/var/log/nginx/access.log"
	for _, kind := range []string{"", KindPlacement} {
		r := addReq()
		r.Kind = kind
		if kind == KindPlacement {
			r.Until = 0
		}
		r.LoginPaths = []string{"/api/auth/login", "/Users/AuthenticateByName"}
		if err := c.Validate(r); err != nil {
			t.Fatal(err)
		}
		out := c.Render(r)
		for _, want := range []string{"location ~* ^(?:/api/auth/login|/Users/AuthenticateByName)/?$", "limit_req zone=" + c.LimitZone, "limit_req zone=fleet_edge_login burst=5 nodelay", "limit_req_status 429", "access_log /var/log/nginx/login.log fleet_login", "access_log /var/log/nginx/access.log"} {
			if !strings.Contains(out, want) {
				t.Fatalf("missing %s: %s", want, out)
			}
		}
		if strings.Count(out, "proxy_pass http://") != 2 {
			t.Fatal("login proxy differs from normal route")
		}
	}
	for _, path := range []string{"/", "/login;return 200", "/a?$x"} {
		r := addReq()
		r.LoginPaths = []string{path}
		if c.Validate(r) == nil {
			t.Fatalf("accepted %q", path)
		}
	}
}
