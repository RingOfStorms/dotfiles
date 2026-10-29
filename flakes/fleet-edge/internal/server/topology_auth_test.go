package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

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
