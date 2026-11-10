package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestChatToResponsesBodyToolRoundTrip covers the shape omp produces: system
// prompt, an assistant tool call and its tool result. Copilot rejects unknown
// item types, so the translation must emit the exact responses item vocabulary.
func TestChatToResponsesBodyToolRoundTrip(t *testing.T) {
	body := map[string]any{
		"model": "gpt-6-luna",
		"messages": []any{
			map[string]any{"role": "system", "content": "You are terse."},
			map[string]any{"role": "user", "content": "Weather in Paris?"},
			map[string]any{
				"role":    "assistant",
				"content": nil,
				"tool_calls": []any{map[string]any{
					"id":       "call_1",
					"type":     "function",
					"function": map[string]any{"name": "get_weather", "arguments": `{"city":"Paris"}`},
				}},
			},
			map[string]any{"role": "tool", "tool_call_id": "call_1", "content": "18C sunny"},
		},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        "get_weather",
				"description": "Get weather",
				"parameters":  map[string]any{"type": "object"},
			},
		}},
		"tool_choice":           map[string]any{"type": "function", "function": map[string]any{"name": "get_weather"}},
		"parallel_tool_calls":   true,
		"max_completion_tokens": json.Number("512"),
		"reasoning_effort":      "high",
		"stream":                true,
		"temperature":           0.7,
	}

	got := responsesBodyFromChat("gpt-6-luna", body, true)

	if got["model"] != "gpt-6-luna" || got["instructions"] != "You are terse." {
		t.Fatalf("model/instructions: %v", got)
	}
	if _, ok := got["temperature"]; ok {
		t.Error("copilot responses rejects temperature; it must be dropped")
	}
	if got["max_output_tokens"] != json.Number("512") {
		t.Errorf("max_output_tokens = %v", got["max_output_tokens"])
	}
	reasoning, _ := got["reasoning"].(map[string]any)
	if reasoning["effort"] != "high" {
		t.Errorf("reasoning = %v", got["reasoning"])
	}
	choice, _ := got["tool_choice"].(map[string]any)
	if choice["type"] != "function" || choice["name"] != "get_weather" {
		t.Errorf("tool_choice = %v", got["tool_choice"])
	}
	tools, _ := got["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools = %v", got["tools"])
	}
	if tool := tools[0].(map[string]any); tool["type"] != "function" || tool["name"] != "get_weather" {
		t.Errorf("tool entry = %v", tool)
	}

	input, _ := got["input"].([]any)
	types := make([]string, 0, len(input))
	for _, item := range input {
		types = append(types, str(item.(map[string]any)["type"]))
	}
	want := []string{"message", "function_call", "function_call_output"}
	if strings.Join(types, ",") != strings.Join(want, ",") {
		t.Fatalf("input types = %v, want %v", types, want)
	}
	call := input[1].(map[string]any)
	if call["call_id"] != "call_1" || call["name"] != "get_weather" || call["arguments"] != `{"city":"Paris"}` {
		t.Errorf("function_call = %v", call)
	}
	if out := input[2].(map[string]any); out["call_id"] != "call_1" || out["output"] != "18C sunny" {
		t.Errorf("function_call_output = %v", out)
	}
}

// TestChatToResponsesBodyNonCopilotKeepsSamplingParams guards the pass-through
// path: temperature/top_p are valid upstream outside Copilot.
func TestChatToResponsesBodyNonCopilotKeepsSamplingParams(t *testing.T) {
	body := map[string]any{
		"model":       "m",
		"messages":    []any{map[string]any{"role": "user", "content": "hi"}},
		"temperature": 0.2,
		"top_p":       0.9,
	}
	got := responsesBodyFromChat("m", body, false)
	if got["temperature"] != 0.2 || got["top_p"] != 0.9 {
		t.Fatalf("sampling params dropped: %v", got)
	}
	input, _ := got["input"].([]any)
	content, _ := input[0].(map[string]any)["content"].([]any)
	if part := content[0].(map[string]any); part["type"] != "input_text" || part["text"] != "hi" {
		t.Errorf("user content = %v", part)
	}
}

// TestChatToResponsesBodyImagePart covers multimodal user content.
func TestChatToResponsesBodyImagePart(t *testing.T) {
	body := map[string]any{
		"model": "m",
		"messages": []any{map[string]any{
			"role": "user",
			"content": []any{
				map[string]any{"type": "text", "text": "what is this"},
				map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAA"}},
			},
		}},
	}
	got := responsesBodyFromChat("m", body, true)
	input, _ := got["input"].([]any)
	content := input[0].(map[string]any)["content"].([]any)
	if content[0].(map[string]any)["type"] != "input_text" {
		t.Errorf("text part = %v", content[0])
	}
	image := content[1].(map[string]any)
	if image["type"] != "input_image" || image["image_url"] != "data:image/png;base64,AAA" {
		t.Errorf("image part = %v", image)
	}
}

// TestResponsesToChatBodyRoundTrip covers a responses request from a native
// /v1/responses client being served by a chat-only model.
func TestResponsesToChatBodyRoundTrip(t *testing.T) {
	body := map[string]any{
		"model":        "claude-sonnet-5.5",
		"instructions": "Be brief.",
		"input": []any{
			map[string]any{"type": "message", "role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": "Weather?"},
			}},
			map[string]any{"type": "function_call", "call_id": "c1", "name": "get_weather", "arguments": `{"city":"Paris"}`},
			map[string]any{"type": "function_call_output", "call_id": "c1", "output": "18C"},
		},
		"tools": []any{map[string]any{
			"type":        "function",
			"name":        "get_weather",
			"description": "w",
			"parameters":  map[string]any{"type": "object"},
		}},
		"tool_choice":       map[string]any{"type": "function", "name": "get_weather"},
		"max_output_tokens": json.Number("256"),
		"reasoning":         map[string]any{"effort": "low"},
		"text": map[string]any{"format": map[string]any{
			"type": "json_schema", "name": "out", "strict": true,
			"schema": map[string]any{"type": "object"},
		}},
	}

	got := chatBodyFromResponses("claude-sonnet-5.5", body)

	messages, _ := got["messages"].([]any)
	if len(messages) != 4 {
		t.Fatalf("messages = %d, want 4: %v", len(messages), messages)
	}
	if first := messages[0].(map[string]any); first["role"] != "system" || first["content"] != "Be brief." {
		t.Errorf("system message = %v", first)
	}
	call := messages[2].(map[string]any)
	calls, _ := call["tool_calls"].([]any)
	if len(calls) != 1 {
		t.Fatalf("assistant tool_calls = %v", call)
	}
	if fn := calls[0].(map[string]any)["function"].(map[string]any); fn["name"] != "get_weather" {
		t.Errorf("tool call = %v", fn)
	}
	if tool := messages[3].(map[string]any); tool["role"] != "tool" || tool["tool_call_id"] != "c1" {
		t.Errorf("tool message = %v", tool)
	}
	if got["max_tokens"] != json.Number("256") || got["reasoning_effort"] != "low" {
		t.Errorf("limits = %v / %v", got["max_tokens"], got["reasoning_effort"])
	}
	format, _ := got["response_format"].(map[string]any)
	schema, _ := format["json_schema"].(map[string]any)
	if format["type"] != "json_schema" || schema["name"] != "out" || schema["strict"] != true {
		t.Errorf("response_format = %v", format)
	}
	toolChoice, _ := got["tool_choice"].(map[string]any)
	if toolChoice["type"] != "function" {
		t.Errorf("tool_choice = %v", toolChoice)
	}
}

// TestChatFromResponseBody verifies the non-streaming chat view of a copilot
// responses object, including tool calls and usage.
func TestChatFromResponseBody(t *testing.T) {
	payload := map[string]any{
		"usage": map[string]any{
			"input_tokens":  json.Number("50"),
			"output_tokens": json.Number("18"),
			"total_tokens":  json.Number("68"),
		},
		"output": []any{
			map[string]any{"type": "message", "content": []any{
				map[string]any{"type": "output_text", "text": "Checking."},
			}},
			map[string]any{"type": "function_call", "call_id": "call_9", "name": "get_weather", "arguments": `{"city":"Paris"}`},
		},
	}
	got := chatFromResponseBody("copilot-gpt-6-luna", 42, payload)

	choice := got["choices"].([]any)[0].(map[string]any)
	if choice["finish_reason"] != "tool_calls" {
		t.Errorf("finish_reason = %v", choice["finish_reason"])
	}
	message := choice["message"].(map[string]any)
	calls, _ := message["tool_calls"].([]any)
	if len(calls) != 1 {
		t.Fatalf("tool_calls = %v", message)
	}
	call := calls[0].(map[string]any)
	if call["id"] != "call_9" {
		t.Errorf("tool call id = %v", call["id"])
	}
	if message["content"] != nil {
		t.Errorf("content = %v, want nil beside tool calls", message["content"])
	}
	usage := got["usage"].(map[string]any)
	if usage["prompt_tokens"] != int64(50) || usage["completion_tokens"] != int64(18) {
		t.Errorf("usage = %v", usage)
	}
}

// TestChatFromIncompleteResponseBody pins that a truncated responses object
// surfaces as chat finish_reason "length", not a clean stop.
func TestChatFromIncompleteResponseBody(t *testing.T) {
	payload := map[string]any{
		"status": "incomplete",
		"output": []any{map[string]any{"type": "message", "content": []any{
			map[string]any{"type": "output_text", "text": "half an ans"},
		}}},
	}
	got := chatFromResponseBody("m", 1, payload)
	choice := got["choices"].([]any)[0].(map[string]any)
	if choice["finish_reason"] != "length" {
		t.Errorf("finish_reason = %v, want length", choice["finish_reason"])
	}
}

// TestResponseBodyFromChatMarksTruncation is the other direction: a chat
// completion that stopped at the token limit is an incomplete response.
func TestResponseBodyFromChatMarksTruncation(t *testing.T) {
	payload := map[string]any{
		"choices": []any{map[string]any{
			"message":       map[string]any{"role": "assistant", "content": "half"},
			"finish_reason": "length",
		}},
	}
	got := responseBodyFromChat("m", payload)
	if got["status"] != "incomplete" {
		t.Errorf("status = %v, want incomplete", got["status"])
	}
	details, _ := got["incomplete_details"].(map[string]any)
	if details["reason"] != "max_output_tokens" {
		t.Errorf("incomplete_details = %v", got["incomplete_details"])
	}

	payload["choices"].([]any)[0].(map[string]any)["finish_reason"] = "stop"
	if got := responseBodyFromChat("m", payload); got["status"] != "completed" {
		t.Errorf("completed answer reported as %v", got["status"])
	}
}

// TestResponseStreamTranslatesChatChunks drives the streaming bridge with raw
// chat chunks: text, then a tool call, then the usage-only final chunk.
func TestResponseStreamTranslatesChatChunks(t *testing.T) {
	recorder := newRecordingWriter()
	out := &sseWriter{w: recorder}
	state := &responseStream{out: out, modelID: "copilot-claude-sonnet-5.5", responseID: "resp_test", createdAt: 1}
	if err := state.start(); err != nil {
		t.Fatal(err)
	}

	raw := strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}`,
		`data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
		`data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}`,
		`data: [DONE]`,
		"",
	}, "\n\n")
	failure := state.consumeChatStream(strings.NewReader(raw))
	if failure != "" {
		t.Fatalf("stream reported failure: %s", failure)
	}
	state.finish(failure)

	body := recorder.body.String()
	for _, want := range []string{
		"event: response.created",
		"event: response.output_text.delta",
		`"delta":"Hel"`,
		"event: response.function_call_arguments.done",
		`"arguments":"{\"city\":\"Paris\"}"`,
		"event: response.output_item.done",
		"event: response.completed",
		`"output_tokens":7`,
		`"status":"completed"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("stream missing %q\n%s", want, body)
		}
	}
	// Text must precede the tool call item, and sequence numbers must be
	// monotonically increasing across every event.
	if strings.Index(body, "output_text.done") > strings.Index(body, "function_call_arguments.done") {
		t.Error("text item closed after the tool call; order is wrong")
	}
	checkSequenceNumbers(t, body)
}

// TestResponseStreamReportsUpstreamError fails the way a dropped upstream
// connection does: text arrives, then the stream stops with no finish_reason.
func TestResponseStreamReportsUpstreamError(t *testing.T) {
	recorder := newRecordingWriter()
	state := &responseStream{out: &sseWriter{w: recorder}, modelID: "m", responseID: "resp_test", createdAt: 1}
	if err := state.start(); err != nil {
		t.Fatal(err)
	}
	raw := "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n"
	failure := state.consumeChatStream(strings.NewReader(raw))
	if failure == "" {
		t.Fatal("truncated stream reported success")
	}
	state.finish(failure)

	body := recorder.body.String()
	if !strings.Contains(body, "event: response.failed") {
		t.Errorf("missing response.failed:\n%s", body)
	}
	if strings.Contains(body, "event: response.completed") {
		t.Errorf("a broken stream must not report completion:\n%s", body)
	}
	if !strings.Contains(body, `"status":"failed"`) {
		t.Errorf("terminal status not failed:\n%s", body)
	}
}

// TestResponseStreamReportsTruncation maps a chat length cut-off to an
// incomplete response, so a client can tell the answer was truncated.
func TestResponseStreamReportsTruncation(t *testing.T) {
	recorder := newRecordingWriter()
	state := &responseStream{out: &sseWriter{w: recorder}, modelID: "m", responseID: "resp_test", createdAt: 1}
	if err := state.start(); err != nil {
		t.Fatal(err)
	}
	raw := strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"content":"cut"}}]}`,
		`data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}`,
		`data: [DONE]`,
		"",
	}, "\n\n")
	failure := state.consumeChatStream(strings.NewReader(raw))
	if failure != "" {
		t.Fatalf("a token-limit stop is not a failure: %s", failure)
	}
	state.finish(failure)

	body := recorder.body.String()
	if !strings.Contains(body, "event: response.incomplete") {
		t.Errorf("missing response.incomplete:\n%s", body)
	}
	if strings.Contains(body, "event: response.completed") {
		t.Errorf("a truncated generation must not report completion:\n%s", body)
	}
	if !strings.Contains(body, `"reason":"max_output_tokens"`) {
		t.Errorf("missing incomplete_details:\n%s", body)
	}
}

// TestChatStreamFromResponsesEvents drives the responses-events-to-chat bridge
// with the event shapes captured from api.githubcopilot.com.
func TestChatStreamFromResponsesEvents(t *testing.T) {
	events := []struct{ name, data string }{
		{"response.created", `{"type":"response.created","response":{"id":"r","status":"in_progress"}}`},
		{"response.output_text.delta", `{"type":"response.output_text.delta","delta":"Hi"}`},
		{"response.output_text.delta", `{"type":"response.output_text.delta","delta":"!"}`},
		{"response.output_item.added", `{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_k","name":"get_weather","arguments":""}}`},
		{"response.function_call_arguments.delta", `{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"city\":\"Paris\"}"}`},
		{"response.completed", `{"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":50,"output_tokens":18,"total_tokens":68}}}`},
	}

	recorder := newRecordingWriter()
	emitter := &chatChunkWriter{out: &sseWriter{w: recorder}, created: 1, modelID: "copilot-claude-sonnet-5.5"}
	failure := streamResponsesAsChat(strings.NewReader(strings.Join(renderEvents(events), "")), emitter)
	if failure != "" {
		t.Fatalf("stream reported failure: %s", failure)
	}
	emitter.finish(failure, true)

	body := recorder.body.String()
	for _, want := range []string{
		`"delta":{"content":"Hi"}`,
		`"finish_reason":"tool_calls"`,
		`"arguments":"{\"city\":\"Paris\"}"`,
		`"completion_tokens":18`,
		"data: [DONE]",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("chat stream missing %q\n%s", want, body)
		}
	}
	if strings.Count(body, `"content":"Hi"`) != 1 || strings.Count(body, `"content":"!"`) != 1 {
		t.Errorf("text deltas lost or duplicated:\n%s", body)
	}
}

// TestChatStreamReportsResponsesFailure pins the truncation bug: copilot can
// end a responses stream with response.failed, which must not reach the chat
// client as a successful stop.
func TestChatStreamReportsResponsesFailure(t *testing.T) {
	events := []struct{ name, data string }{
		{"response.created", `{"type":"response.created","response":{"id":"r","status":"in_progress"}}`},
		{"response.output_text.delta", `{"type":"response.output_text.delta","delta":"partial"}`},
		{"response.failed", `{"type":"response.failed","response":{"id":"r","status":"failed","error":{"code":"server_error","message":"model crashed"}}}`},
	}

	recorder := newRecordingWriter()
	emitter := &chatChunkWriter{out: &sseWriter{w: recorder}, created: 1, modelID: "m"}
	failure := streamResponsesAsChat(strings.NewReader(strings.Join(renderEvents(events), "")), emitter)
	if failure != "model crashed" {
		t.Fatalf("failure = %q, want the upstream error message", failure)
	}
	emitter.finish(failure, true)

	body := recorder.body.String()
	if strings.Contains(body, `"finish_reason":"stop"`) || strings.Contains(body, `"finish_reason":"tool_calls"`) {
		t.Errorf("failed stream produced a success finish reason:\n%s", body)
	}
	if !strings.Contains(body, "model crashed") {
		t.Errorf("upstream error not surfaced to the client:\n%s", body)
	}
}

// TestScanSSEMultilineData checks the SSE parser joins data lines and ignores
// comments, which copilot's stream interleaves.
func TestScanSSEMultilineData(t *testing.T) {
	raw := ": keepalive\n\nevent: response.completed\ndata: {\"a\":1}\ndata: \n\n"
	var got []sseEvent
	if err := scanSSE(strings.NewReader(raw), func(ev sseEvent) error {
		got = append(got, ev)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("events = %d, want 1: %v", len(got), got)
	}
	if got[0].Name != "response.completed" || strings.TrimSpace(string(got[0].Data)) != `{"a":1}` {
		t.Errorf("event = %+v", got[0])
	}
}

// TestModelJSONLiteLLMShape pins the discovery document clients depend on.
func TestModelJSONLiteLLMShape(t *testing.T) {
	got := modelJSON(model{ID: "air-m", Mode: "chat", ContextWindow: 1000, MaxTokens: 100})
	if got["id"] != "air-m" || got["object"] != "model" || got["mode"] != "chat" {
		t.Fatalf("model JSON = %v", got)
	}
	if got["created"] != 1677610602 {
		t.Errorf("created = %v", got["created"])
	}
	if got["max_input_tokens"] != int64(1000) || got["max_output_tokens"] != int64(100) {
		t.Errorf("limits = %v", got)
	}
}

func checkSequenceNumbers(t *testing.T, body string) {
	t.Helper()
	last := int64(-1)
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload, err := decodeObject([]byte(strings.TrimPrefix(line, "data: ")))
		if err != nil {
			continue
		}
		value, ok := payload["sequence_number"]
		if !ok {
			continue
		}
		got := num(value)
		if got <= last {
			t.Fatalf("sequence_number %d after %d", got, last)
		}
		last = got
	}
	if last < 0 {
		t.Fatal("no sequence numbers emitted")
	}
}

func renderEvents(events []struct{ name, data string }) []string {
	out := make([]string, 0, len(events))
	for _, ev := range events {
		out = append(out, "event: "+ev.name+"\ndata: "+ev.data+"\n\n")
	}
	return out
}

// recordingWriter is an http.ResponseWriter that keeps the emitted SSE text.
type recordingWriter struct {
	header http.Header
	status int
	body   strings.Builder
}

func newRecordingWriter() *recordingWriter {
	return &recordingWriter{header: http.Header{}}
}

func (r *recordingWriter) Header() http.Header         { return r.header }
func (r *recordingWriter) WriteHeader(status int)      { r.status = status }
func (r *recordingWriter) Write(p []byte) (int, error) { return r.body.Write(p) }
func (r *recordingWriter) Flush()                      {}
