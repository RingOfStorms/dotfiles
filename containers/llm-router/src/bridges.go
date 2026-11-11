package main

// Bridges between the two upstream dialects.
//
// Copilot serves two disjoint model families: Claude/Gemini/Kimi accept only
// /chat/completions and the GPT-5/6 family accepts only /responses. The router
// therefore exposes /v1/chat/completions and /v1/responses for every chat
// model and translates on the way out. Clients (open-webui, omp, llm_chat)
// keep using chat completions; a direct /v1/responses caller gets the other
// direction.
//
// Verified against api.githubcopilot.com (2026-11-09):
//   - /responses has no temperature/top_p (400 "Unsupported parameter"); it
//     accepts presence_penalty, frequency_penalty, seed, stop,
//     parallel_tool_calls, instructions, tools, tool_choice, text.format.
//   - tool round trips are stateless: a function_call + function_call_output
//     pair without a reasoning item is accepted (no previous_response_id).
//   - Copilot answers without "Accept: text/event-stream" only for
//     non-streaming calls, so streaming requests set it explicitly.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

const (
	chatObject   = "chat.completion"
	chatChunkObj = "chat.completion.chunk"
	responseObj  = "response"
)

// ---------------------------------------------------------------- helpers

// sseEvent is one parsed server-sent event.
type sseEvent struct {
	Name string
	Data []byte
}

// scanSSE reads events until the reader is exhausted. Consecutive "data:"
// lines are joined with newlines as the SSE spec requires.
func scanSSE(r io.Reader, fn func(sseEvent) error) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64<<10), 16<<20)
	var name string
	var data []string
	dispatch := func() error {
		if len(data) == 0 {
			name = ""
			return nil
		}
		event := sseEvent{Name: name, Data: []byte(strings.Join(data, "\n"))}
		name, data = "", nil
		return fn(event)
	}
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "":
			if err := dispatch(); err != nil {
				return err
			}
		case strings.HasPrefix(line, ":"):
			// comment/keepalive
		case strings.HasPrefix(line, "event:"):
			name = strings.TrimSpace(line[len("event:"):])
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	if err := dispatch(); err != nil {
		return err
	}
	return scanner.Err()
}

// sseWriter emits events, flushing after each one.
type sseWriter struct {
	w       http.ResponseWriter
	flusher http.Flusher
}

func newSSEWriter(w http.ResponseWriter) *sseWriter {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	return &sseWriter{w: w, flusher: flusher}
}

func (s *sseWriter) event(name string, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if name != "" {
		if _, err := fmt.Fprintf(s.w, "event: %s\n", name); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintf(s.w, "data: %s\n\n", body); err != nil {
		return err
	}
	if s.flusher != nil {
		s.flusher.Flush()
	}
	return nil
}

func (s *sseWriter) done() {
	fmt.Fprint(s.w, "data: [DONE]\n\n")
	if s.flusher != nil {
		s.flusher.Flush()
	}
}

// decodeObject parses JSON with numbers kept intact for re-encoding.
func decodeObject(data []byte) (map[string]any, error) {
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	var out map[string]any
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

func newID(prefix string) string {
	return fmt.Sprintf("%s_%d", prefix, time.Now().UnixNano())
}

// usageFromChat converts OpenAI chat usage to responses usage.
func usageFromResponses(u map[string]any) map[string]any {
	if u == nil {
		return nil
	}
	return map[string]any{
		"prompt_tokens":     num(u["input_tokens"]),
		"completion_tokens": num(u["output_tokens"]),
		"total_tokens":      num(u["total_tokens"]),
	}
}

func usageToResponses(u map[string]any) map[string]any {
	if u == nil {
		return nil
	}
	out := map[string]any{
		"input_tokens":  num(u["prompt_tokens"]),
		"output_tokens": num(u["completion_tokens"]),
		"total_tokens":  num(u["total_tokens"]),
	}
	if details, ok := u["completion_tokens_details"].(map[string]any); ok {
		if rt := num(details["reasoning_tokens"]); rt > 0 {
			out["output_tokens_details"] = map[string]any{"reasoning_tokens": rt}
		}
	}
	if details, ok := u["prompt_tokens_details"].(map[string]any); ok {
		if ct := num(details["cached_tokens"]); ct > 0 {
			out["input_tokens_details"] = map[string]any{"cached_tokens": ct}
		}
	}
	return out
}

// ------------------------------------------------- chat client -> responses upstream

// responsesBodyFromChat translates a chat completions request into a
// responses request for the same model.
func responsesBodyFromChat(upstreamModel string, body map[string]any, copilot bool) map[string]any {
	req := map[string]any{
		"model": upstreamModel,
		"store": false,
	}

	var instructions []string
	var input []any
	appendOutputText := func(text string) {
		input = append(input, map[string]any{
			"type":    "message",
			"role":    "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": text}},
		})
	}

	if messages, ok := body["messages"].([]any); ok {
		for _, raw := range messages {
			msg, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			role := str(msg["role"])
			switch role {
			case "system", "developer":
				if text := contentString(msg["content"]); text != "" {
					instructions = append(instructions, text)
				}
			case "user":
				content := userContentForResponses(msg["content"])
				if len(content) > 0 {
					input = append(input, map[string]any{"type": "message", "role": "user", "content": content})
				}
			case "assistant":
				if text := contentString(msg["content"]); text != "" {
					appendOutputText(text)
				}
				if calls, ok := msg["tool_calls"].([]any); ok {
					for _, rc := range calls {
						call, ok := rc.(map[string]any)
						if !ok {
							continue
						}
						fn, _ := call["function"].(map[string]any)
						input = append(input, map[string]any{
							"type":      "function_call",
							"call_id":   str(call["id"]),
							"name":      str(fn["name"]),
							"arguments": str(fn["arguments"]),
						})
					}
				}
			case "tool", "function":
				input = append(input, map[string]any{
					"type":    "function_call_output",
					"call_id": str(msg["tool_call_id"]),
					"output":  contentString(msg["content"]),
				})
			}
		}
	}
	if len(instructions) > 0 {
		req["instructions"] = strings.Join(instructions, "\n\n")
	}
	if len(input) > 0 {
		req["input"] = input
	}

	if tools, ok := body["tools"].([]any); ok {
		out := make([]any, 0, len(tools))
		for _, rt := range tools {
			tool, ok := rt.(map[string]any)
			if !ok || str(tool["type"]) != "function" {
				continue // web_search/file_search have no responses equivalent here
			}
			fn, _ := tool["function"].(map[string]any)
			out = append(out, map[string]any{
				"type":        "function",
				"name":        str(fn["name"]),
				"description": str(fn["description"]),
				"parameters":  fn["parameters"],
			})
		}
		if len(out) > 0 {
			req["tools"] = out
		}
	}
	switch choice := body["tool_choice"].(type) {
	case string:
		if choice != "" {
			req["tool_choice"] = choice
		}
	case map[string]any:
		if fn, ok := choice["function"].(map[string]any); ok {
			req["tool_choice"] = map[string]any{"type": "function", "name": str(fn["name"])}
		}
	}
	if parallel, ok := body["parallel_tool_calls"]; ok {
		req["parallel_tool_calls"] = parallel
	}

	if v, ok := body["max_completion_tokens"]; ok {
		req["max_output_tokens"] = v
	} else if v, ok := body["max_tokens"]; ok {
		req["max_output_tokens"] = v
	}
	if effort := str(body["reasoning_effort"]); effort != "" {
		req["reasoning"] = map[string]any{"effort": effort}
	}
	for _, key := range []string{"presence_penalty", "frequency_penalty", "seed", "stop", "user"} {
		if v, ok := body[key]; ok {
			req[key] = v
		}
	}
	// temperature/top_p: Copilot's responses models reject both, and omp
	// never sends temperature. Drop them for Copilot, forward otherwise.
	if !copilot {
		for _, key := range []string{"temperature", "top_p"} {
			if v, ok := body[key]; ok {
				req[key] = v
			}
		}
	}
	if format, ok := body["response_format"].(map[string]any); ok {
		switch str(format["type"]) {
		case "json_object":
			req["text"] = map[string]any{"format": map[string]any{"type": "json_object"}}
		case "json_schema":
			if schema, ok := format["json_schema"].(map[string]any); ok {
				text := map[string]any{
					"type":   "json_schema",
					"name":   str(schema["name"]),
					"schema": schema["schema"],
				}
				if strict, ok := schema["strict"]; ok {
					text["strict"] = strict
				}
				req["text"] = map[string]any{"format": text}
			}
		}
	}
	return req
}

// userContentForResponses converts chat content (string or parts) into
// responses input content parts.
func userContentForResponses(content any) []any {
	switch t := content.(type) {
	case string:
		if t == "" {
			return nil
		}
		return []any{map[string]any{"type": "input_text", "text": t}}
	case []any:
		parts := make([]any, 0, len(t))
		for _, rp := range t {
			part, ok := rp.(map[string]any)
			if !ok {
				continue
			}
			switch str(part["type"]) {
			case "text":
				parts = append(parts, map[string]any{"type": "input_text", "text": str(part["text"])})
			case "image_url":
				url := ""
				switch img := part["image_url"].(type) {
				case string:
					url = img
				case map[string]any:
					url = str(img["url"])
				}
				if url != "" {
					parts = append(parts, map[string]any{"type": "input_image", "image_url": url})
				}
			}
		}
		return parts
	}
	return nil
}

// chatViaResponses serves a chat completions request from the responses API.
func (s *server) chatViaResponses(w http.ResponseWriter, r *http.Request, m model, body map[string]any) {
	stream := boolean(body["stream"])
	reqBody := responsesBodyFromChat(m.Upstream, body, m.Provider == "copilot")
	reqBody["stream"] = stream

	includeUsage := false
	if opts, ok := body["stream_options"].(map[string]any); ok {
		includeUsage = boolean(opts["include_usage"])
	}

	resp, err := s.postJSON(r.Context(), m.UpstreamName, "/responses", reqBody)
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		writeError(w, http.StatusBadGateway, "llm-router: upstream request failed")
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		logUpstreamFailure("chat->responses "+m.ID, resp.StatusCode, raw)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(raw)
		return
	}

	created := time.Now().Unix()
	if !stream {
		var payload map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			writeError(w, http.StatusBadGateway, "llm-router: decode upstream response: "+err.Error())
			return
		}
		result := chatFromResponseBody(m.ID, created, payload)
		writeJSON(w, http.StatusOK, result)
		return
	}

	out := newSSEWriter(w)
	emitter := &chatChunkWriter{out: out, created: created, modelID: m.ID}
	failure := streamResponsesAsChat(resp.Body, emitter)
	if failure != "" && r.Context().Err() == nil {
		log.Printf("chat->responses %s: stream ended in failure: %s", m.ID, failure)
	}
	emitter.finish(failure, includeUsage)
}

// chatChunkWriter turns responses stream events into chat.completion.chunk
// events. It tracks what it has emitted so the terminal chunk reflects the
// upstream outcome instead of always claiming success.
type chatChunkWriter struct {
	out     *sseWriter
	created int64
	modelID string

	// slotFor maps the upstream output_index of a function call to the dense
	// chat tool_calls index clients expect.
	slotFor map[int64]int64
	next    int64
	// tools counts declared tool calls; used for the finish reason when the
	// upstream ends without saying why.
	tools int
	// length marks a generation the upstream cut off at the token limit.
	length bool
	usage  map[string]any
}

func (c *chatChunkWriter) chunk(delta map[string]any, finish any) map[string]any {
	return map[string]any{
		"id":      newID("chatcmpl"),
		"object":  chatChunkObj,
		"created": c.created,
		"model":   c.modelID,
		"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}},
	}
}

func (c *chatChunkWriter) event(delta map[string]any, finish any) error {
	return c.out.event("", c.chunk(delta, finish))
}

// streamResponsesAsChat forwards one responses stream to the chat client and
// returns the failure text when the upstream reported an error or the stream
// broke before a terminal event. An empty string means the upstream completed.
func streamResponsesAsChat(body io.Reader, c *chatChunkWriter) string {
	if c.slotFor == nil {
		c.slotFor = map[int64]int64{}
	}
	var failure string
	completed := false
	err := scanSSE(body, func(ev sseEvent) error {
		payload, err := decodeObject(ev.Data)
		if err != nil {
			return nil // tolerate non-JSON keepalives
		}
		if failure != "" {
			return nil
		}
		switch str(payload["type"]) {
		case "response.output_item.added":
			item := asMap(payload["item"])
			if str(item["type"]) != "function_call" {
				return nil
			}
			slot := c.next
			c.next++
			c.tools++
			c.slotFor[num(payload["output_index"])] = slot
			return c.event(map[string]any{
				"tool_calls": []any{map[string]any{
					"index": slot,
					"id":    str(item["call_id"]),
					"type":  "function",
					"function": map[string]any{
						"name":      str(item["name"]),
						"arguments": "",
					},
				}},
			}, nil)
		case "response.function_call_arguments.delta":
			slot, ok := c.slotFor[num(payload["output_index"])]
			if !ok {
				return nil
			}
			return c.event(map[string]any{
				"tool_calls": []any{map[string]any{
					"index":    slot,
					"function": map[string]any{"arguments": str(payload["delta"])},
				}},
			}, nil)
		case "response.output_text.delta":
			return c.event(map[string]any{"content": str(payload["delta"])}, nil)
		case "response.reasoning_text.delta":
			return c.event(map[string]any{"reasoning_content": str(payload["delta"])}, nil)
		case "response.completed":
			completed = true
			c.usage = usageFromResponses(asMap(asMap(payload["response"])["usage"]))
		case "response.incomplete":
			completed = true
			c.length = true
			c.usage = usageFromResponses(asMap(asMap(payload["response"])["usage"]))
		case "response.failed":
			completed = true
			response := asMap(payload["response"])
			if detail := asMap(response["error"]); detail != nil {
				failure = str(detail["message"])
			}
			if failure == "" {
				failure = "the upstream reported a failed response"
			}
			c.usage = usageFromResponses(asMap(response["usage"]))
		}
		return nil
	})
	if failure != "" {
		return failure
	}
	if err != nil {
		return "stream read: " + err.Error()
	}
	if !completed {
		return "stream ended before the upstream finished"
	}
	return ""
}

// finish writes the terminal chat chunk. A failed stream ends as an error
// event rather than a successful stop: a client that sees finish_reason
// "stop" would treat truncated output as a complete answer.
func (c *chatChunkWriter) finish(failure string, includeUsage bool) {
	if failure != "" {
		_ = c.out.event("", map[string]any{
			"error": map[string]any{"message": "llm-router: upstream stream failed: " + failure, "type": "upstream_error"},
		})
		c.out.done()
		return
	}
	reason := "stop"
	switch {
	case c.tools > 0:
		reason = "tool_calls"
	case c.length:
		// Chat has no "incomplete": a cut-off generation is finish_reason
		// "length", which is how clients learn the answer was truncated.
		reason = "length"
	}
	if err := c.event(map[string]any{}, reason); err != nil {
		return
	}
	if includeUsage && c.usage != nil {
		if err := c.out.event("", map[string]any{
			"id":      newID("chatcmpl"),
			"object":  chatChunkObj,
			"created": c.created,
			"model":   c.modelID,
			"choices": []any{},
			"usage":   c.usage,
		}); err != nil {
			return
		}
	}
	c.out.done()
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// chatFromResponseBody converts a complete responses object into a chat
// completion.
func chatFromResponseBody(modelID string, created int64, payload map[string]any) map[string]any {
	var text strings.Builder
	var reasoning strings.Builder
	var toolCalls []any
	output, _ := payload["output"].([]any)
	for _, ro := range output {
		item, ok := ro.(map[string]any)
		if !ok {
			continue
		}
		switch str(item["type"]) {
		case "message":
			content, _ := item["content"].([]any)
			for _, rc := range content {
				part, ok := rc.(map[string]any)
				if !ok {
					continue
				}
				switch str(part["type"]) {
				case "output_text":
					text.WriteString(str(part["text"]))
				case "refusal":
					text.WriteString(str(part["refusal"]))
				}
			}
		case "reasoning":
			summary, _ := item["summary"].([]any)
			for _, rs := range summary {
				if part, ok := rs.(map[string]any); ok {
					reasoning.WriteString(str(part["text"]))
				}
			}
		case "function_call":
			toolCalls = append(toolCalls, map[string]any{
				"id":   str(item["call_id"]),
				"type": "function",
				"function": map[string]any{
					"name":      str(item["name"]),
					"arguments": str(item["arguments"]),
				},
			})
		}
	}

	message := map[string]any{"role": "assistant", "content": text.String()}
	if reasoning.Len() > 0 {
		message["reasoning_content"] = reasoning.String()
	}
	finish := "stop"
	if len(toolCalls) > 0 {
		message["tool_calls"] = toolCalls
		message["content"] = nil
		finish = "tool_calls"
	}
	// A responses object cut off at the token limit maps to chat's "length";
	// callers rely on it to know the answer was truncated.
	if str(payload["status"]) == "incomplete" {
		finish = "length"
	}
	return map[string]any{
		"id":      newID("chatcmpl"),
		"object":  chatObject,
		"created": created,
		"model":   modelID,
		"choices": []any{map[string]any{"index": 0, "message": message, "finish_reason": finish}},
		"usage":   usageFromResponses(asMap(payload["usage"])),
	}
}

// ------------------------------------------------- chat upstream -> responses client

// chatBodyFromResponses translates a responses request into a chat
// completions request.
func chatBodyFromResponses(upstreamModel string, body map[string]any) map[string]any {
	req := map[string]any{"model": upstreamModel}
	var messages []any

	if instructions := str(body["instructions"]); instructions != "" {
		messages = append(messages, map[string]any{"role": "system", "content": instructions})
	}
	switch input := body["input"].(type) {
	case string:
		messages = append(messages, map[string]any{"role": "user", "content": input})
	case []any:
		for _, ri := range input {
			item, ok := ri.(map[string]any)
			if !ok {
				continue
			}
			switch str(item["type"]) {
			case "message":
				role := str(item["role"])
				content := messageContentForChat(item["content"])
				if role == "" {
					role = "user"
				}
				messages = append(messages, map[string]any{"role": role, "content": content})
			case "function_call":
				messages = append(messages, map[string]any{
					"role":    "assistant",
					"content": nil,
					"tool_calls": []any{map[string]any{
						"id":       str(item["call_id"]),
						"type":     "function",
						"function": map[string]any{"name": str(item["name"]), "arguments": str(item["arguments"])},
					}},
				})
			case "function_call_output":
				messages = append(messages, map[string]any{
					"role":         "tool",
					"tool_call_id": str(item["call_id"]),
					"content":      str(item["output"]),
				})
			}
		}
	}
	req["messages"] = messages

	if tools, ok := body["tools"].([]any); ok {
		out := make([]any, 0, len(tools))
		for _, rt := range tools {
			tool, ok := rt.(map[string]any)
			if !ok || str(tool["type"]) != "function" {
				continue
			}
			fn := map[string]any{"name": str(tool["name"])}
			if d := str(tool["description"]); d != "" {
				fn["description"] = d
			}
			if p, ok := tool["parameters"]; ok {
				fn["parameters"] = p
			}
			out = append(out, map[string]any{"type": "function", "function": fn})
		}
		if len(out) > 0 {
			req["tools"] = out
		}
	}
	switch choice := body["tool_choice"].(type) {
	case string:
		if choice != "" {
			req["tool_choice"] = choice
		}
	case map[string]any:
		req["tool_choice"] = map[string]any{
			"type":     "function",
			"function": map[string]any{"name": str(choice["name"])},
		}
	}
	if parallel, ok := body["parallel_tool_calls"]; ok {
		req["parallel_tool_calls"] = parallel
	}
	if v, ok := body["max_output_tokens"]; ok {
		req["max_tokens"] = v
	}
	if reasoning, ok := body["reasoning"].(map[string]any); ok {
		if effort := str(reasoning["effort"]); effort != "" {
			req["reasoning_effort"] = effort
		}
	}
	for _, key := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty", "seed", "stop", "user"} {
		if v, ok := body[key]; ok {
			req[key] = v
		}
	}
	if text, ok := body["text"].(map[string]any); ok {
		if format, ok := text["format"].(map[string]any); ok {
			switch str(format["type"]) {
			case "json_object":
				req["response_format"] = map[string]any{"type": "json_object"}
			case "json_schema":
				schema := map[string]any{"name": str(format["name"]), "schema": format["schema"]}
				if strict, ok := format["strict"]; ok {
					schema["strict"] = strict
				}
				req["response_format"] = map[string]any{"type": "json_schema", "json_schema": schema}
			}
		}
	}
	return req
}

// messageContentForChat flattens responses input content parts to chat content.
func messageContentForChat(content any) any {
	parts, ok := content.([]any)
	if !ok {
		return str(content)
	}
	var texts []string
	var chatParts []any
	images := false
	for _, rp := range parts {
		part, ok := rp.(map[string]any)
		if !ok {
			continue
		}
		switch str(part["type"]) {
		case "input_text", "output_text", "text":
			texts = append(texts, str(part["text"]))
			chatParts = append(chatParts, map[string]any{"type": "text", "text": str(part["text"])})
		case "input_image":
			if url := str(part["image_url"]); url != "" {
				images = true
				chatParts = append(chatParts, map[string]any{
					"type":      "image_url",
					"image_url": map[string]any{"url": url},
				})
			}
		}
	}
	if images {
		return chatParts
	}
	return strings.Join(texts, "\n")
}

// responsesViaChat serves a responses request from a chat completions model.
func (s *server) responsesViaChat(w http.ResponseWriter, r *http.Request, m model, body map[string]any) {
	stream := boolean(body["stream"])
	reqBody := chatBodyFromResponses(m.Upstream, body)
	reqBody["stream"] = stream
	if stream {
		reqBody["stream_options"] = map[string]any{"include_usage": true}
	}

	resp, err := s.postJSON(r.Context(), m.UpstreamName, "/chat/completions", reqBody)
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		writeError(w, http.StatusBadGateway, "llm-router: upstream request failed")
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		logUpstreamFailure("responses->chat "+m.ID, resp.StatusCode, raw)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(raw)
		return
	}

	if !stream {
		var payload map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			writeError(w, http.StatusBadGateway, "llm-router: decode upstream response: "+err.Error())
			return
		}
		result := responseBodyFromChat(m.ID, payload)
		writeJSON(w, http.StatusOK, result)
		return
	}

	out := newSSEWriter(w)
	state := &responseStream{out: out, modelID: m.ID, responseID: newID("resp"), createdAt: time.Now().Unix()}
	if err := state.start(); err != nil {
		return
	}
	failure := state.consumeChatStream(resp.Body)
	if failure != "" && r.Context().Err() == nil {
		log.Printf("responses->chat %s: stream ended in failure: %s", m.ID, failure)
	}
	state.finish(failure)
}

// responseStream turns chat.completion.chunk events into responses SSE events.
type responseStream struct {
	out        *sseWriter
	modelID    string
	responseID string
	createdAt  int64

	seq        int64
	itemOpen   bool
	textItemID string
	text       strings.Builder
	toolCalls  map[int64]*streamToolCall
	toolOrder  []int64
	usage      map[string]any
	// truncated marks a generation the upstream cut off at the token limit.
	truncated bool
}

type streamToolCall struct {
	id        string
	name      string
	arguments strings.Builder
	itemSent  bool
}

func (s *responseStream) next() int64 {
	s.seq++
	return s.seq - 1
}

func (s *responseStream) emit(event string, payload map[string]any) error {
	payload["type"] = event
	payload["sequence_number"] = s.next()
	return s.out.event(event, payload)
}

func (s *responseStream) responseObject(status string, output []any) map[string]any {
	obj := map[string]any{
		"id":         s.responseID,
		"object":     responseObj,
		"created_at": s.createdAt,
		"status":     status,
		"model":      s.modelID,
		"output":     output,
	}
	if s.usage != nil {
		obj["usage"] = s.usage
	}
	return obj
}

func (s *responseStream) start() error {
	if err := s.emit("response.created", map[string]any{
		"response": s.responseObject("in_progress", []any{}),
	}); err != nil {
		return err
	}
	return s.emit("response.in_progress", map[string]any{
		"response": s.responseObject("in_progress", []any{}),
	})
}

func (s *responseStream) consumeChatChunk(chunk map[string]any) error {
	if usage := asMap(chunk["usage"]); usage != nil {
		s.usage = usageToResponses(usage)
	}
	choices, _ := chunk["choices"].([]any)
	if len(choices) == 0 {
		return nil
	}
	choice, _ := choices[0].(map[string]any)
	delta := asMap(choice["delta"])

	if content := str(delta["content"]); content != "" {
		if !s.itemOpen {
			s.itemOpen = true
			s.textItemID = newID("msg")
			if err := s.emit("response.output_item.added", map[string]any{
				"output_index": 0,
				"item": map[string]any{
					"id": s.textItemID, "type": "message", "role": "assistant",
					"status": "in_progress", "content": []any{},
				},
			}); err != nil {
				return err
			}
			if err := s.emit("response.content_part.added", map[string]any{
				"item_id": s.textItemID, "output_index": 0, "content_index": 0,
				"part": map[string]any{"type": "output_text", "text": "", "annotations": []any{}},
			}); err != nil {
				return err
			}
		}
		s.text.WriteString(content)
		if err := s.emit("response.output_text.delta", map[string]any{
			"item_id": s.textItemID, "output_index": 0, "content_index": 0, "delta": content,
		}); err != nil {
			return err
		}
	}

	if calls, ok := delta["tool_calls"].([]any); ok {
		if s.toolCalls == nil {
			s.toolCalls = map[int64]*streamToolCall{}
		}
		for _, rc := range calls {
			call, ok := rc.(map[string]any)
			if !ok {
				continue
			}
			index := num(call["index"])
			current, ok := s.toolCalls[index]
			if !ok {
				current = &streamToolCall{}
				s.toolCalls[index] = current
				s.toolOrder = append(s.toolOrder, index)
			}
			if id := str(call["id"]); id != "" {
				current.id = id
			}
			if fn := asMap(call["function"]); fn != nil {
				if name := str(fn["name"]); name != "" {
					current.name = name
				}
				current.arguments.WriteString(str(fn["arguments"]))
			}
		}
	}
	return nil
}

// consumeChatStream forwards one chat.completion.chunk stream into the
// responses stream and returns failure text when the upstream broke, sent an
// error, or stopped without a finish_reason. Empty means it finished normally.
func (s *responseStream) consumeChatStream(body io.Reader) string {
	var failure string
	finished := false
	err := scanSSE(body, func(ev sseEvent) error {
		if strings.TrimSpace(string(ev.Data)) == "[DONE]" {
			return nil
		}
		payload, err := decodeObject(ev.Data)
		if err != nil {
			return nil
		}
		if failure != "" {
			return nil
		}
		if detail := asMap(payload["error"]); detail != nil {
			failure = str(detail["message"])
			if failure == "" {
				failure = "the upstream returned an error"
			}
			return nil
		}
		if err := s.consumeChatChunk(payload); err != nil {
			return err
		}
		choices, _ := payload["choices"].([]any)
		if len(choices) == 0 {
			return nil
		}
		choice, _ := choices[0].(map[string]any)
		switch str(choice["finish_reason"]) {
		case "":
		case "length":
			// Cut off at the token limit: an incomplete response, not success.
			s.truncated = true
			finished = true
		default:
			finished = true
		}
		return nil
	})
	if failure != "" {
		return failure
	}
	if err != nil {
		return "stream read: " + err.Error()
	}
	if !finished {
		return "stream ended before the upstream finished"
	}
	return ""
}

// finish closes any open output items and emits the terminal event. A broken
// stream ends as response.failed and a generation cut off at the token limit
// as response.incomplete; only a clean upstream exit reports
// response.completed, because clients treat that as a whole answer.
func (s *responseStream) finish(failure string) {
	status := "completed"
	switch {
	case failure != "":
		status = "failed"
	case s.truncated:
		status = "incomplete"
	}

	var output []any
	text := s.text.String()

	if s.itemOpen {
		part := map[string]any{"type": "output_text", "text": text, "annotations": []any{}}
		if s.emit("response.output_text.done", map[string]any{
			"item_id": s.textItemID, "output_index": 0, "content_index": 0, "text": text,
		}) == nil {
			s.emit("response.content_part.done", map[string]any{
				"item_id": s.textItemID, "output_index": 0, "content_index": 0, "part": part,
			})
			item := map[string]any{
				"id": s.textItemID, "type": "message", "role": "assistant",
				"status": status, "content": []any{part},
			}
			s.emit("response.output_item.done", map[string]any{"output_index": 0, "item": item})
			output = append(output, item)
		}
	}

	for i, index := range s.toolOrder {
		call := s.toolCalls[index]
		outputIndex := int64(i)
		if s.itemOpen {
			outputIndex++
		}
		itemID := newID("fc")
		arguments := call.arguments.String()
		base := map[string]any{
			"id": itemID, "type": "function_call", "call_id": call.id,
			"name": call.name, "arguments": "", "status": "in_progress",
		}
		s.emit("response.output_item.added", map[string]any{"output_index": outputIndex, "item": base})
		if arguments != "" {
			s.emit("response.function_call_arguments.delta", map[string]any{
				"item_id": itemID, "output_index": outputIndex, "delta": arguments,
			})
		}
		s.emit("response.function_call_arguments.done", map[string]any{
			"item_id": itemID, "output_index": outputIndex, "arguments": arguments,
		})
		final := map[string]any{
			"id": itemID, "type": "function_call", "call_id": call.id,
			"name": call.name, "arguments": arguments, "status": status,
		}
		s.emit("response.output_item.done", map[string]any{"output_index": outputIndex, "item": final})
		output = append(output, final)
	}

	response := s.responseObject(status, output)
	event := "response.completed"
	switch status {
	case "failed":
		event = "response.failed"
		response["error"] = map[string]any{"code": "upstream_error", "message": failure}
	case "incomplete":
		event = "response.incomplete"
		response["incomplete_details"] = map[string]any{"reason": "max_output_tokens"}
	}
	s.emit(event, map[string]any{"response": response})
}

// responseBodyFromChat converts a complete chat completion into a responses
// object. Reasoning text has no responses equivalent here, so it is dropped.
func responseBodyFromChat(modelID string, payload map[string]any) map[string]any {
	var text strings.Builder
	var output []any
	choices, _ := payload["choices"].([]any)
	if len(choices) > 0 {
		if choice, ok := choices[0].(map[string]any); ok {
			message := asMap(choice["message"])
			text.WriteString(contentString(message["content"]))
			if calls, ok := message["tool_calls"].([]any); ok {
				for _, rc := range calls {
					call, ok := rc.(map[string]any)
					if !ok {
						continue
					}
					fn := asMap(call["function"])
					output = append(output, map[string]any{
						"id": newID("fc"), "type": "function_call", "call_id": str(call["id"]),
						"name": str(fn["name"]), "arguments": str(fn["arguments"]), "status": "completed",
					})
				}
			}
		}
	}
	if text.Len() > 0 {
		output = append([]any{map[string]any{
			"id": newID("msg"), "type": "message", "role": "assistant", "status": "completed",
			"content": []any{map[string]any{"type": "output_text", "text": text.String(), "annotations": []any{}}},
		}}, output...)
	}
	status := "completed"
	if len(choices) > 0 {
		if choice, ok := choices[0].(map[string]any); ok && str(choice["finish_reason"]) == "length" {
			status = "incomplete"
		}
	}
	out := map[string]any{
		"id":         newID("resp"),
		"object":     responseObj,
		"created_at": time.Now().Unix(),
		"status":     status,
		"model":      modelID,
		"output":     output,
		"usage":      usageToResponses(asMap(payload["usage"])),
	}
	if status == "incomplete" {
		out["incomplete_details"] = map[string]any{"reason": "max_output_tokens"}
	}
	return out
}
