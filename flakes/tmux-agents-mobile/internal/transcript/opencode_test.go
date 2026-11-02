package transcript

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type ocFixture struct {
	t  *testing.T
	oc *OpenCodeDB
	db *sql.DB
}

func newOCFixture(t *testing.T) *ocFixture {
	t.Helper()
	path := filepath.Join(t.TempDir(), "opencode.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	f := &ocFixture{t: t, oc: NewOpenCodeDB(path), db: db}
	t.Cleanup(func() {
		_ = f.oc.Close()
		_ = db.Close()
	})
	f.exec(`PRAGMA journal_mode=WAL`)
	f.exec(`CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT, revert TEXT, time_updated INTEGER NOT NULL)`)
	f.exec(`CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)`)
	return f
}

func (f *ocFixture) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatal(err)
	}
}

var ocClock = time.Now().UnixMilli()

// row inserts or rewrites a message, stamped later than anything before.
func (f *ocFixture) row(id, typ string, seq int, data string) {
	f.t.Helper()
	ocClock++
	f.exec(`INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (?, 's1', ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET data = excluded.data, time_updated = excluded.time_updated`, id, typ, seq, ocClock, ocClock, data)
	// The reader notices changes by the files' mtime and size.
	time.Sleep(5 * time.Millisecond)
}

func TestOpenCodeConversation(t *testing.T) {
	f := newOCFixture(t)
	f.exec(`INSERT INTO session_v2 (id, directory, title, time_updated) VALUES ('s1', '/x', 'New session - 2026-11-01T00:00:00.000Z', 1)`)
	f.row("m1", "synthetic", 1, `{"text":"<system-reminder>plan mode</system-reminder>"}`)
	f.row("m2", "user", 2, `{"text":"hello","files":[{"mime":"image/png","name":"clipboard"},{"mime":"application/x-directory","name":"hosts/joe/"}]}`)
	f.row("m3", "assistant", 3, `{"agent":"build","model":{"id":"opus","variant":"high"},"content":[
		{"type":"reasoning","text":"hmm"},
		{"type":"text","text":"Let me look."},
		{"type":"tool","id":"t1","name":"shell","state":{"status":"running","input":{"command":"ls -la","timeout":5}}}]}`)

	s, err := f.oc.Open("s1")
	if err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(s); got != "user,assistant" {
		t.Fatalf("kinds = %s", got)
	}
	if s.Meta().Title != "" {
		t.Fatalf("default title shown: %q", s.Meta().Title)
	}
	user := s.Range(0, 1)[0]
	if user.Text != "hello" || user.Images != 1 || len(user.Files) != 1 || user.Files[0] != "hosts/joe/" {
		t.Fatalf("user = %+v", user)
	}
	a := s.Range(1, 2)[0]
	if len(a.Parts) != 3 || a.Parts[0].Kind != PartThinking || a.Parts[2].Tool.Status != ToolRunning ||
		a.Parts[2].Tool.Detail != "ls -la" || a.Parts[2].Tool.Args != `{"timeout":5}` {
		t.Fatalf("assistant = %+v", a)
	}
	rev := a.Rev

	// The tool finishes in place; the title arrives.
	f.exec(`UPDATE session_v2 SET title = 'Listing files'`)
	f.row("m3", "assistant", 3, `{"agent":"build","model":{"id":"opus","variant":"high"},"content":[
		{"type":"reasoning","text":"hmm"},
		{"type":"text","text":"Let me look."},
		{"type":"tool","id":"t1","name":"shell","state":{"status":"completed","input":{"command":"ls -la","timeout":5},"content":[{"type":"text","text":"a\nb"}]}}]}`)
	changed, err := s.Poll()
	if err != nil || len(changed) != 1 || changed[0] != 1 {
		t.Fatalf("poll = %v, %v", changed, err)
	}
	a = s.Range(1, 2)[0]
	if tool := a.Parts[2].Tool; tool.Status != ToolDone || tool.Output != "a\nb" || a.Rev <= rev {
		t.Fatalf("after result = %+v (rev %d -> %d)", tool, rev, a.Rev)
	}
	if s.Meta().Title != "Listing files" {
		t.Fatalf("title = %q", s.Meta().Title)
	}
	if changed, _ := s.Poll(); len(changed) != 0 {
		t.Fatalf("idle poll changed %v", changed)
	}

	// Model switch mid-conversation becomes a divider; an abort shows.
	f.row("m4", "model-switched", 4, `{"model":{"id":"sonnet","variant":"high"},"previous":{"id":"opus","variant":"high"}}`)
	f.row("m5", "assistant", 5, `{"agent":"build","model":{"id":"sonnet","variant":"high"},"content":[],"error":{"type":"aborted","message":"Step interrupted"}}`)
	if _, err := s.Poll(); err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(s); got != "user,assistant,event,assistant" {
		t.Fatalf("kinds = %s", got)
	}
	ev := s.Range(2, 3)[0]
	if len(ev.Settings) != 1 || ev.Settings[0] != (Setting{Key: "model", Value: "sonnet"}) {
		t.Fatalf("event = %+v", ev.Settings)
	}
	if last := s.Range(3, 4)[0]; last.Stop != StopInterrupted || last.StopMessage != "Step interrupted" {
		t.Fatalf("aborted = %+v", last)
	}

	// Undo hides the reverted message and everything after it.
	f.exec(`UPDATE session_v2 SET revert = '{"messageID":"m4"}'`)
	time.Sleep(5 * time.Millisecond)
	if _, err := s.Poll(); !errors.Is(err, ErrReset) {
		t.Fatalf("revert poll = %v", err)
	}
	if got := kindsOf(s); got != "user,assistant" {
		t.Fatalf("after revert = %s", got)
	}
	// Committing deletes the rows; clearing the revert reloads again.
	f.exec(`DELETE FROM session_message WHERE seq >= 4`)
	f.exec(`UPDATE session_v2 SET revert = NULL`)
	time.Sleep(5 * time.Millisecond)
	if _, err := s.Poll(); !errors.Is(err, ErrReset) {
		t.Fatalf("commit poll = %v", err)
	}
	if got := kindsOf(s); got != "user,assistant" {
		t.Fatalf("after commit = %s", got)
	}
}

func TestOpenCodeToolsTodosAndSubagents(t *testing.T) {
	f := newOCFixture(t)
	f.exec(`INSERT INTO session_v2 (id, directory, title, time_updated) VALUES ('s1', '/x', 'Work', 1)`)
	f.row("m1", "user", 1, `{"text":"go"}`)
	f.row("m2", "assistant", 2, `{"agent":"build","model":{"id":"opus"},"content":[
		{"type":"tool","id":"t1","name":"todowrite","state":{"status":"completed","input":{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"},{"content":"three","status":"cancelled"}]}}},
		{"type":"tool","id":"t2","name":"edit","state":{"status":"completed","input":{"path":"/r/a.go","oldString":"x","newString":"y"},"metadata":{"files":[{"file":"a.go","patch":"Index: a.go\n===\n--- a.go\n+++ a.go\n@@ -1 +1 @@\n-x\n+y\n"}]}}},
		{"type":"tool","id":"t3","name":"patch","state":{"status":"running","input":{"patchText":"*** Begin Patch\n*** Update File: /r/b.go\n@@\n-a\n+b\n*** End Patch"}}},
		{"type":"tool","id":"t4","name":"subagent","state":{"status":"completed","input":{"agent":"explore","description":"Scan docs","prompt":"look around"},"content":[{"type":"text","text":"The subagent is working in the background (sessionID: ses_child1). You will be notified automatically when it finishes."}]}},
		{"type":"tool","id":"t5","name":"read","state":{"status":"error","input":{"path":"/nope"},"error":{"type":"aborted","message":"Tool execution interrupted"}}}]}`)

	s, err := f.oc.Open("s1")
	if err != nil {
		t.Fatal(err)
	}
	todos := s.Meta().Todos
	if len(todos) != 1 || len(todos[0].Tasks) != 3 || todos[0].Tasks[1].Status != TodoInProgress || todos[0].Tasks[2].Status != TodoAbandoned {
		t.Fatalf("todos = %+v", todos)
	}
	parts := s.Range(1, 2)[0].Parts
	if edit := parts[1].Tool; edit.Detail != "/r/a.go" || edit.Diff != "@@ -1 +1 @@\n-x\n+y" || edit.Args != "" {
		t.Fatalf("edit = %+v", edit)
	}
	if patch := parts[2].Tool; patch.Detail != "/r/b.go" || patch.Args != "" {
		t.Fatalf("patch = %+v", patch)
	}
	sub := parts[3].Tool
	if sub.Intent != "Scan docs" || len(sub.Jobs) != 1 || sub.Jobs[0] != (Job{ID: "ses_child1", Name: "Scan docs", Agent: "explore", Status: ToolRunning}) {
		t.Fatalf("subagent = %+v", sub)
	}
	if read := parts[4].Tool; read.Status != ToolStopped || !strings.Contains(read.Output, "interrupted") {
		t.Fatalf("read = %+v", read)
	}

	f.row("m3", "synthetic", 3, `{"text":"<subagent sessionID=\"ses_child1\" state=\"completed\" description=\"Scan docs\">\nfound it\n</subagent>","description":"Scan docs","metadata":{"source":"subagent","childID":"ses_child1","agent":"explore","state":"completed"}}`)
	changed, err := s.Poll()
	if err != nil || len(changed) != 2 {
		t.Fatalf("poll = %v, %v", changed, err)
	}
	if job := s.Range(1, 2)[0].Parts[3].Tool.Jobs[0]; job.Status != ToolDone {
		t.Fatalf("job = %+v", job)
	}
	if n := s.Range(2, 3)[0]; n.Kind != KindNotice || n.Label != "subagent" {
		t.Fatalf("notice = %+v", n)
	}

	// The spawning row being rewritten (the patch finishing) keeps the
	// settled job.
	f.row("m2", "assistant", 2, strings.Replace(mustRow(t, f, "m2"), `"status":"running"`, `"status":"completed"`, 1))
	if _, err := s.Poll(); err != nil {
		t.Fatal(err)
	}
	parts = s.Range(1, 2)[0].Parts
	if parts[2].Tool.Status != ToolDone || parts[3].Tool.Jobs[0].Status != ToolDone {
		t.Fatalf("after rewrite: patch %s, job %s", parts[2].Tool.Status, parts[3].Tool.Jobs[0].Status)
	}
}

func mustRow(t *testing.T, f *ocFixture, id string) string {
	t.Helper()
	var data string
	if err := f.db.QueryRow(`SELECT data FROM session_message WHERE id = ?`, id).Scan(&data); err != nil {
		t.Fatal(err)
	}
	return data
}

func TestOpenCodeFindSession(t *testing.T) {
	f := newOCFixture(t)
	f.exec(`INSERT INTO session_v2 (id, parent_id, directory, title, time_updated) VALUES
		('a', NULL, '/r', 'Building the mobile viewer for tmux panes today', 1),
		('b', NULL, '/r', 'Other work', 2),
		('c', NULL, '/elsewhere', 'Other work', 3),
		('d', 'a', '/r', 'Other work', 4)`)
	ctx := context.Background()
	cases := []struct {
		name  string
		argv  []string
		cwd   string
		title string
		want  string
	}{
		{"exact title under cwd", []string{"opencode"}, "/r", "OC | Other work", "b"},
		{"ancestor directory", []string{"opencode"}, "/r/sub", "OC | Other work", "b"},
		{"truncated title", []string{"opencode"}, "/r", "OC | Building the mobile viewer for tmux…", "a"},
		{"argument agrees with title", []string{"opencode", "-s", "a"}, "/r", "OC | Building the mobile viewer for tmux…", "a"},
		{"title overrides stale argument", []string{"opencode", "--session=a"}, "/r", "OC | Other work", "b"},
		{"untitled uses argument", []string{"opencode", "-s", "b"}, "/r", "OpenCode", "b"},
		{"untitled without argument", []string{"opencode"}, "/r", "OpenCode", ""},
		{"unknown argument", []string{"opencode", "-s", "zzz"}, "/r", "OpenCode", ""},
		{"wrong directory", []string{"opencode"}, "/nowhere", "OC | Other work", ""},
	}
	for _, c := range cases {
		got, ok := f.oc.FindSession(ctx, c.argv, c.cwd, c.title)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("%s: got %q, %v; want %q", c.name, got, ok, c.want)
		}
	}
}

func kindsOf(r Reader) string {
	var out []string
	for _, it := range r.Range(0, r.Len()) {
		out = append(out, string(it.Kind))
	}
	return strings.Join(out, ",")
}
