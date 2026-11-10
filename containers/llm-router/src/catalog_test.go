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
	t.Setenv("OPENROUTER_API_KEY", "")
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
			forwarded := make(chan string, 1)
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
					forwarded <- request.Model
					json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{
						"message": map[string]string{"role": "assistant", "content": "hello"},
					}}})
				default:
					http.NotFound(w, r)
				}
			}))
			defer upstream.Close()
			s := newServer(config{airBase: upstream.URL})
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
					if !slices.Equal(ids, []string{"air-gpt-test", "air-other"}) {
						t.Fatalf("%s IDs = %v", path, ids)
					}
				}
				var detail struct {
					Context int `json:"max_input_tokens"`
					Output  int `json:"max_output_tokens"`
				}
				get("/models/air-gpt-test", &detail)
				if detail.Context != 922000 || detail.Output != 64000 {
					t.Fatalf("unsafe deployment limits: %+v", detail)
				}
				m, ok := s.lookup("air-gpt-test")
				if !ok || m.Vision || m.Tools || !m.Reasoning || m.CostInput != 0.000003 ||
					!slices.Equal(m.ReasoningEfforts, []string{"low", "high"}) ||
					!slices.Equal(m.SupportedParams, []string{"temperature"}) {
					t.Fatalf("unsafe merged metadata: %+v", m)
				}
				var info struct {
					Data []struct {
						ModelName string `json:"model_name"`
					}
				}
				get("/model/info", &info)
				if len(info.Data) != 2 || info.Data[0].ModelName != "air-gpt-test" || info.Data[1].ModelName != "air-other" {
					t.Fatalf("metadata catalog still has deployment rows: %+v", info)
				}
			}
			checkCatalog()
			var health struct {
				Models    int
				Providers map[string]string
			}
			get("/health", &health)
			if health.Models != 2 || health.Providers["air"] != "2 models" {
				t.Fatalf("health counts deployment rows: %+v", health)
			}

			// An outage must keep the same deduplicated cached catalog.
			unavailable.Store(true)
			s.refresh(context.Background())
			checkCatalog()

			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/chat/completions",
				strings.NewReader(`{"model":"air-gpt-test","messages":[{"role":"user","content":"hi"}]}`)))
			if rec.Code != http.StatusOK {
				t.Fatalf("completion: %d %s", rec.Code, rec.Body.String())
			}
			if got := <-forwarded; got != "gpt-test" {
				t.Fatalf("forwarded deployment instead of shared model name: %q", got)
			}
		})
	}
}

func TestDuplicateUnknownLimitsRemainUnknown(t *testing.T) {
	for _, reverse := range []bool{false, true} {
		models := []model{
			{ID: "air-x", ContextWindow: 1000, MaxTokens: 100, ReasoningEfforts: []string{"high"}},
			{ID: "air-x"},
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
