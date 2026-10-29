package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
)

func TestTopologyRequiresAuthentication(t *testing.T) {
	key := "topology-test-key-1234567890"
	a, err := auth.New(auth.Config{APIKeys: []string{key}})
	if err != nil {
		t.Fatal(err)
	}
	h := a.Wrap(New(fakeSource{m: sample()}, Config{}))
	for _, path := range []string{"/topology", "/topology.svg", "/static/topology.js"} {
		t.Run(path, func(t *testing.T) {
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("unauthenticated %s: %d", path, w.Code)
			}
			req := httptest.NewRequest(http.MethodGet, path, nil)
			req.Header.Set("X-API-Key", key)
			w = httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != http.StatusOK {
				t.Fatalf("authenticated %s: %d %s", path, w.Code, w.Body.String())
			}
		})
	}
}

// TestAtlasRoutesRequireAuthentication proves the history, replay and traffic
// endpoints sit behind the same auth wrap as the pages, not beside it.
func TestAtlasRoutesRequireAuthentication(t *testing.T) {
	key := "atlas-test-key-1234567890"
	a, err := auth.New(auth.Config{APIKeys: []string{key}})
	if err != nil {
		t.Fatal(err)
	}
	captured := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	at := captured.Add(10 * time.Second).Format(time.RFC3339)
	h := a.Wrap(atlasServer(t, snapshotAt(t, captured)))

	for _, path := range []string{
		"/api/topology/timeline",
		"/api/topology/frame?at=" + at,
		"/api/topology/traffic?at=" + at,
		"/topology.svg?at=" + at,
	} {
		t.Run(path, func(t *testing.T) {
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("unauthenticated %s: %d", path, w.Code)
			}
			req := httptest.NewRequest(http.MethodGet, path, nil)
			req.Header.Set("X-API-Key", key)
			w = httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != http.StatusOK {
				t.Fatalf("authenticated %s: %d %s", path, w.Code, w.Body.String())
			}
		})
	}
}
