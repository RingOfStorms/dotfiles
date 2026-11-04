package web

import (
	"net/http/httptest"
	"testing"
)

func TestCrossOriginUpgrade(t *testing.T) {
	for _, tc := range []struct {
		name, site, origin string
		allowed            bool
	}{
		{"same origin", "same-origin", "https://tmux.example.com", true},
		// A sibling subdomain still gets the SameSite=Lax cookie; it must not
		// get a shell.
		{"same site", "same-site", "https://evil.example.com", false},
		{"cross site", "cross-site", "https://evil.test", false},
		{"no fetch metadata, matching origin", "", "https://tmux.example.com", true},
		{"no fetch metadata, other origin", "", "https://evil.test", false},
		{"not a browser", "", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "http://tmux.example.com/term/ws", nil)
			if tc.site != "" {
				r.Header.Set("Sec-Fetch-Site", tc.site)
			}
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			if got := crossOriginUpgrade(r) == ""; got != tc.allowed {
				t.Fatalf("allowed = %v, want %v (%q)", got, tc.allowed, crossOriginUpgrade(r))
			}
		})
	}
}
