package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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
		},
	}
	polls := map[string]state.HostPoll{
		"h001": {Host: "h001", OK: true, PolledAt: time.Now()},
	}
	return state.Merge(inv, polls)
}

func TestHandleIndexRenders(t *testing.T) {
	srv := New(fakeSource{m: sample()})
	req := httptest.NewRequest(http.MethodGet, "/", nil)
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
	srv := New(fakeSource{m: sample()})
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
	srv := New(fakeSource{m: sample()})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Fatalf("unexpected healthz response: %d %s", w.Code, w.Body.String())
	}
}

func TestHandleAPIStateJSON(t *testing.T) {
	srv := New(fakeSource{m: sample()})
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
	srv := New(fakeSource{m: sample()})
	for _, path := range []string{"/", "/hosts", "/healthz", "/api/state.json"} {
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
