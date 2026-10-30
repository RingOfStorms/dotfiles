package transcript

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const header = `{"type":"session","version":3,"id":"s1","timestamp":"t","cwd":"/x"}
{"type":"model_change","id":"m0","parentId":null,"model":"x"}
`

func writeLog(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "s.jsonl")
	if err := os.WriteFile(path, []byte(header+body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func appendLog(t *testing.T, path, body string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(body); err != nil {
		t.Fatal(err)
	}
}

func kinds(s *Session) string {
	var out []string
	for _, it := range s.Tail(1000) {
		out = append(out, string(it.Kind))
	}
	return strings.Join(out, ",")
}

func TestOpenBuildsConversation(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"u1","parentId":"m0","message":{"role":"user","content":[{"type":"text","text":"hello"},{"type":"image","data":"x","mimeType":"image/png"}]}}
{"type":"message","id":"f1","parentId":"u1","message":{"role":"fileMention","files":[{"path":"a.txt","content":"..."}]}}
{"type":"message","id":"a1","parentId":"f1","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"let me look"},{"type":"toolCall","id":"c1","name":"bash","arguments":{"i":"list files","command":"ls -la","timeout":5}}]}}
{"type":"custom","id":"x1","parentId":"a1","customType":"tool_execution_start","data":{"toolCallId":"c1"}}
{"type":"message","id":"r1","parentId":"x1","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","isError":false,"content":[{"type":"text","text":"a.txt\n"}]}}
{"type":"custom_message","id":"n1","parentId":"r1","customType":"advisor","display":true,"content":"<advisory>\nbe careful\n</advisory>"}
{"type":"custom_message","id":"n2","parentId":"n1","customType":"mid-run-todo-nudge","display":false,"content":"hidden"}
{"type":"message","id":"a2","parentId":"n2","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"done"}]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := kinds(s); got != "user,assistant,notice,assistant" {
		t.Fatalf("kinds = %s", got)
	}
	items := s.Tail(10)
	if items[0].Text != "hello" || items[0].Images != 1 || len(items[0].Files) != 1 || items[0].Files[0] != "a.txt" {
		t.Fatalf("user item = %+v", items[0])
	}
	parts := items[1].Parts
	if len(parts) != 3 || parts[0].Kind != PartThinking || parts[1].Kind != PartText || parts[2].Kind != PartTool {
		t.Fatalf("assistant parts = %+v", parts)
	}
	tool := parts[2].Tool
	if tool.Name != "bash" || tool.Intent != "list files" || tool.Detail != "ls -la" || tool.Status != ToolDone || tool.Output != "a.txt\n" {
		t.Fatalf("tool = %+v", tool)
	}
	if tool.Args != `{"timeout":5}` {
		t.Fatalf("tool args = %q", tool.Args)
	}
	if items[2].Label != "advisor" {
		t.Fatalf("notice = %+v", items[2])
	}
}

func TestOpenFollowsNewestBranch(t *testing.T) {
	// u2 was re-sent from a1: the original u1→a2 branch is abandoned.
	path := writeLog(t, `{"type":"message","id":"u1","parentId":"m0","message":{"role":"user","content":"first"}}
{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"one"}]}}
{"type":"message","id":"u2","parentId":"a1","message":{"role":"user","content":"abandoned"}}
{"type":"message","id":"u3","parentId":"a1","message":{"role":"user","content":"edited"}}
{"type":"message","id":"a3","parentId":"u3","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"two"}]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	var texts []string
	for _, it := range s.Tail(10) {
		if it.Kind == KindUser {
			texts = append(texts, it.Text)
		}
	}
	if strings.Join(texts, "|") != "first|edited" {
		t.Fatalf("user messages = %v", texts)
	}
}

func TestPollAppliesAppendsAndResults(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"u1","parentId":"m0","message":{"role":"user","content":"go"}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if changed, err := s.Poll(); err != nil || len(changed) != 0 {
		t.Fatalf("idle poll = %v, %v", changed, err)
	}

	appendLog(t, path, `{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"i":"read it","path":"x.go"}}]}}
{"type":"message","id":"r1","parentId":"a1","message":{"role":"toolRe`)
	changed, err := s.Poll()
	if err != nil || len(changed) != 1 || changed[0] != 1 {
		t.Fatalf("poll = %v, %v", changed, err)
	}
	if st := s.Tail(1)[0].Parts[0].Tool.Status; st != ToolRunning {
		t.Fatalf("status before result = %s", st)
	}
	rev := s.Tail(1)[0].Rev

	// The rest of the half-written line, completing the tool result.
	appendLog(t, path, `sult","toolCallId":"c1","isError":true,"content":[{"type":"text","text":"no such file"}]}}
`)
	changed, err = s.Poll()
	if err != nil || len(changed) != 1 || changed[0] != 1 {
		t.Fatalf("poll after result = %v, %v", changed, err)
	}
	it := s.Tail(1)[0]
	if it.Parts[0].Tool.Status != ToolError || it.Parts[0].Tool.Output != "no such file" || it.Rev <= rev {
		t.Fatalf("tool after result = %+v rev %d (was %d)", it.Parts[0].Tool, it.Rev, rev)
	}
	if got := s.Since(rev); len(got) != 1 || got[0].ID != "a1" {
		t.Fatalf("Since = %+v", got)
	}
}

func TestPollResetsOnBranch(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"u1","parentId":"m0","message":{"role":"user","content":"one"}}
{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"ok"}]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	appendLog(t, path, `{"type":"message","id":"u2","parentId":"u1","message":{"role":"user","content":"branched"}}
`)
	if _, err := s.Poll(); !errors.Is(err, ErrReset) {
		t.Fatalf("poll = %v, want ErrReset", err)
	}
	if got := kinds(s); got != "user,user" {
		t.Fatalf("kinds after reset = %s", got)
	}
}

func TestUnansweredToolsStopOnNextTurn(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"a1","parentId":"m0","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"sleep 100"}}]}}
{"type":"message","id":"a2","parentId":"a1","message":{"role":"assistant","stopReason":"aborted","errorMessage":"Interrupted by user","content":[]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	items := s.Tail(10)
	if len(items) != 2 {
		t.Fatalf("items = %d", len(items))
	}
	if st := items[0].Parts[0].Tool.Status; st != ToolStopped {
		t.Fatalf("status = %s", st)
	}
	if items[1].Stop != StopInterrupted || items[1].StopMessage != "Interrupted by user" {
		t.Fatalf("stop = %+v", items[1])
	}
}

func TestEditAndAskDetails(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"a1","parentId":"m0","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"edit","arguments":{"i":"fix","input":"[src/a.go#1F2E]\nPUT 1:\n+x"}},{"type":"toolCall","id":"c2","name":"ask","arguments":{"i":"pick","questions":[{"id":"q","question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}}]}}
{"type":"message","id":"r1","parentId":"a1","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"ok"}],"details":{"diff":"-old\n+new"}}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	parts := s.Tail(1)[0].Parts
	if parts[0].Tool.Detail != "src/a.go" || parts[0].Tool.Diff != "-old\n+new" || parts[0].Tool.Args != "" {
		t.Fatalf("edit = %+v", parts[0].Tool)
	}
	if parts[1].Tool.Detail != "Which?\n  1. A\n  2. B" {
		t.Fatalf("ask detail = %q", parts[1].Tool.Detail)
	}
}

func TestClipKeepsRunesWhole(t *testing.T) {
	got := clip(strings.Repeat("é", 10), 5)
	if !strings.HasPrefix(got, "éé\n…") {
		t.Fatalf("clip = %q", got)
	}
}
