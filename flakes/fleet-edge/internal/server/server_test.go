package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func strp(s string) *string { return &s }

type fakeSource struct {
	m state.Merged
}

func (f fakeSource) Current() state.Merged { return f.m }

func sample() state.Merged {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"photos": {
				Name: "photos", Kind: "nixos", Host: "h001", Description: "immich",
				Routes: map[string]inventory.Route{
					"web": {FQDN: strp("photos.joshuabell.xyz"), URL: strp("https://photos.joshuabell.xyz"), Exposure: "public", Auth: strp("native"), Via: []string{"edge"}},
				},
			},
		},
		Hosts: map[string]inventory.Host{
			"h001": {User: "root"},
			"gp3":  {User: "josh"},
		},
	}
	polls := map[string]state.HostPoll{
		"h001": {Host: "h001", OK: true, PolledAt: time.Now()},
	}
	return state.Merge(inv, polls)
}

func TestHandleIndexRenders(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/services", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	body := w.Body.String()
	if !strings.Contains(body, "photos") || !strings.Contains(body, "photos.joshuabell.xyz") {
		t.Fatalf("expected body to mention photos route, got: %s", body)
	}
}

func TestHandleHosts(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/hosts", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), "h001") {
		t.Fatalf("expected body to mention h001, got: %s", w.Body.String())
	}
}

func TestHandleHealthz(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Fatalf("unexpected healthz response: %d %s", w.Code, w.Body.String())
	}
}

func TestHandleAPIStateJSON(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/api/state.json", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var got state.Merged
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if len(got.Services) != 1 || got.Services[0].Name != "photos" {
		t.Fatalf("unexpected api state: %+v", got)
	}
}

func TestNoPostHandlers(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	for _, path := range []string{"/", "/services", "/hosts", "/healthz", "/api/state.json"} {
		req := httptest.NewRequest(http.MethodPost, path, nil)
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, req)
		// net/http's default mux has no method restriction per handler here
		// (handlers are plain funcs), so this just documents that POST is
		// treated identically to GET -- i.e. there is no mutating behavior
		// triggered by method. The key read-only guarantee is that no
		// handler writes state; verified by code review / Source interface
		// being read-only (Current() has no side effects).
		if w.Code >= 500 {
			t.Fatalf("POST %s caused server error: %d", path, w.Code)
		}
	}
}

func TestStaticStyleCSSServed(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/static/style.css", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	ct := w.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/css") {
		t.Fatalf("expected text/css content type, got %q", ct)
	}
	if !strings.Contains(w.Body.String(), "--bg") {
		t.Fatalf("expected stylesheet body, got: %s", w.Body.String())
	}
}

func TestHostsNoEndpointNotCounted(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts", nil))
	body := w.Body.String()
	if !strings.Contains(body, "no endpoint") || strings.Contains(body, "pill-unreachable") {
		t.Fatalf("expected gp3 as no endpoint and nothing unreachable, got: %s", body)
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	if !strings.Contains(w.Body.String(), "<strong>1</strong>/<strong>1</strong> hosts reachable") {
		t.Fatalf("expected 1/1 hosts reachable, got: %s", w.Body.String())
	}
}

func TestStartPageTilesAndIcons(t *testing.T) {
	cfg := Config{
		Title: "Josh's Homelab",
		Links: []dash.Link{
			{Name: "Photos", URL: "https://photos.joshuabell.xyz", Icon: "immich", Group: "Photos & Docs"},
			{Name: "Radarr", URL: "http://h001:7878", Group: "Media"},
		},
	}
	srv := New(fakeSource{m: sample()}, cfg)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
	body := w.Body.String()
	for _, want := range []string{
		"Photos &amp; Docs",
		"https://cdn.jsdelivr.net/gh/selfhst/icons/svg/immich.svg",
		`<span class="letter">R</span>`,
		"dot-unknown",
		"Josh&#39;s Homelab",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("start page missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, `class="bg"`) {
		t.Fatal("no background configured, but bg div rendered")
	}
}

func TestBackgroundURL(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{Background: "https://example.com/bg.png"})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
	if !strings.Contains(w.Body.String(), "https://example.com/bg.png") {
		t.Fatalf("expected background URL, got %s", w.Body.String())
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/assets/bg", nil))
	if w.Code == http.StatusOK {
		t.Fatal("/assets/bg should not be served for a URL background")
	}
}

func TestBackgroundFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bg.svg")
	if err := os.WriteFile(p, []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := New(fakeSource{m: sample()}, Config{Background: p})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts", nil))
	if !strings.Contains(w.Body.String(), "/assets/bg") || strings.Contains(w.Body.String(), p) {
		t.Fatalf("expected /assets/bg reference (not the path), got %s", w.Body.String())
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/assets/bg", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "<svg") {
		t.Fatalf("/assets/bg = %d %s", w.Code, w.Body.String())
	}
}
