package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// model is one entry of the merged catalog plus what the router needs to know
// to serve it. Upstream is the id the provider's API expects; ID is the public
// (LiteLLM-compatible) alias.
type model struct {
	ID                 string
	Upstream           string
	Provider           string // air | copilot | openrouter
	Mode               string // chat | embedding | image_generation | ...
	ChatEndpoint       bool   // provider serves /chat/completions for it
	ResponsesEndpoint  bool   // provider serves /responses for it
	EmbeddingsEndpoint bool   // provider serves /embeddings for it
	DisplayName        string
	Created            int64
	ContextWindow      int64
	MaxTokens          int64
	Vision             bool
	Reasoning          bool
	ReasoningEfforts   []string
	Tools              bool
	SupportedParams    []string
	CostInput          float64 // USD per token
	CostOutput         float64
	CostCacheRead      float64
}

const catalogTimeout = 45 * time.Second

// errNoCredential marks a provider that has no credential at all. That is an
// operator choice, not a fault: /health reports the provider as unconfigured
// and keeps answering 200, so a monitor only fires on real upstream breakage.
var errNoCredential = errors.New("no credential")

// providerBases maps a provider to its API root (no trailing slash).
func (s *server) providerBase(provider string) string {
	switch provider {
	case "air":
		return s.cfg.airBase
	case "openrouter":
		return s.cfg.openrouterBase
	case "copilot":
		return s.cfg.copilotBase
	}
	return ""
}

// providerHeaders returns the upstream auth/support headers for a provider.
func (s *server) providerHeaders(provider string) (http.Header, error) {
	h := make(http.Header)
	switch provider {
	case "air":
		h.Set("Authorization", "Bearer na")
	case "openrouter":
		key := openRouterKey()
		if key == "" {
			return nil, fmt.Errorf("%w: OPENROUTER_API_KEY is not set", errNoCredential)
		}
		h.Set("Authorization", "Bearer "+key)
	case "copilot":
		token, err := s.copilot.token()
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errNoCredential, err)
		}
		h.Set("Authorization", "Bearer "+token)
		h.Set("Editor-Version", "vscode/1.95.0")
		h.Set("Copilot-Integration-Id", "vscode-chat")
		h.Set("X-GitHub-Api-Version", "2025-04-01")
	default:
		return nil, fmt.Errorf("unknown provider %q", provider)
	}
	return h, nil
}

func (s *server) refresh(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, catalogTimeout)
	defer cancel()

	type result struct {
		provider string
		models   []model
		err      error
	}
	var (
		wg  sync.WaitGroup
		mu  sync.Mutex
		out []result
	)
	for _, provider := range []string{"air", "copilot", "openrouter"} {
		wg.Add(1)
		go func(provider string) {
			defer wg.Done()
			models, err := s.fetchProvider(ctx, provider)
			mu.Lock()
			out = append(out, result{provider: provider, models: models, err: err})
			mu.Unlock()
		}(provider)
	}
	wg.Wait()

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.providerModels == nil {
		s.providerModels = map[string][]model{}
		s.failed = map[string]bool{}
	}
	var merged []model
	for _, r := range out {
		if errors.Is(r.err, errNoCredential) {
			// No credential: leave the provider out of the catalog and out of
			// the failed set, so /health stays 200 and the retry loop keeps its
			// normal interval.
			log.Printf("catalog: %s: %v (provider unconfigured)", r.provider, r.err)
			delete(s.failed, r.provider)
			delete(s.providerModels, r.provider)
			continue
		}
		if r.err != nil {
			log.Printf("catalog: %s: %v (keeping %d cached models)", r.provider, r.err, len(s.providerModels[r.provider]))
			s.failed[r.provider] = true
			merged = append(merged, s.providerModels[r.provider]...)
			continue
		}
		delete(s.failed, r.provider)
		s.providerModels[r.provider] = r.models
		merged = append(merged, r.models...)
		log.Printf("catalog: %s: %d models", r.provider, len(r.models))
	}
	sort.Slice(merged, func(i, j int) bool { return merged[i].ID < merged[j].ID })
	byID := make(map[string]model, len(merged))
	for _, m := range merged {
		byID[m.ID] = m
	}
	s.models = merged
	s.byID = byID
}

func (s *server) degraded() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.failed) > 0
}

func (s *server) lookup(id string) (model, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	m, ok := s.byID[id]
	return m, ok
}

func (s *server) catalog() []model {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.models
}

func (s *server) providerStatus() map[string]string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	status := make(map[string]string, 3)
	for _, provider := range []string{"air", "copilot", "openrouter"} {
		switch {
		case s.failed[provider]:
			status[provider] = "error"
		case s.providerModels[provider] == nil:
			status[provider] = "unconfigured"
		default:
			status[provider] = fmt.Sprintf("%d models", len(s.providerModels[provider]))
		}
	}
	return status
}

func (s *server) fetchProvider(ctx context.Context, provider string) ([]model, error) {
	headers, err := s.providerHeaders(provider)
	if err != nil {
		return nil, err
	}
	switch provider {
	case "air":
		return s.fetchAir(ctx, headers)
	case "copilot":
		return s.fetchCopilot(ctx, headers)
	case "openrouter":
		return s.fetchOpenRouter(ctx, headers)
	}
	return nil, fmt.Errorf("unknown provider %q", provider)
}

func (s *server) getJSON(ctx context.Context, url string, headers http.Header, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Accept", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: HTTP %d: %s", url, resp.StatusCode, truncate(string(body), 300))
	}
	dec := json.NewDecoder(strings.NewReader(string(body)))
	dec.UseNumber()
	return dec.Decode(out)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// numbers in provider JSON are decoded as json.Number; these helpers keep the
// conversions in one place.
func num(v any) int64 {
	switch t := v.(type) {
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return i
		}
		if f, err := t.Float64(); err == nil {
			return int64(f)
		}
	case float64:
		return int64(t)
	case int64:
		return t
	case int:
		return int64(t)
	}
	return 0
}

func fnum(v any) float64 {
	switch t := v.(type) {
	case json.Number:
		if f, err := t.Float64(); err == nil {
			return f
		}
	case float64:
		return t
	}
	return 0
}

func boolean(v any) bool {
	b, _ := v.(bool)
	return b
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// stringsOf decodes []any of strings.
func stringsOf(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, item := range arr {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// contentString flattens OpenAI chat content (string or parts array) to text.
func contentString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []any:
		var b strings.Builder
		for _, part := range t {
			m, ok := part.(map[string]any)
			if !ok {
				continue
			}
			b.WriteString(str(m["text"]))
		}
		return b.String()
	}
	return ""
}

// fetchAir reads 宙 Proxy's LiteLLM-format model metadata. The upstream is
// itself a LiteLLM proxy, so /model/info is the authoritative catalog and
// already carries reasoning levels and limits.
func (s *server) fetchAir(ctx context.Context, headers http.Header) ([]model, error) {
	var payload struct {
		Data []struct {
			ModelName string         `json:"model_name"`
			ModelInfo map[string]any `json:"model_info"`
		} `json:"data"`
	}
	if err := s.getJSON(ctx, s.cfg.airBase+"/model/info", headers, &payload); err != nil {
		return nil, err
	}
	models := make([]model, 0, len(payload.Data))
	for _, entry := range payload.Data {
		if entry.ModelName == "" || entry.ModelInfo == nil {
			continue
		}
		info := entry.ModelInfo
		m := model{
			ID:               "air-" + entry.ModelName,
			Upstream:         entry.ModelName,
			Provider:         "air",
			Mode:             str(info["mode"]),
			DisplayName:      entry.ModelName,
			ContextWindow:    num(info["max_input_tokens"]),
			MaxTokens:        num(info["max_output_tokens"]),
			Vision:           boolean(info["supports_vision"]),
			Reasoning:        boolean(info["supports_reasoning"]),
			ReasoningEfforts: stringsOf(info["reasoning_effort_levels"]),
			Tools:            boolean(info["supports_function_calling"]),
			SupportedParams:  stringsOf(info["supported_openai_params"]),
			CostInput:        fnum(info["input_cost_per_token"]),
			CostOutput:       fnum(info["output_cost_per_token"]),
			CostCacheRead:    fnum(info["cache_read_input_token_cost"]),
		}
		switch m.Mode {
		case "chat":
			m.ChatEndpoint = true
			m.ResponsesEndpoint = true
		case "embedding":
			m.EmbeddingsEndpoint = true
		case "":
			// Modal-less entries in air's catalog are chat models.
			m.Mode = "chat"
			m.ChatEndpoint = true
			m.ResponsesEndpoint = true
		}
		models = append(models, m)
	}
	return models, nil
}

// fetchCopilot reads GitHub Copilot's model list. supported_endpoints decides
// which dialect a model speaks: chat-only models (Claude, Gemini, Kimi) reject
// /responses, and the GPT-5/6 family rejects /chat/completions.
func (s *server) fetchCopilot(ctx context.Context, headers http.Header) ([]model, error) {
	var payload struct {
		Data []struct {
			ID                 string         `json:"id"`
			Name               string         `json:"name"`
			ModelPickerEnabled bool           `json:"model_picker_enabled"`
			SupportedEndpoints []string       `json:"supported_endpoints"`
			Capabilities       map[string]any `json:"capabilities"`
		} `json:"data"`
	}
	if err := s.getJSON(ctx, s.cfg.copilotBase+"/models", headers, &payload); err != nil {
		return nil, err
	}
	models := make([]model, 0, len(payload.Data))
	for _, entry := range payload.Data {
		if entry.ID == "" || entry.Capabilities == nil {
			continue
		}
		kind := str(entry.Capabilities["type"])
		supports, _ := entry.Capabilities["supports"].(map[string]any)
		limits, _ := entry.Capabilities["limits"].(map[string]any)

		m := model{
			ID:               "copilot-" + entry.ID,
			Upstream:         entry.ID,
			Provider:         "copilot",
			DisplayName:      entry.Name,
			ContextWindow:    num(limits["max_context_window_tokens"]),
			MaxTokens:        num(limits["max_output_tokens"]),
			Vision:           boolean(supports["vision"]),
			ReasoningEfforts: stringsOf(supports["reasoning_effort"]),
			Tools:            boolean(supports["tool_calls"]),
			SupportedParams:  []string{"temperature", "top_p", "stream", "stop", "seed", "tools", "tool_choice"},
		}
		hasChat, hasResponses := false, false
		for _, ep := range entry.SupportedEndpoints {
			switch ep {
			case "/chat/completions":
				hasChat = true
			case "/responses":
				hasResponses = true
			}
		}
		switch kind {
		case "embeddings":
			m.Mode = "embedding"
			m.EmbeddingsEndpoint = true
		case "chat":
			// Legacy chat models carry no supported_endpoints and are not in
			// Copilot's picker; skip them like LiteLLM did.
			if !entry.ModelPickerEnabled || !(hasChat || hasResponses) {
				continue
			}
			m.Mode = "chat"
			m.ChatEndpoint = hasChat
			m.ResponsesEndpoint = hasResponses
			m.Reasoning = len(m.ReasoningEfforts) > 0
			if hasChat {
				m.SupportedParams = append(m.SupportedParams, "reasoning_effort")
			}
		default:
			continue
		}
		models = append(models, m)
	}
	return models, nil
}

// fetchOpenRouter reads OpenRouter's catalog. Every entry is a chat model that
// speaks both dialects; supported_parameters tells whether tools/reasoning are
// available.
func (s *server) fetchOpenRouter(ctx context.Context, headers http.Header) ([]model, error) {
	var payload struct {
		Data []struct {
			ID            string         `json:"id"`
			Name          string         `json:"name"`
			Created       json.Number    `json:"created"`
			ContextLength json.Number    `json:"context_length"`
			Architecture  map[string]any `json:"architecture"`
			Pricing       map[string]any `json:"pricing"`
			TopProvider   map[string]any `json:"top_provider"`
			Supported     []string       `json:"supported_parameters"`
		} `json:"data"`
	}
	if err := s.getJSON(ctx, s.cfg.openrouterBase+"/models", headers, &payload); err != nil {
		return nil, err
	}
	models := make([]model, 0, len(payload.Data))
	for _, entry := range payload.Data {
		if entry.ID == "" {
			continue
		}
		input := stringsOf(entry.Architecture["input_modalities"])
		m := model{
			ID:                "openrouter/" + entry.ID,
			Upstream:          entry.ID,
			Provider:          "openrouter",
			Mode:              "chat",
			ChatEndpoint:      true,
			ResponsesEndpoint: true,
			DisplayName:       entry.Name,
			Created:           num(entry.Created),
			ContextWindow:     num(entry.ContextLength),
			MaxTokens:         num(entry.TopProvider["max_completion_tokens"]),
			Reasoning:         contains(entry.Supported, "reasoning") || contains(entry.Supported, "reasoning_effort"),
			Tools:             contains(entry.Supported, "tools"),
			SupportedParams:   entry.Supported,
			CostInput:         fnum(entry.Pricing["prompt"]),
			CostOutput:        fnum(entry.Pricing["completion"]),
		}
		for _, modality := range input {
			if modality == "image" {
				m.Vision = true
			}
		}
		models = append(models, m)
	}
	return models, nil
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}
