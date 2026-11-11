package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
)

func TestCatalogGroupsDeploymentsByPublicName(t *testing.T) {
	t.Setenv("COPILOT_TOKEN_FILE", filepath.Join(t.TempDir(), "no-token"))

	for _, reverse := range []bool{false, true} {
		name := "upstream order"
		if reverse {
			name = "reversed order"
		}
		t.Run(name, func(t *testing.T) {
			rows := []map[string]any{
				{"model_name": "gpt-test", "model_info": map[string]any{
					"mode": "chat", "max_input_tokens": 1050000, "max_output_tokens": 128000,
					"supports_vision": true, "supports_reasoning": true, "supports_function_calling": true,
					"reasoning_effort_levels": []string{"low", "medium", "high"},
					"supported_openai_params": []string{"temperature", "tools"},
					"input_cost_per_token":    0.000002,
				}},
				{"model_name": "other", "model_info": map[string]any{"mode": "chat"}},
				{"model_name": "gpt-test", "model_info": map[string]any{
					"mode": "chat", "max_input_tokens": 922000, "max_output_tokens": 64000,
					"supports_vision": false, "supports_reasoning": true, "supports_function_calling": false,
					"reasoning_effort_levels": []string{"low", "high"},
					"supported_openai_params": []string{"temperature"},
					"input_cost_per_token":    0.000003,
				}},
			}
			if reverse {
				slices.Reverse(rows)
			}
			var unavailable atomic.Bool
			forwarded := make(chan struct{ model, auth string }, 1)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/model/info":
					if unavailable.Load() {
						w.WriteHeader(http.StatusServiceUnavailable)
						return
					}
					json.NewEncoder(w).Encode(map[string]any{"data": rows})
				case "/chat/completions":
					var request struct{ Model string }
					if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
						t.Error(err)
					}
					forwarded <- struct{ model, auth string }{model: request.Model, auth: r.Header.Get("Authorization")}
					json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
						"message": map[string]string{"role": "assistant", "content": "hello"},
					}}})
				default:
					http.NotFound(w, r)
				}
			}))
			defer upstream.Close()
			s := newServer(config{upstreams: []upstreamConfig{{Name: "litellm", Type: "litellm", BaseURL: upstream.URL}}})
			s.refresh(context.Background())
			h := s.routes()
			get := func(path string, out any) {
				t.Helper()
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
				if rec.Code != http.StatusOK {
					t.Fatalf("GET %s: %d %s", path, rec.Code, rec.Body.String())
				}
				if err := json.Unmarshal(rec.Body.Bytes(), out); err != nil {
					t.Fatal(err)
				}
			}
			checkCatalog := func() {
				t.Helper()
				for _, path := range []string{"/models", "/v1/models"} {
					var list struct{ Data []struct{ ID string } }
					get(path, &list)
					ids := make([]string, 0, len(list.Data))
					for _, entry := range list.Data {
						ids = append(ids, entry.ID)
					}
					if !slices.Equal(ids, []string{"litellm-gpt-test", "litellm-other"}) {
						t.Fatalf("%s IDs = %v", path, ids)
					}
				}
				var detail struct {
					Context int `json:"max_input_tokens"`
					Output  int `json:"max_output_tokens"`
				}
				get("/models/litellm-gpt-test", &detail)
				if detail.Context != 922000 || detail.Output != 64000 {
					t.Fatalf("unsafe deployment limits: %+v", detail)
				}
				m, ok := s.lookup("litellm-gpt-test")
				if !ok || m.Vision || m.Tools || !m.Reasoning || m.CostInput != 0.000003 ||
					!slices.Equal(m.ReasoningEfforts, []string{"low", "high"}) {
					t.Fatalf("unsafe merged metadata: %+v", m)
				}
				var info struct {
					Data []struct {
						ModelName string `json:"model_name"`
						ModelInfo struct {
							Params []string `json:"supported_openai_params"`
						} `json:"model_info"`
					}
				}
				get("/model/info", &info)
				if len(info.Data) != 2 || info.Data[0].ModelName != "litellm-gpt-test" || info.Data[1].ModelName != "litellm-other" {
					t.Fatalf("metadata catalog still has deployment rows: %+v", info)
				}
				if !slices.Equal(info.Data[0].ModelInfo.Params, []string{"temperature"}) {
					t.Fatalf("discovery advertises parameters outside the deployment intersection: %v", info.Data[0].ModelInfo.Params)
				}
				if info.Data[1].ModelInfo.Params == nil || len(info.Data[1].ModelInfo.Params) != 0 {
					t.Fatalf("missing upstream parameters must serialize as an empty array: %v", info.Data[1].ModelInfo.Params)
				}
			}
			checkCatalog()
			var health struct {
				Models    int
				Providers map[string]string
			}
			get("/health", &health)
			if health.Models != 2 || health.Providers["litellm"] != "2 models" {
				t.Fatalf("health counts deployment rows: %+v", health)
			}

			// An outage must keep the same deduplicated cached catalog.
			unavailable.Store(true)
			s.refresh(context.Background())
			checkCatalog()

			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/chat/completions",
				strings.NewReader(`{"model":"litellm-gpt-test","messages":[{"role":"user","content":"hi"}]}`)))
			if rec.Code != http.StatusOK {
				t.Fatalf("completion: %d %s", rec.Code, rec.Body.String())
			}
			got := <-forwarded
			if got.model != "gpt-test" || got.auth != "" {
				t.Fatalf("forwarded request = %+v, want upstream model without implicit Authorization", got)
			}
		})
	}
}

func TestMultipleLiteLLMUpstreamsRouteIndependentlyAndRetainCache(t *testing.T) {
	t.Setenv("ALPHA_API_KEY", "alpha-secret")
	t.Setenv("BRAVO_API_KEY", "bravo-secret")
	t.Setenv("COPILOT_TOKEN_FILE", filepath.Join(t.TempDir(), "no-token"))
	t.Setenv("OPENROUTER_API_KEY", "")

	type observedRequest struct {
		model string
		auth  string
	}
	observed := map[string]chan observedRequest{
		"alpha": make(chan observedRequest, 4),
		"bravo": make(chan observedRequest, 4),
	}
	var alphaUnavailable atomic.Bool
	newLiteLLM := func(name string, unavailable *atomic.Bool) *httptest.Server {
		t.Helper()
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/model/info":
				if unavailable.Load() {
					http.Error(w, "unavailable", http.StatusServiceUnavailable)
					return
				}
				json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
					"model_name": "shared", "model_info": map[string]any{"mode": "chat"},
				}}})
			case "/chat/completions":
				var request struct{ Model string }
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Errorf("decode %s request: %v", name, err)
				}
				observed[name] <- observedRequest{model: request.Model, auth: r.Header.Get("Authorization")}
				json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
					"message": map[string]string{"role": "assistant", "content": name},
				}}})
			default:
				http.NotFound(w, r)
			}
		}))
	}
	alpha := newLiteLLM("alpha", &alphaUnavailable)
	defer alpha.Close()
	var bravoUnavailable atomic.Bool
	bravo := newLiteLLM("bravo", &bravoUnavailable)
	defer bravo.Close()

	s := newServer(config{upstreams: []upstreamConfig{
		{Name: "alpha", Type: "litellm", BaseURL: alpha.URL, APIKeyEnv: "ALPHA_API_KEY"},
		{Name: "bravo", Type: "litellm", BaseURL: bravo.URL, APIKeyEnv: "BRAVO_API_KEY"},
	}})
	s.refresh(context.Background())
	if got := s.catalog(); len(got) != 2 || got[0].ID != "alpha-shared" || got[1].ID != "bravo-shared" {
		t.Fatalf("catalog should retain both namespaced model identities: %+v", got)
	}

	handler := s.routes()
	call := func(id string) {
		t.Helper()
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/chat/completions",
			strings.NewReader(`{"model":"`+id+`","messages":[{"role":"user","content":"hi"}]}`)))
		if rec.Code != http.StatusOK {
			t.Fatalf("completion for %s: %d %s", id, rec.Code, rec.Body.String())
		}
	}
	call("alpha-shared")
	call("bravo-shared")
	for _, want := range []struct{ name, key string }{
		{name: "alpha", key: "alpha-secret"}, {name: "bravo", key: "bravo-secret"},
	} {
		select {
		case got := <-observed[want.name]:
			if got.model != "shared" || got.auth != "Bearer "+want.key {
				t.Errorf("%s request = %+v, want upstream model shared and its own credential", want.name, got)
			}
		default:
			t.Errorf("%s did not receive its namespaced model request", want.name)
		}
	}

	alphaUnavailable.Store(true)
	s.refresh(context.Background())
	status := s.providerStatus()
	if status["alpha"] != "error" || status["bravo"] != "1 models" {
		t.Fatalf("upstream failure must be isolated by identity: %v", status)
	}
	if _, ok := s.lookup("alpha-shared"); !ok {
		t.Fatal("failed catalog refresh discarded alpha's cached model")
	}
	call("alpha-shared")
	call("bravo-shared")
	for _, want := range []struct{ name, key string }{
		{name: "alpha", key: "alpha-secret"}, {name: "bravo", key: "bravo-secret"},
	} {
		select {
		case got := <-observed[want.name]:
			if got.model != "shared" || got.auth != "Bearer "+want.key {
				t.Errorf("cached %s route = %+v, want its own upstream and credential", want.name, got)
			}
		default:
			t.Errorf("cached/healthy %s model did not route to its own upstream", want.name)
		}
	}
}

func TestConflictingPublicModelIDsAreExcludedAndRecover(t *testing.T) {
	serveCatalog := func(initial string, recovered *atomic.Bool) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/model/info" {
				http.NotFound(w, r)
				return
			}
			modelName := initial
			if recovered != nil && recovered.Load() {
				modelName = "recovered"
			}
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"model_name": modelName, "model_info": map[string]any{"mode": "chat"},
			}}})
		}))
	}
	one := serveCatalog("shared-model-x", nil)
	defer one.Close()
	two := serveCatalog("model-x", nil)
	defer two.Close()
	var thirdRecovered atomic.Bool
	three := serveCatalog("x", &thirdRecovered)
	defer three.Close()
	other := serveCatalog("ok", nil)
	defer other.Close()

	s := newServer(config{upstreams: []upstreamConfig{
		{Name: "team", Type: "litellm", BaseURL: one.URL},
		{Name: "team-shared", Type: "litellm", BaseURL: two.URL},
		{Name: "team-shared-model", Type: "litellm", BaseURL: three.URL},
		{Name: "healthy", Type: "litellm", BaseURL: other.URL},
	}})
	s.refresh(context.Background())
	if _, ok := s.lookup("team-shared-model-x"); ok {
		t.Fatal("conflicting public ID must not arbitrarily route to a claimant")
	}
	if got := s.catalog(); len(got) != 1 || got[0].ID != "healthy-ok" {
		t.Fatalf("catalog should exclude colliding ID and preserve independent models: %+v", got)
	}
	status := s.providerStatus()
	for _, name := range []string{"team", "team-shared", "team-shared-model"} {
		if status[name] != "error" {
			t.Errorf("collision claimant %q status = %q, want error (all statuses: %v)", name, status[name], status)
		}
	}
	if status["healthy"] != "1 models" {
		t.Fatalf("independent identity should remain healthy: %v", status)
	}

	thirdRecovered.Store(true)
	s.refresh(context.Background())
	if _, ok := s.lookup("team-shared-model-recovered"); !ok {
		t.Fatal("recovered upstream model was not published")
	}
	status = s.providerStatus()
	if status["team-shared-model"] != "1 models" || status["team"] != "error" || status["team-shared"] != "error" {
		t.Fatalf("resolved claimant should recover while remaining collision stays isolated: %v", status)
	}
}

func TestOpenRouterWithoutConfiguredKeyIsUnconfigured(t *testing.T) {
	t.Setenv("OPENROUTER_API_KEY", "legacy-credential-must-not-be-used")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer router-secret" {
			t.Errorf("OpenRouter Authorization = %q, want configured key", r.Header.Get("Authorization"))
		}
		json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"id": "test", "name": "Test"}}})
	}))
	defer upstream.Close()
	config := config{upstreams: []upstreamConfig{{Name: "router", Type: "openrouter", BaseURL: upstream.URL, APIKeyEnv: "MISSING_ROUTER_KEY"}}}
	s := newServer(config)
	s.refresh(context.Background())
	if got := s.providerStatus()["router"]; got != "unconfigured" || len(s.catalog()) != 0 {
		t.Fatalf("missing API key should remain unconfigured with no models: status=%q catalog=%+v", got, s.catalog())
	}
	t.Setenv("MISSING_ROUTER_KEY", "router-secret")
	s = newServer(config)
	s.refresh(context.Background())
	if got := s.providerStatus()["router"]; got != "1 models" {
		t.Fatalf("configured API key status = %q, want 1 models", got)
	}
	if models := s.catalog(); len(models) != 1 || models[0].ID != "router/test" {
		t.Fatalf("configured OpenRouter model was not discovered: %+v", models)
	}
}
func TestOpenRouterUpstreamUsesIdentityAndConfiguredCredential(t *testing.T) {
	t.Setenv("REGIONAL_OPENROUTER_KEY", "regional-secret")
	t.Setenv("OPENROUTER_API_KEY", "legacy-credential-must-not-be-used")
	requests := make(chan struct {
		model string
		auth  string
	}, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/models":
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"id": "vendor/model", "name": "Regional Model", "context_length": 8192,
			}}})
		case "/chat/completions":
			var request struct{ Model string }
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode OpenRouter request: %v", err)
			}
			requests <- struct {
				model string
				auth  string
			}{model: request.Model, auth: r.Header.Get("Authorization")}
			json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
				"message": map[string]string{"role": "assistant", "content": "ok"},
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	s := newServer(config{upstreams: []upstreamConfig{{
		Name: "regional", Type: "openrouter", BaseURL: upstream.URL, APIKeyEnv: "REGIONAL_OPENROUTER_KEY",
	}}})
	s.refresh(context.Background())
	if got := s.catalog(); len(got) != 1 || got[0].ID != "regional/vendor/model" || got[0].UpstreamName != "regional" {
		t.Fatalf("OpenRouter model identity = %+v", got)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/chat/completions",
		strings.NewReader(`{"model":"regional/vendor/model","messages":[{"role":"user","content":"hi"}]}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("OpenRouter completion: %d %s", rec.Code, rec.Body.String())
	}
	got := <-requests
	if got.model != "vendor/model" || got.auth != "Bearer regional-secret" {
		t.Fatalf("OpenRouter route = %+v, want upstream model and configured credential", got)
	}
}

func TestCopilotBridgeRoutesThroughNamedUpstream(t *testing.T) {
	t.Setenv("COPILOT_UPSTREAM_KEY", "copilot-secret")
	requests := make(chan struct {
		model string
		auth  string
	}, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/models":
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"id": "chat-only", "name": "Chat-only model", "model_picker_enabled": true,
				"supported_endpoints": []string{"/chat/completions"},
				"capabilities":        map[string]any{"type": "chat", "supports": map[string]any{}, "limits": map[string]any{}},
			}}})
		case "/chat/completions":
			var request struct{ Model string }
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode Copilot request: %v", err)
			}
			requests <- struct {
				model string
				auth  string
			}{model: request.Model, auth: r.Header.Get("Authorization")}
			json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
				"message":       map[string]string{"role": "assistant", "content": "ok"},
				"finish_reason": "stop",
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	s := newServer(config{upstreams: []upstreamConfig{{
		Name: "gh-region", Type: "copilot", BaseURL: upstream.URL, APIKeyEnv: "COPILOT_UPSTREAM_KEY",
	}}})
	s.refresh(context.Background())
	if got := s.catalog(); len(got) != 1 || got[0].ID != "gh-region-chat-only" || got[0].ResponsesEndpoint || !got[0].ChatEndpoint {
		t.Fatalf("expected a chat-only model from the named Copilot upstream: %+v", got)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/responses",
		strings.NewReader(`{"model":"gh-region-chat-only","input":"hi"}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("bridged response: %d %s", rec.Code, rec.Body.String())
	}
	got := <-requests
	if got.model != "chat-only" || got.auth != "Bearer copilot-secret" {
		t.Fatalf("bridge request = %+v, want named upstream model and configured credential", got)
	}
}

func TestCopilotDeviceTokenUsedForCatalogAndForwarding(t *testing.T) {
	t.Setenv("COPILOT_GITHUB_TOKEN", "device-login-token")
	t.Setenv("COPILOT_TOKEN_FILE", filepath.Join(t.TempDir(), "no-token"))

	type observedRequest struct {
		path string
		auth string
	}
	requests := make(chan observedRequest, 2)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests <- observedRequest{path: r.URL.Path, auth: r.Header.Get("Authorization")}
		switch r.URL.Path {
		case "/models":
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"id": "chat-only", "name": "Chat-only model", "model_picker_enabled": true,
				"supported_endpoints": []string{"/chat/completions"},
				"capabilities":        map[string]any{"type": "chat", "supports": map[string]any{}, "limits": map[string]any{}},
			}}})
		case "/chat/completions":
			json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
				"message":       map[string]string{"role": "assistant", "content": "ok"},
				"finish_reason": "stop",
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	s := newServer(config{upstreams: []upstreamConfig{{Name: "copilot", Type: "copilot", BaseURL: upstream.URL}}})
	s.refresh(context.Background())
	if got := s.catalog(); len(got) != 1 || got[0].ID != "copilot-chat-only" {
		t.Fatalf("expected Copilot catalog model: %+v", got)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/chat/completions",
		strings.NewReader(`{"model":"copilot-chat-only","messages":[{"role":"user","content":"hi"}]}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("Copilot completion: %d %s", rec.Code, rec.Body.String())
	}

	for _, wantPath := range []string{"/models", "/chat/completions"} {
		got := <-requests
		if got.path != wantPath || got.auth != "Bearer device-login-token" {
			t.Errorf("Copilot request = %+v, want %s with device-login bearer", got, wantPath)
		}
	}
}

func TestDuplicateUnknownLimitsRemainUnknown(t *testing.T) {
	for _, reverse := range []bool{false, true} {
		models := []model{
			{ID: "litellm-x", ContextWindow: 1000, MaxTokens: 100, ReasoningEfforts: []string{"high"}},
			{ID: "litellm-x"},
		}
		if reverse {
			slices.Reverse(models)
		}
		got := deduplicateModels(models)
		if len(got) != 1 || got[0].ContextWindow != 0 || got[0].MaxTokens != 0 || len(got[0].ReasoningEfforts) != 0 {
			t.Fatalf("unknown deployment capabilities overstated: %+v", got)
		}
	}
}
