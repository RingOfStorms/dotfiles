package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type server struct {
	cfg     config
	client  *http.Client
	copilot *copilotAuth

	mu              sync.RWMutex
	models          []model
	byID            map[string]model
	providerModels  map[string][]model
	failed          map[string]bool
	collisionFailed map[string]bool
	upstreamByName  map[string]upstreamConfig
	upstreamAuth    map[string]string
}

func newServer(cfg config) *server {
	validated, err := validateUpstreams(cfg.upstreams)
	if err != nil {
		panic(err)
	}
	cfg.upstreams = validated
	tokenPath := os.Getenv("COPILOT_TOKEN_FILE")
	if tokenPath == "" {
		for _, upstream := range validated {
			if upstream.Type != "copilot" || upstream.APIKeyEnv != "" {
				continue
			}
			configDir, err := os.UserConfigDir()
			if err != nil {
				panic(fmt.Errorf("resolve user config directory: %w", err))
			}
			tokenPath = configDir + string(os.PathSeparator) + "llm-router" + string(os.PathSeparator) + "copilot-token"
			break
		}
	}
	s := &server{
		cfg: cfg,
		client: &http.Client{
			// No overall timeout: completion streams can run for many minutes.
			// Header timeouts bound the "upstream never answered" case.
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				MaxIdleConnsPerHost:   32,
				IdleConnTimeout:       90 * time.Second,
				TLSHandshakeTimeout:   15 * time.Second,
				ResponseHeaderTimeout: 10 * time.Minute,
				ExpectContinueTimeout: time.Second,
			},
		},
		copilot:         newCopilotAuth(tokenPath),
		providerModels:  map[string][]model{},
		failed:          map[string]bool{},
		collisionFailed: map[string]bool{},
		upstreamByName:  make(map[string]upstreamConfig, len(validated)),
		upstreamAuth:    make(map[string]string, len(validated)),
	}
	for _, upstream := range validated {
		s.upstreamByName[upstream.Name] = upstream
		if upstream.APIKeyEnv != "" {
			s.upstreamAuth[upstream.Name] = strings.TrimSpace(os.Getenv(upstream.APIKeyEnv))
		}
	}
	return s
}

func (s *server) hasCopilot() bool {
	for _, upstream := range s.cfg.upstreams {
		if upstream.Type == "copilot" && upstream.APIKeyEnv == "" {
			return true
		}
	}
	return false
}

func (s *server) upstream(name string) (upstreamConfig, bool) {
	u, ok := s.upstreamByName[name]
	return u, ok
}

func (s *server) providerBase(name string) string {
	upstream, ok := s.upstream(name)
	if !ok {
		return ""
	}
	return upstream.BaseURL
}

func (s *server) providerHeaders(name string) (http.Header, error) {
	upstream, ok := s.upstream(name)
	if !ok {
		return nil, fmt.Errorf("unknown upstream %q", name)
	}
	h := make(http.Header)
	if upstream.APIKeyEnv != "" {
		key := s.upstreamAuth[name]
		if key == "" {
			return nil, fmt.Errorf("%w: credential environment variable %s is not set", errNoCredential, upstream.APIKeyEnv)
		}
		h.Set("Authorization", "Bearer "+key)
	} else if upstream.Type == "copilot" {
		token, err := s.copilot.token()
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errNoCredential, err)
		}
		h.Set("Authorization", "Bearer "+token)
	}
	if upstream.Type == "copilot" {
		h.Set("Editor-Version", "vscode/1.95.0")
		h.Set("Copilot-Integration-Id", "vscode-chat")
		h.Set("X-GitHub-Api-Version", "2025-04-01")
	}
	return h, nil
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	// The router answers API paths with and without the /v1 prefix; clients
	// rely on both forms.
	handle := func(pattern string, h http.HandlerFunc) {
		mux.HandleFunc(pattern, h)
		method, path, ok := strings.Cut(pattern, " ")
		if !ok {
			return
		}
		switch {
		case strings.HasPrefix(path, "/v1/"):
			mux.HandleFunc(method+" "+strings.TrimPrefix(path, "/v1"), h)
		case strings.HasPrefix(path, "/v"), path == "/health":
			// Already versioned, or not part of the versioned API.
		default:
			mux.HandleFunc(method+" /v1"+path, h)
		}
	}
	mux.HandleFunc("GET /health", s.handleHealth)
	handle("GET /models", s.handleModels)
	handle("GET /models/{id}", s.handleModel)
	handle("POST /chat/completions", s.handleChat)
	handle("POST /responses", s.handleResponses)
	handle("POST /embeddings", s.handleEmbeddings)
	handle("POST /images/generations", s.handleImages)
	// omp's LiteLLM discovery probes these for rich metadata; all answer the
	// same document.
	for _, path := range []string{"/model/info", "/v2/model/info", "/model_group/info"} {
		handle("GET "+path, s.handleModelInfo)
	}
	mux.HandleFunc("/v1/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "llm-router: unsupported endpoint "+r.URL.Path)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			fmt.Fprintln(w, "llm-router")
			return
		}
		writeError(w, http.StatusNotFound, "llm-router: unsupported endpoint "+r.URL.Path)
	})
	return mux
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"message": message, "type": "invalid_request_error"},
	})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	status := s.providerStatus()
	healthy := true
	for _, v := range status {
		if v == "error" {
			healthy = false
		}
	}
	code := http.StatusOK
	if !healthy {
		code = http.StatusServiceUnavailable
	}
	body := map[string]any{
		"status":    map[bool]string{true: "ok", false: "degraded"}[healthy],
		"providers": status,
		"models":    len(s.catalog()),
	}
	if hint := s.copilot.loginHint(); hint != "" {
		body["copilot_login"] = hint
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(body)
}

// modelJSON renders one catalog entry in the LiteLLM /v1/models shape.
func modelJSON(m model) map[string]any {
	out := map[string]any{
		"id":      m.ID,
		"object":  "model",
		"created": m.Created,
		"mode":    m.Mode,
	}
	if m.Created == 0 {
		out["created"] = 1677610602 // LiteLLM's constant
	}
	if m.ContextWindow > 0 {
		out["max_input_tokens"] = m.ContextWindow
	}
	if m.MaxTokens > 0 {
		out["max_output_tokens"] = m.MaxTokens
	}
	return out
}

func (s *server) handleModels(w http.ResponseWriter, r *http.Request) {
	list := s.catalog()
	data := make([]map[string]any, 0, len(list))
	for _, m := range list {
		data = append(data, modelJSON(m))
	}
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

func (s *server) handleModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, ok := s.lookup(id)
	if !ok {
		writeError(w, http.StatusNotFound, "llm-router: model "+id+" not found")
		return
	}
	writeJSON(w, http.StatusOK, modelJSON(m))
}

// handleModelInfo serves LiteLLM's rich metadata format. omp prefers it over
// /v1/models because it carries limits, vision and reasoning capability.
func (s *server) handleModelInfo(w http.ResponseWriter, r *http.Request) {
	list := s.catalog()
	data := make([]map[string]any, 0, len(list))
	for _, m := range list {
		params := m.SupportedParams
		if m.Provider == "litellm" {
			// LiteLLM metadata preserves its advertised supported parameters.
			if params == nil {
				params = []string{}
			}
		} else {
			params = []string{
				"stream", "stop", "temperature", "top_p", "seed", "presence_penalty",
				"frequency_penalty", "max_tokens", "max_completion_tokens", "user",
			}
			if m.Tools {
				params = append(params, "tools", "tool_choice", "parallel_tool_calls")
			}
			if m.Reasoning {
				params = append(params, "reasoning_effort")
			}
			if m.Mode == "chat" {
				params = append(params, "response_format")
			}
		}
		info := map[string]any{
			"mode":                      m.Mode,
			"supports_vision":           m.Vision,
			"supports_reasoning":        m.Reasoning,
			"supports_function_calling": m.Tools,
			"supports_prompt_caching":   true,
			"supports_response_schema":  true,
			"supported_openai_params":   params,
			"base_model":                m.UpstreamName + "/" + m.Upstream,
		}
		if m.ContextWindow > 0 {
			info["max_input_tokens"] = m.ContextWindow
		}
		if m.MaxTokens > 0 {
			info["max_output_tokens"] = m.MaxTokens
		}
		if len(m.ReasoningEfforts) > 0 {
			info["reasoning_effort_levels"] = m.ReasoningEfforts
		}
		if m.CostInput > 0 {
			info["input_cost_per_token"] = m.CostInput
		}
		if m.CostOutput > 0 {
			info["output_cost_per_token"] = m.CostOutput
		}
		if m.CostCacheRead > 0 {
			info["cache_read_input_token_cost"] = m.CostCacheRead
		}
		data = append(data, map[string]any{
			"model_name": m.ID,
			"litellm_params": map[string]any{
				// A non-"openai" prefix keeps omp on the chat dialect, which
				// the router always serves (bridging where needed).
				"model": m.UpstreamName + "/" + m.Upstream,
			},
			"model_info": info,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": data})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "llm-router: encode response: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
}

// readJSONBody parses a request body into a generic map. 512 MiB matches the
// headroom LiteLLM had configured for large multimodal requests.
func readJSONBody(w http.ResponseWriter, r *http.Request) (map[string]any, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
	dec := json.NewDecoder(r.Body)
	dec.UseNumber()
	var body map[string]any
	if err := dec.Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "llm-router: invalid JSON body: "+err.Error())
		return nil, false
	}
	return body, true
}

// resolveRequest performs the model lookup on a request body, rewrites the
// model field to the upstream id and returns the catalog entry.
func (s *server) resolveRequest(w http.ResponseWriter, body map[string]any) (model, bool) {
	id := str(body["model"])
	if id == "" {
		writeError(w, http.StatusBadRequest, "llm-router: request has no model")
		return model{}, false
	}
	m, ok := s.lookup(id)
	if !ok {
		writeError(w, http.StatusNotFound, "llm-router: model "+id+" is not in the catalog")
		return model{}, false
	}
	body["model"] = m.Upstream
	return m, true
}

// forward sends body to the upstream path and streams the response back
// verbatim (status, content type and body), which covers both JSON and SSE.
func (s *server) forward(w http.ResponseWriter, r *http.Request, upstreamName, path string, body map[string]any) {
	if upstreamName == "" {
		writeError(w, http.StatusServiceUnavailable, "llm-router: model has no upstream identity")
		return
	}
	headers, err := s.providerHeaders(upstreamName)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "llm-router: "+err.Error())
		return
	}
	payload, err := json.Marshal(body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "llm-router: encode body: "+err.Error())
		return
	}
	requestURL := s.providerBase(upstreamName) + path
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, requestURL, strings.NewReader(string(payload)))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "llm-router: build upstream request")
		return
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", r.Header.Get("Accept"))
	if req.Header.Get("Accept") == "" {
		req.Header.Set("Accept", "application/json")
	}

	resp, err := s.client.Do(req)
	if err != nil {
		if r.Context().Err() != nil {
			return // client went away
		}
		writeError(w, http.StatusBadGateway, "llm-router: upstream request failed")
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	copyStream(w, resp.Body)
}

// copyStream copies an upstream body to the client, flushing after each read
// so SSE deltas reach the client immediately.
func copyStream(w http.ResponseWriter, src io.Reader) {
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

// handleChat serves POST /v1/chat/completions for every chat model. Models
// whose provider only speaks /responses are bridged.
func (s *server) handleChat(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONBody(w, r)
	if !ok {
		return
	}
	m, ok := s.resolveRequest(w, body)
	if !ok {
		return
	}
	switch {
	case m.ChatEndpoint:
		s.forward(w, r, m.UpstreamName, "/chat/completions", body)
	case m.ResponsesEndpoint:
		s.chatViaResponses(w, r, m, body)
	default:
		writeError(w, http.StatusBadRequest, "llm-router: model "+m.ID+" does not serve chat completions")
	}
}

// handleResponses serves POST /v1/responses. Chat-only models are bridged.
func (s *server) handleResponses(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONBody(w, r)
	if !ok {
		return
	}
	m, ok := s.resolveRequest(w, body)
	if !ok {
		return
	}
	switch {
	case m.ResponsesEndpoint:
		s.forward(w, r, m.UpstreamName, "/responses", body)
	case m.ChatEndpoint:
		s.responsesViaChat(w, r, m, body)
	default:
		writeError(w, http.StatusBadRequest, "llm-router: model "+m.ID+" does not serve the responses API")
	}
}

// handleEmbeddings serves POST /v1/embeddings. Copilot only accepts an input
// array, so a bare string is wrapped.
func (s *server) handleEmbeddings(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONBody(w, r)
	if !ok {
		return
	}
	m, ok := s.resolveRequest(w, body)
	if !ok {
		return
	}
	if !m.EmbeddingsEndpoint {
		writeError(w, http.StatusBadRequest, "llm-router: model "+m.ID+" is not an embedding model")
		return
	}
	if m.Provider == "copilot" {
		if _, isString := body["input"].(string); isString {
			body["input"] = []any{body["input"]}
		}
	}
	s.forward(w, r, m.UpstreamName, "/embeddings", body)
}

// handleImages serves POST /v1/images/generations for image models.
func (s *server) handleImages(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONBody(w, r)
	if !ok {
		return
	}
	m, ok := s.resolveRequest(w, body)
	if !ok {
		return
	}
	if m.Mode != "image_generation" {
		writeError(w, http.StatusBadRequest, "llm-router: model "+m.ID+" is not an image generation model")
		return
	}
	s.forward(w, r, m.UpstreamName, "/images/generations", body)
}

// logUpstreamFailure logs a non-2xx upstream reply for the bridged paths, where
// the body must be consumed rather than streamed.
func logUpstreamFailure(what string, status int, body []byte) {
	log.Printf("%s: upstream HTTP %d: %s", what, status, truncate(string(body), 300))
}

// postJSON performs a non-streaming (or streamed-to-buffer) upstream POST.
func (s *server) postJSON(ctx context.Context, upstreamName, path string, body map[string]any) (*http.Response, error) {
	if upstreamName == "" {
		return nil, fmt.Errorf("model has no upstream identity")
	}
	headers, err := s.providerHeaders(upstreamName)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.providerBase(upstreamName)+path, strings.NewReader(string(payload)))
	if err != nil {
		return nil, fmt.Errorf("build upstream request")
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Content-Type", "application/json")
	return s.client.Do(req)
}
