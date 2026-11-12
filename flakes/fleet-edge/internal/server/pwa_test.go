package server

import (
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
)

// Installers do not share the browser's login. Only metadata and icons may
// bypass authentication; dashboard data and personalized assets must not.
func TestInstallResourcesWithoutSession(t *testing.T) {
	a, err := auth.New(auth.Config{Zitadel: auth.ZitadelConfig{
		Issuer: "https://sso.example.com", ClientID: "fleet", AllowedRole: "admin",
	}})
	if err != nil {
		t.Fatal(err)
	}
	title := `Fleet "home" & lab`
	h := a.Wrap(New(fakeSource{m: sample()}, Config{Title: title}))
	request := func(method, path string) *httptest.ResponseRecorder {
		t.Helper()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(method, path, nil))
		return w
	}
	w := request(http.MethodGet, "/manifest.webmanifest")
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "application/manifest+json" {
		t.Fatalf("anonymous manifest: %d %v", w.Code, w.Header())
	}
	var manifest struct {
		Name  string `json:"name"`
		Icons []struct {
			Src string `json:"src"`
		} `json:"icons"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.Name != title {
		t.Fatalf("manifest title = %q, want %q", manifest.Name, title)
	}
	sizes := map[int]bool{}
	for _, icon := range manifest.Icons {
		w := request(http.MethodGet, icon.Src)
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "image/png" {
			t.Fatalf("anonymous icon %s: %d %v", icon.Src, w.Code, w.Header())
		}
		image, err := png.Decode(w.Body)
		if err != nil {
			t.Fatalf("icon %s: %v", icon.Src, err)
		}
		bounds := image.Bounds()
		if bounds.Dx() != bounds.Dy() {
			t.Fatalf("icon %s is not square: %v", icon.Src, bounds)
		}
		sizes[bounds.Dx()] = true
	}
	if !sizes[192] || !sizes[512] {
		t.Fatalf("installers need decodable 192px and 512px icons, got %v", sizes)
	}
	for _, path := range []string{"/manifest.webmanifest", "/static/icon-192.png", "/static/icon-512.png"} {
		if w := request(http.MethodHead, path); w.Code != http.StatusOK || w.Body.Len() != 0 {
			t.Errorf("HEAD %s: %d, %d bytes", path, w.Code, w.Body.Len())
		}
		if w := request(http.MethodPost, path); w.Code != http.StatusUnauthorized {
			t.Errorf("unauthenticated POST %s: %d", path, w.Code)
		}
	}
	for _, path := range []string{
		"/", "/services", "/hosts", "/assets/bg", "/static/style.css", "/static/",
		"/manifest.webmanifest/private", "/static/icon-192.png/private",
		"/static/../style.css", "/static/icon-192.png/../../assets/bg",
	} {
		w := request(http.MethodGet, path)
		if w.Code != http.StatusFound {
			t.Errorf("anonymous GET %s: %d, want login redirect", path, w.Code)
		}
	}
	if w := request(http.MethodGet, "/api/state.json"); w.Code != http.StatusUnauthorized {
		t.Errorf("anonymous state API: %d", w.Code)
	}
}
