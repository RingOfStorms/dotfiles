package transcript

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
}

func TestAskKeepsCustomOnlyQuestions(t *testing.T) {
	tool := newTool(ompBlock{ID: "ask", Name: "ask", Arguments: []byte(`{"questions":[{"id":"custom","question":"Your answer?","options":[]},{"id":"features","question":"Which?","multi":true,"options":[{"label":"A"},{"label":"B"}]}]}`)})
	if len(tool.Questions) != 2 || tool.Questions[0].ID != "custom" || len(tool.Questions[0].Options) != 0 || tool.Questions[1].ID != "features" || !tool.Questions[1].Multi {
		t.Fatalf("question order/cardinality changed: %+v", tool.Questions)
	}
}

func TestMalformedAskDoesNotOfferPartialAnswers(t *testing.T) {
	for _, args := range []string{
		`{"questions":[{"id":"a","question":"One?","options":[]},null]}`,
		`{"questions":[{"id":"a","question":"One?","options":[null]}]}`,
		`{"questions":[{"id":"a","question":"One?","options":[{"label":"x\r\ry"},{"label":"x y"}]}]}`,
		`{"questions":[{"id":"a","question":"One?","options":[]},{"id":"a","question":"Two?","options":[]}]}`,
	} {
		tool := newTool(ompBlock{ID: "ask", Name: "ask", Arguments: []byte(args)})
		if len(tool.Questions) != 0 {
			t.Fatalf("malformed call offers answers: %s => %+v", args, tool.Questions)
		}
	}
}

func TestSessionMetaTitleAndTodos(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.jsonl")
	title := `{"type":"title","v":1,"title":"Fix the thing","source":"auto","pad":"          "}`
	body := title + "\n" + header + `{"type":"message","id":"u1","parentId":"m0","timestamp":"2026-11-01T10:00:00.500Z","message":{"role":"user","content":"go"}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-01T10:00:05.250Z","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"todo","arguments":{"op":"init"}}]}}
{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-11-01T10:00:06Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"todo","content":[{"type":"text","text":"ok"}],"details":{"op":"init","phases":[{"name":"Tasks","tasks":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"},{"content":"three","status":"blocked","blocker":"needs creds"}]}]}}}
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if s.ID() != "s1" {
		t.Fatalf("id = %q", s.ID())
	}
	m := s.Meta()
	if m.Title != "Fix the thing" {
		t.Fatalf("title = %q", m.Title)
	}
	if len(m.Todos) != 1 || len(m.Todos[0].Tasks) != 3 || m.Todos[0].Tasks[1].Status != TodoInProgress || m.Todos[0].Tasks[2].Blocker != "needs creds" {
		t.Fatalf("todos = %+v", m.Todos)
	}
	if want := time.Date(2026, 11, 1, 10, 0, 6, 0, time.UTC); !s.LastActivity().Equal(want) {
		t.Fatalf("last activity = %v", s.LastActivity())
	}

	// omp rewrites the padded title line in place.
	rev := s.MetaRev()
	renamed := strings.Replace(body, `"Fix the thing","source":"auto","pad":"          "`, `"Fixed","source":"auto","pad":"                  "`, 1)
	if len(renamed) != len(body) {
		t.Fatalf("test rewrite changed the length")
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteAt([]byte(renamed), 0); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if _, err := s.Poll(); err != nil {
		t.Fatal(err)
	}
	if s.Meta().Title != "Fixed" || s.MetaRev() == rev {
		t.Fatalf("title after rewrite = %q (rev %d, was %d)", s.Meta().Title, s.MetaRev(), rev)
	}

	appendLog(t, path, `{"type":"title_change","id":"t1","parentId":"r1","title":"Renamed by hand"}
{"type":"custom","id":"e1","parentId":"t1","customType":"user_todo_edit","data":{"phases":[]}}
`)
	if _, err := s.Poll(); err != nil {
		t.Fatal(err)
	}
	if m := s.Meta(); m.Title != "Renamed by hand" || len(m.Todos) != 0 {
		t.Fatalf("meta after edits = %+v", m)
	}
}

func TestSettingChangesBecomeDividers(t *testing.T) {
	// Settings before the first message (m0 in the header, k1) are the
	// starting state and get no divider.
	path := writeLog(t, `{"type":"thinking_level_change","id":"k1","parentId":"m0","thinkingLevel":"high"}
{"type":"message","id":"u1","parentId":"k1","message":{"role":"user","content":"hi"}}
{"type":"model_change","id":"m1","parentId":"u1","model":"litellm/air-gpt-6","role":"default"}
{"type":"thinking_level_change","id":"k2","parentId":"m1","thinkingLevel":"high"}
{"type":"model_change","id":"m2","parentId":"k2","model":"litellm/fast","role":"smol"}
{"type":"mode_change","id":"d1","parentId":"m2","mode":"plan","data":{}}
{"type":"message","id":"u2","parentId":"d1","message":{"role":"user","content":"again"}}
{"type":"mode_change","id":"d2","parentId":"u2","mode":"none"}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := kinds(s); got != "user,event,user,event" {
		t.Fatalf("kinds = %s", got)
	}
	items := s.Tail(10)
	want := []string{"model=air-gpt-6 mode=plan", "mode=default"}
	var got []string
	for _, it := range items {
		if it.Kind != KindEvent {
			continue
		}
		var kv []string
		for _, st := range it.Settings {
			kv = append(kv, st.Key+"="+st.Value)
		}
		got = append(got, strings.Join(kv, " "))
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("dividers = %q, want %q", got, want)
	}
}

func TestBackgroundJobsSettle(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"a1","parentId":"m0","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"task","arguments":{"i":"scout","context":"x","tasks":[{"name":"Alpha","agent":"scout","task":"a"},{"name":"Beta","task":"b"}]}},{"type":"toolCall","id":"c2","name":"vibe_spawn","arguments":{"i":"plan","name":"plan","cli":"good","prompt":"p"}}]}}
{"type":"message","id":"r1","parentId":"a1","message":{"role":"toolResult","toolCallId":"c1","toolName":"task","content":[{"type":"text","text":"Spawned 2 background agents using scout.\n- `+"`Alpha` (job `Alpha`)\\n- `Beta` (job `Beta`)"+`"}]}}
{"type":"message","id":"r2","parentId":"r1","message":{"role":"toolResult","toolCallId":"c2","toolName":"vibe_spawn","content":[{"type":"text","text":"Spawned good session `+"`plan` (turn job `plan-t1`)"+`. The turn result will be delivered."}]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	jobs := func() []Job {
		var out []Job
		for _, p := range s.Tail(1)[0].Parts {
			out = append(out, p.Tool.Jobs...)
		}
		return out
	}
	if j := jobs(); len(j) != 3 || j[0].ID != "Alpha" || j[0].Agent != "scout" || j[1].Agent != "task" || j[2].ID != "plan-t1" || j[2].Status != ToolRunning {
		t.Fatalf("jobs = %+v", j)
	}

	appendLog(t, path, `{"type":"custom_message","id":"n1","parentId":"r2","customType":"async-result","display":true,"content":"<system-notice>\n<task-result id=\"Alpha\" agent=\"scout\" status=\"failed (exit 1)\" duration=\"1m\">\nboom\n</task-result>\n<vibe-turn session=\"plan\" cli=\"good\" turn=\"1\" status=\"completed\" duration=\"5s\">\nok\n</vibe-turn>","details":{"jobs":[{"jobId":"Alpha","type":"task","durationMs":60000},{"jobId":"plan-t1","type":"task","durationMs":5000}]}}
{"type":"message","id":"a2","parentId":"n1","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c3","name":"hub","arguments":{"op":"wait","ids":["Beta"]}}]}}
{"type":"message","id":"r3","parentId":"a2","message":{"role":"toolResult","toolCallId":"c3","toolName":"hub","content":[{"type":"text","text":"done"}],"details":{"op":"wait","jobs":[{"id":"Beta","status":"cancelled","durationMs":1500}]}}}
`)
	changed, err := s.Poll()
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) == 0 || changed[0] != 0 {
		t.Fatalf("changed = %v, want the spawning item first", changed)
	}
	s2 := s.Range(0, 1)[0]
	var got []string
	for _, p := range s2.Parts {
		for _, j := range p.Tool.Jobs {
			got = append(got, j.Name+"="+string(j.Status))
		}
	}
	if strings.Join(got, " ") != "Alpha=error Beta=stopped plan=done" {
		t.Fatalf("settled = %v", got)
	}
	if s2.Parts[0].Tool.Jobs[0].DurationMs != 60000 {
		t.Fatalf("duration = %d", s2.Parts[0].Tool.Jobs[0].DurationMs)
	}
}

func TestSteeredSendStartsNoJob(t *testing.T) {
	path := writeLog(t, `{"type":"message","id":"a1","parentId":"m0","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"vibe_send","arguments":{"session":"plan","message":"m"}}]}}
{"type":"message","id":"r1","parentId":"a1","message":{"role":"toolResult","toolCallId":"c1","toolName":"vibe_send","content":[{"type":"text","text":"Steered `+"`plan`"+` mid-turn — the running turn sees your message at its next step."}]}}
`)
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if j := s.Tail(1)[0].Parts[0].Tool.Jobs; len(j) != 0 {
		t.Fatalf("jobs = %+v", j)
	}
}

func TestClipKeepsRunesWhole(t *testing.T) {
	got := clip(strings.Repeat("é", 10), 5)
	if !strings.HasPrefix(got, "éé\n…") {
		t.Fatalf("clip = %q", got)
	}
}
