package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeUpstream serves one canned SSE body for every POST.
func fakeUpstream(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func testServer(upstream string, m model) (*server, http.Handler) {
	s := newServer(config{upstreams: []upstreamConfig{{Name: "litellm", Type: "litellm", BaseURL: upstream}}})
	s.providerModels = map[string][]model{"litellm": {m}}
	s.models = []model{m}
	s.byID = map[string]model{m.ID: m}
	return s, s.routes()
}

// TestChatHandlerFailsWhenUpstreamResponseFails drives POST /v1/chat/completions
// against a responses-only model whose upstream dies mid-stream. The client
// must not receive finish_reason "stop": that reads as a complete answer.
func TestChatHandlerFailsWhenUpstreamResponseFails(t *testing.T) {
	upstream := fakeUpstream(t, strings.Join([]string{
		`event: response.created`,
		`data: {"type":"response.created","response":{"id":"r","status":"in_progress"}}`,
		"",
		`event: response.output_text.delta`,
		`data: {"type":"response.output_text.delta","delta":"partial"}`,
		"",
		`event: response.failed`,
		`data: {"type":"response.failed","response":{"id":"r","status":"failed","error":{"code":"server_error","message":"model crashed"}}}`,
		"",
		"",
	}, "\n"))

	m := model{ID: "litellm-x", Upstream: "x", Provider: "litellm", UpstreamName: "litellm", Mode: "chat", ResponsesEndpoint: true}
	_, handler := testServer(upstream.URL, m)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		strings.NewReader(`{"model":"litellm-x","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "model crashed") {
		t.Errorf("upstream error not surfaced:\n%s", body)
	}
	if strings.Contains(body, `"finish_reason":"stop"`) {
		t.Errorf("failed stream reported a clean stop:\n%s", body)
	}
}

// TestResponsesHandlerFailsWhenUpstreamChatBreaks drives POST /v1/responses
// against a chat-only model whose stream stops without a finish_reason.
func TestResponsesHandlerFailsWhenUpstreamChatBreaks(t *testing.T) {
	upstream := fakeUpstream(t, strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}`,
		"",
		"",
	}, "\n"))

	m := model{ID: "litellm-y", Upstream: "y", Provider: "litellm", UpstreamName: "litellm", Mode: "chat", ChatEndpoint: true}
	_, handler := testServer(upstream.URL, m)

	req := httptest.NewRequest(http.MethodPost, "/v1/responses",
		strings.NewReader(`{"model":"litellm-y","stream":true,"input":"hi"}`))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "event: response.failed") {
		t.Errorf("truncated upstream not reported as failed:\n%s", body)
	}
	if strings.Contains(body, "event: response.completed") {
		t.Errorf("truncated stream claimed completion:\n%s", body)
	}
}

// TestResponsesHandlerCompletesOnCleanStream keeps the success path honest:
// the same handler must still report completion when the upstream finishes.
func TestResponsesHandlerCompletesOnCleanStream(t *testing.T) {
	upstream := fakeUpstream(t, strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"content":"hi"}}]}`,
		"",
		`data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
		"",
		`data: [DONE]`,
		"",
		"",
	}, "\n"))

	m := model{ID: "litellm-z", Upstream: "z", Provider: "litellm", UpstreamName: "litellm", Mode: "chat", ChatEndpoint: true}
	_, handler := testServer(upstream.URL, m)

	req := httptest.NewRequest(http.MethodPost, "/v1/responses",
		strings.NewReader(`{"model":"litellm-z","stream":true,"input":"hi"}`))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "event: response.completed") {
		t.Errorf("clean stream did not complete:\n%s", body)
	}
	checkSequenceNumbers(t, body)
}
