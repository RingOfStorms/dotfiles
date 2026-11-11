package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"slices"
	"sort"
	"strings"
	"time"
)

// model is one entry of the merged catalog plus routing metadata. Upstream is
// the provider's model id; UpstreamName binds it to one configured server.
type model struct {
	ID                 string
	Upstream           string
	UpstreamName       string
	Provider           string // litellm | copilot | openrouter
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

// errNoCredential marks an upstream that lacks a required credential. Health
// reports it as unconfigured rather than a failure.
var errNoCredential = errors.New("no credential")

func (s *server) refresh(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, catalogTimeout)
	defer cancel()

	type result struct {
		name   string
		models []model
		err    error
	}
	results := make(chan result, len(s.cfg.upstreams))
	for _, configured := range s.cfg.upstreams {
		upstream := configured
		go func() {
			models, err := s.fetchProvider(ctx, upstream)
			models = deduplicateModels(models)
			results <- result{name: upstream.Name, models: models, err: err}
		}()
	}
	for range s.cfg.upstreams {
		r := <-results
		s.mu.Lock()
		if errors.Is(r.err, errNoCredential) {
			log.Printf("catalog: %s: %v (upstream unconfigured)", r.name, r.err)
			delete(s.failed, r.name)
			delete(s.providerModels, r.name)
		} else if r.err != nil {
			log.Printf("catalog: %s: %v (keeping %d cached models)", r.name, r.err, len(s.providerModels[r.name]))
			s.failed[r.name] = true
		} else {
			delete(s.failed, r.name)
			s.providerModels[r.name] = r.models
			log.Printf("catalog: %s: %d models", r.name, len(r.models))
		}
		s.mu.Unlock()
	}
	s.rebuildCatalog()
}

func (s *server) rebuildCatalog() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.collisionFailed = make(map[string]bool)
	merged := make([]model, 0)
	for _, upstream := range s.cfg.upstreams {
		merged = append(merged, s.providerModels[upstream.Name]...)
	}
	sort.Slice(merged, func(i, j int) bool {
		if merged[i].ID == merged[j].ID {
			return merged[i].UpstreamName < merged[j].UpstreamName
		}
		return merged[i].ID < merged[j].ID
	})
	byID := make(map[string]model, len(merged))
	collisions := make(map[string][]string)
	for _, m := range merged {
		if _, collided := collisions[m.ID]; collided {
			collisions[m.ID] = append(collisions[m.ID], m.UpstreamName)
			continue
		}
		if existing, ok := byID[m.ID]; ok {
			collisions[m.ID] = []string{existing.UpstreamName, m.UpstreamName}
			delete(byID, m.ID)
			continue
		}
		byID[m.ID] = m
	}
	for id, names := range collisions {
		unique := make(map[string]struct{}, len(names))
		for _, name := range names {
			unique[name] = struct{}{}
			s.collisionFailed[name] = true
		}
		ordered := make([]string, 0, len(unique))
		for name := range unique {
			ordered = append(ordered, name)
		}
		sort.Strings(ordered)
		log.Printf("catalog: public model ID %q conflicts across upstreams %s; excluding it", id, strings.Join(ordered, ", "))
	}
	s.models = make([]model, 0, len(byID))
	for _, m := range byID {
		s.models = append(s.models, m)
	}
	sort.Slice(s.models, func(i, j int) bool { return s.models[i].ID < s.models[j].ID })
	s.byID = byID
}

// Providers may publish several deployments under one requestable name. Keep
// one public entry without choosing a deployment: requests still use Upstream.
// Advertise only limits and capabilities shared by every deployment, and the
// highest published price rather than understating a possible upstream cost.
func deduplicateModels(models []model) []model {
	indexes := make(map[string]int, len(models))
	unique := models[:0]
	for _, m := range models {
		if i, ok := indexes[m.ID]; ok {
			entry := &unique[i]
			entry.ContextWindow = min(entry.ContextWindow, m.ContextWindow)
			entry.MaxTokens = min(entry.MaxTokens, m.MaxTokens)
			entry.Vision = entry.Vision && m.Vision
			entry.Reasoning = entry.Reasoning && m.Reasoning
			entry.Tools = entry.Tools && m.Tools
			entry.ReasoningEfforts = commonStrings(entry.ReasoningEfforts, m.ReasoningEfforts)
			entry.SupportedParams = commonStrings(entry.SupportedParams, m.SupportedParams)
			entry.CostInput = max(entry.CostInput, m.CostInput)
			entry.CostOutput = max(entry.CostOutput, m.CostOutput)
			entry.CostCacheRead = max(entry.CostCacheRead, m.CostCacheRead)
			continue
		}
		indexes[m.ID] = len(unique)
		unique = append(unique, m)
	}
	return unique
}

func commonStrings(left, right []string) []string {
	return slices.DeleteFunc(left, func(value string) bool {
		return !slices.Contains(right, value)
	})
}

func (s *server) degraded() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.failed) > 0 || len(s.collisionFailed) > 0
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
	status := make(map[string]string, len(s.cfg.upstreams))
	for _, upstream := range s.cfg.upstreams {
		switch {
		case s.failed[upstream.Name] || s.collisionFailed[upstream.Name]:
			status[upstream.Name] = "error"
		case s.providerModels[upstream.Name] == nil:
			status[upstream.Name] = "unconfigured"
		default:
			status[upstream.Name] = fmt.Sprintf("%d models", len(s.providerModels[upstream.Name]))
		}
	}
	return status
}

func (s *server) fetchProvider(ctx context.Context, upstream upstreamConfig) ([]model, error) {
	headers, err := s.providerHeaders(upstream.Name)
	if err != nil {
		return nil, err
	}
	switch upstream.Type {
	case "litellm":
		return s.fetchLiteLLM(ctx, upstream, headers)
	case "copilot":
		return s.fetchCopilot(ctx, upstream, headers)
	case "openrouter":
		return s.fetchOpenRouter(ctx, upstream, headers)
	}
	return nil, fmt.Errorf("unknown upstream type %q", upstream.Type)
}

func (s *server) getJSON(ctx context.Context, requestURL string, headers http.Header, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return fmt.Errorf("build catalog request")
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Accept", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("catalog request failed")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return fmt.Errorf("read catalog response")
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("catalog response returned HTTP %d", resp.StatusCode)
	}
	dec := json.NewDecoder(strings.NewReader(string(body)))
	dec.UseNumber()
	if err := dec.Decode(out); err != nil {
		return fmt.Errorf("decode catalog response: %w", err)
	}
	return nil
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

// fetchLiteLLM reads a LiteLLM-format model catalog, including rich metadata.
func (s *server) fetchLiteLLM(ctx context.Context, upstream upstreamConfig, headers http.Header) ([]model, error) {
	var payload struct {
		Data []struct {
			ModelName string         `json:"model_name"`
			ModelInfo map[string]any `json:"model_info"`
		} `json:"data"`
	}
	if err := s.getJSON(ctx, upstream.BaseURL+"/model/info", headers, &payload); err != nil {
		return nil, err
	}
	models := make([]model, 0, len(payload.Data))
	for _, entry := range payload.Data {
		if entry.ModelName == "" || entry.ModelInfo == nil {
			continue
		}
		info := entry.ModelInfo
		m := model{
			ID:               upstream.Name + "-" + entry.ModelName,
			Upstream:         entry.ModelName,
			UpstreamName:     upstream.Name,
			Provider:         upstream.Type,
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
			// Catalog entries without a mode are chat models.
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
func (s *server) fetchCopilot(ctx context.Context, upstream upstreamConfig, headers http.Header) ([]model, error) {
	var payload struct {
		Data []struct {
			ID                 string         `json:"id"`
			Name               string         `json:"name"`
			ModelPickerEnabled bool           `json:"model_picker_enabled"`
			SupportedEndpoints []string       `json:"supported_endpoints"`
			Capabilities       map[string]any `json:"capabilities"`
		} `json:"data"`
	}
	if err := s.getJSON(ctx, upstream.BaseURL+"/models", headers, &payload); err != nil {
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
			ID:               upstream.Name + "-" + entry.ID,
			Upstream:         entry.ID,
			UpstreamName:     upstream.Name,
			Provider:         upstream.Type,
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
			// Models without supported_endpoints are not in the model picker.
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
func (s *server) fetchOpenRouter(ctx context.Context, upstream upstreamConfig, headers http.Header) ([]model, error) {
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
	if err := s.getJSON(ctx, upstream.BaseURL+"/models", headers, &payload); err != nil {
		return nil, err
	}
	models := make([]model, 0, len(payload.Data))
	for _, entry := range payload.Data {
		if entry.ID == "" {
			continue
		}
		input := stringsOf(entry.Architecture["input_modalities"])
		m := model{
			ID:                upstream.Name + "/" + entry.ID,
			Upstream:          entry.ID,
			UpstreamName:      upstream.Name,
			Provider:          upstream.Type,
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
