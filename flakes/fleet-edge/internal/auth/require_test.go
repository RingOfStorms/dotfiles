package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestRequireSharedSession: fleet-edge-overrides accepts the dashboard's
// fleet_session only when signed with the shared key and holding the role.
func TestRequireSharedSession(t *testing.T) {
	key := []byte("0123456789abcdef0123456789abcdef")
	dash, _ := New(Config{SessionSecret: key})
	cookie := func(a *Authenticator, roles ...string) *http.Cookie {
		v, err := a.mintSessionCookie("sub-1", "josh@example.com", roles)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Cookie{Name: SessionCookieName, Value: v}
	}
	var got Identity
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, _ = FromContext(r.Context())
	})
	over, _ := New(Config{SessionSecret: key, Zitadel: ZitadelConfig{AllowedRole: "admin"}})
	h := over.Require("/auth/login", ok)
	other, _ := New(Config{SessionSecret: []byte("another-key-another-key-another!")})

	do := func(c *http.Cookie, accept string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/backup/?tab=credentials", nil)
		r.Header.Set("Accept", accept)
		r.Header.Set("X-Auth-Request-Email", "forged@example.com")
		r.Header.Set("X-Auth-Request-Groups", "admin")
		if c != nil {
			r.AddCookie(c)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	if w := do(cookie(dash, "admin"), "text/html"); w.Code != 200 || got.Name != "josh@example.com" || got.Roles[0] != "admin" {
		t.Fatalf("valid session: %d %+v", w.Code, got)
	}
	for name, c := range map[string]*http.Cookie{
		"no cookie": nil,
		"other key": cookie(other, "admin"),
		"no role":   cookie(dash, "viewer"),
		"tampered":  {Name: SessionCookieName, Value: strings.Replace(cookie(dash, "admin").Value, ".", "x.", 1)},
	} {
		got = Identity{}
		w := do(c, "text/html")
		if w.Code != http.StatusFound || w.Header().Get("Location") != "/auth/login?return_to=%2Fbackup%2F%3Ftab%3Dcredentials" || got.Name != "" {
			t.Fatalf("%s: %d %q %+v", name, w.Code, w.Header().Get("Location"), got)
		}
		if w := do(c, "application/json"); w.Code != http.StatusUnauthorized {
			t.Fatalf("%s (api): %d", name, w.Code)
		}
	}
}
