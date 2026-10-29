package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Logging out must not bounce into the OIDC flow: the identity provider's own
// session usually survives, so a redirect there re-authenticates immediately and
// the tap looks like nothing happened (the mobile report this fixes).
func TestLogoutStopsAndClearsTheCookie(t *testing.T) {
	a := &Authenticator{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/logout", nil)

	a.handleLogout(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "" {
		t.Fatalf("logout redirected to %q", loc)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("Cache-Control = %q", cc)
	}
	if !strings.Contains(rec.Body.String(), "Signed out") {
		t.Errorf("body does not name the outcome: %q", rec.Body.String())
	}

	var cleared *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == SessionCookieName {
			cleared = c
		}
	}
	if cleared == nil {
		t.Fatal("session cookie was not cleared")
	}
	if cleared.Value != "" || cleared.MaxAge >= 0 {
		t.Fatalf("cookie not expired: value=%q maxAge=%d", cleared.Value, cleared.MaxAge)
	}
	if !cleared.HttpOnly || cleared.SameSite != http.SameSiteLaxMode {
		t.Fatalf("cookie attributes changed: %+v", cleared)
	}
}
