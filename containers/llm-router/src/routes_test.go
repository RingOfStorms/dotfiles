package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestRoutesAcceptUnprefixedPaths guards the LiteLLM compatibility promise:
// every public API path answers both with and without the /v1 prefix. Some
// clients (and hand-written curl calls) omit the prefix.
func TestRoutesAcceptUnprefixedPaths(t *testing.T) {
	m := model{ID: "air-test", Provider: "air", Mode: "chat", ChatEndpoint: true}
	_, h := testServer("http://127.0.0.1:1", m)

	get := func(path string) int {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}

	for _, path := range []string{
		"/models", "/v1/models",
		"/models/air-test", "/v1/models/air-test",
		"/model/info", "/v1/model/info",
		"/model_group/info", "/v1/model_group/info",
	} {
		if code := get(path); code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, code)
		}
	}

	for _, path := range []string{"/models/nope", "/v1/models/nope"} {
		if code := get(path); code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404", path, code)
		}
	}

	// A versioned path must not be registered a second time under a doubled
	// prefix (it did when the alias was derived from the whole pattern).
	if code := get("/v1/v2/model/info"); code != http.StatusNotFound {
		t.Errorf("GET /v1/v2/model/info = %d, want 404", code)
	}

	post := func(path string) int {
		req := httptest.NewRequest(http.MethodPost, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	for _, path := range []string{"/chat/completions", "/v1/chat/completions"} {
		// Malformed body: the handler answers 400, proving the route exists.
		if code := post(path); code != http.StatusBadRequest {
			t.Errorf("POST %s = %d, want 400", path, code)
		}
	}
}
