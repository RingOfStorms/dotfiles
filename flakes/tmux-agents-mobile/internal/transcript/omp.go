package transcript

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// Display caps. The log keeps everything; the phone only needs enough to see
// what happened, and a session can hold thousands of multi-kilobyte reads.
const (
	maxOutputBytes = 6 << 10
	maxOutputLines = 120
	maxDetailBytes = 4 << 10
	maxArgsBytes   = 1500
	maxDiffBytes   = 12 << 10
	maxNoticeBytes = 8 << 10
)

// ErrReset means the log changed in a way that cannot be applied
// incrementally (a branch was taken, or the file was replaced); the caller
// reloads and every viewer starts over.
var ErrReset = errors.New("transcript: session must be reloaded")

// Session is one omp session log, parsed into items and kept current by Poll.
// It is not safe for concurrent use; the hub serialises access.
type Session struct {
	conversation
	Path string

	id    string
	tools map[string]toolRef
	// pending are tool calls still waiting for a result, in call order.
	pending []string
	leaf    string

	offset int64
	dev    uint64
	ino    uint64
}

type toolRef struct{ item, part int }

// ompEntry is the subset of an omp session record the transcript needs.
type ompEntry struct {
	Type         string          `json:"type"`
	ID           string          `json:"id"`
	ParentID     *string         `json:"parentId"`
	Timestamp    string          `json:"timestamp"`
	CustomType   string          `json:"customType"`
	Display      bool            `json:"display"`
	Content      json.RawMessage `json:"content"`
	Details      json.RawMessage `json:"details"`
	Data         json.RawMessage `json:"data"`
	Message      *ompMessage     `json:"message"`
	Summary      string          `json:"summary"`
	ShortSummary string          `json:"shortSummary"`
	Title        string          `json:"title"`
	// Setting changes: model_change (Role is empty or "default" for the main
	// model), thinking_level_change, mode_change.
	Model         string  `json:"model"`
	Role          string  `json:"role"`
	ThinkingLevel *string `json:"thinkingLevel"`
	Mode          string  `json:"mode"`
}

type ompMessage struct {
	Role         string          `json:"role"`
	Content      json.RawMessage `json:"content"`
	StopReason   string          `json:"stopReason"`
	ErrorMessage string          `json:"errorMessage"`
	ToolCallID   string          `json:"toolCallId"`
	ToolName     string          `json:"toolName"`
	IsError      bool            `json:"isError"`
	Details      json.RawMessage `json:"details"`
	Files        []struct {
		Path string `json:"path"`
	} `json:"files"`
}

type ompBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// link is the cheap first-pass decode: just enough to follow the tree. The
// header lines ("title", "session") carry no parent; Title is the session
// title omp rewrites in place at the top of the file.
type link struct {
	Type     string  `json:"type"`
	ID       string  `json:"id"`
	ParentID *string `json:"parentId"`
	Title    string  `json:"title"`
}

// Open reads a whole session log.
func Open(path string) (*Session, error) {
	s := &Session{Path: path}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// ID is the session id from the log's header; omp keys its side tables
// (recaps, titles) by it.
func (s *Session) ID() string { return s.id }

func (s *Session) reset() {
	s.clear()
	s.tools = map[string]toolRef{}
	s.pending = nil
	s.leaf = ""
	s.offset = 0
}

// load parses the file from scratch. omp sessions are trees: re-sending an
// earlier message starts a branch from it. The conversation on screen is the
// path from the newest entry back to the root, exactly what omp resumes into.
func (s *Session) load() error {
	f, err := os.Open(s.Path)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	data, err := io.ReadAll(io.LimitReader(f, st.Size()))
	if err != nil {
		return err
	}
	if i := bytes.LastIndexByte(data, '\n'); i >= 0 {
		data = data[:i+1]
	} else {
		data = data[:0]
	}

	type span struct {
		id, parent string
		start, end int
	}
	var spans []span
	parents := map[string]string{}
	leaf, id, title := "", "", ""
	for start := 0; start < len(data); {
		end := start + bytes.IndexByte(data[start:], '\n')
		var l link
		if json.Unmarshal(data[start:end], &l) == nil {
			switch l.Type {
			case "session":
				id = l.ID
			case "title":
				title = l.Title
			}
			sp := span{id: l.ID, start: start, end: end}
			if l.ParentID != nil {
				sp.parent = *l.ParentID
			}
			if l.ID != "" && l.Type != "session" {
				parents[l.ID] = sp.parent
				leaf = l.ID
			}
			spans = append(spans, sp)
		}
		start = end + 1
	}
	onPath := map[string]bool{}
	for id := leaf; id != "" && !onPath[id]; id = parents[id] {
		onPath[id] = true
	}

	s.reset()
	s.seq++
	for _, sp := range spans {
		if sp.id == "" || !onPath[sp.id] {
			continue
		}
		var e ompEntry
		if json.Unmarshal(data[sp.start:sp.end], &e) != nil {
			continue
		}
		s.apply(&e, nil)
	}
	s.id = id
	// The header holds the newest title, including ones set by hand that
	// leave no title_change entry.
	if title != "" {
		s.meta.Title = title
	}
	s.leaf = leaf
	s.offset = int64(len(data))
	s.dev, s.ino = fileID(st)
	return nil
}

// Poll applies whatever omp appended since the last call and returns the
// indexes of items that changed. ErrReset means the session was reloaded
// from scratch instead.
func (s *Session) Poll() ([]int, error) {
	f, err := os.Open(s.Path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if dev, ino := fileID(st); dev != s.dev || ino != s.ino || st.Size() < s.offset {
		return nil, s.reload()
	}
	s.refreshTitle(f)
	if st.Size() == s.offset {
		return nil, nil
	}
	buf := make([]byte, st.Size()-s.offset)
	n, err := f.ReadAt(buf, s.offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	buf = buf[:n]
	last := bytes.LastIndexByte(buf, '\n')
	if last < 0 {
		return nil, nil // a line is still being written
	}
	buf = buf[:last+1]

	var changed []int
	for start := 0; start < len(buf); {
		end := start + bytes.IndexByte(buf[start:], '\n')
		line := buf[start:end]
		start = end + 1
		var l link
		if json.Unmarshal(line, &l) != nil || l.ID == "" || l.Type == "session" {
			continue
		}
		parent := ""
		if l.ParentID != nil {
			parent = *l.ParentID
		}
		if parent != s.leaf {
			return nil, s.reload()
		}
		var e ompEntry
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		s.leaf = l.ID
		s.apply(&e, &changed)
	}
	s.offset += int64(len(buf))
	return changed, nil
}

// refreshTitle re-reads the title header, which omp rewrites in place (it is
// padded so a new title fits) without necessarily appending anything.
func (s *Session) refreshTitle(f *os.File) {
	buf := make([]byte, 4<<10)
	n, _ := f.ReadAt(buf, 0)
	line, _, ok := bytes.Cut(buf[:n], []byte("\n"))
	if !ok {
		return
	}
	var l link
	if json.Unmarshal(line, &l) != nil || l.Type != "title" || l.Title == "" || l.Title == s.meta.Title {
		return
	}
	s.meta.Title = l.Title
	s.metaRev++
}

func (s *Session) reload() error {
	if err := s.load(); err != nil {
		return err
	}
	return ErrReset
}

func (s *Session) apply(e *ompEntry, changed *[]int) {
	switch e.Type {
	case "message":
		if e.Message != nil {
			s.noteActivity(e.Timestamp)
			s.applyMessage(e, changed)
		}
	case "custom_message":
		if e.CustomType == "async-result" {
			s.applyAsyncResult(e, changed)
		}
		if e.Display {
			s.noteActivity(e.Timestamp)
			s.add(&Item{ID: e.ID, Kind: KindNotice, Label: e.CustomType, Text: clip(contentText(e.Content), maxNoticeBytes)}, changed)
		}
	case "title_change":
		s.setTitle(e.Title)
	case "model_change":
		// Other roles (smol, slow) configure helper models, not the one
		// talking.
		if e.Role == "" || e.Role == "default" || e.Role == "temporary" {
			s.setting(e.ID, "model", shortModel(e.Model), changed)
		}
	case "thinking_level_change":
		if e.ThinkingLevel != nil {
			s.setting(e.ID, "thinking", *e.ThinkingLevel, changed)
		}
	case "mode_change":
		s.setting(e.ID, "mode", modeLabel(e.Mode), changed)
	case "compaction":
		label := e.ShortSummary
		if label == "" {
			label = "context compacted"
		}
		s.add(&Item{ID: e.ID, Kind: KindCompaction, Label: label, Text: e.Summary}, changed)
	case "branch_summary":
		if strings.TrimSpace(e.Summary) != "" {
			s.add(&Item{ID: e.ID, Kind: KindNotice, Label: "branch summary", Text: clip(e.Summary, maxNoticeBytes)}, changed)
		}
	case "custom":
		switch e.CustomType {
		case "session_exit":
			// Background jobs die with the agent.
			s.stopPending(changed)
			for id := range s.jobs {
				s.settleRunningJob(id, changed)
			}
		case "user_todo_edit":
			s.setTodos(e.Data)
		}
	}
}

func (s *Session) noteActivity(ts string) {
	if t, err := time.Parse(time.RFC3339Nano, ts); err == nil && t.After(s.activity) {
		s.activity = t
	}
}

// shortModel drops the provider: "litellm/air-claude-opus-5.5" reads as
// "air-claude-opus-5.5".
func shortModel(m string) string {
	if i := strings.LastIndexByte(m, '/'); i >= 0 {
		return m[i+1:]
	}
	return m
}

func modeLabel(m string) string {
	switch m {
	case "none":
		return "default"
	case "":
		return ""
	}
	return strings.ReplaceAll(m, "_", " ")
}

func (s *Session) setTodos(raw json.RawMessage) {
	var d struct {
		Phases *[]TodoPhase `json:"phases"`
	}
	if json.Unmarshal(raw, &d) != nil || d.Phases == nil {
		return
	}
	s.meta.Todos = *d.Phases
	s.metaRev++
}

func (s *Session) applyMessage(e *ompEntry, changed *[]int) {
	m := e.Message
	switch m.Role {
	case "user":
		it := &Item{ID: e.ID, Kind: KindUser}
		var text []string
		for _, b := range blocks(m.Content) {
			switch b.Type {
			case "text":
				text = append(text, b.Text)
			case "image":
				it.Images++
			}
		}
		it.Text = strings.Join(text, "\n")
		s.add(it, changed)
	case "fileMention":
		var files []string
		for _, f := range m.Files {
			files = append(files, f.Path)
		}
		if len(files) == 0 {
			return
		}
		// Mentions are recorded right after the message that made them.
		if n := len(s.items); n > 0 && s.items[n-1].Kind == KindUser {
			s.seq++
			s.items[n-1].Files = append(s.items[n-1].Files, files...)
			s.touch(n-1, changed)
			return
		}
		s.add(&Item{ID: e.ID, Kind: KindNotice, Label: "files", Files: files}, changed)
	case "assistant":
		// omp waits for every tool result before the next model call, so a
		// call still unanswered when a new turn starts will never be.
		s.stopPending(changed)
		it := &Item{ID: e.ID, Kind: KindAssistant}
		for _, b := range blocks(m.Content) {
			switch b.Type {
			case "thinking":
				if strings.TrimSpace(b.Thinking) != "" {
					it.Parts = append(it.Parts, Part{Kind: PartThinking, Text: b.Thinking})
				}
			case "text":
				if strings.TrimSpace(b.Text) != "" {
					it.Parts = append(it.Parts, Part{Kind: PartText, Text: b.Text})
				}
			case "toolCall":
				it.Parts = append(it.Parts, Part{Kind: PartTool, Tool: newTool(b)})
			}
		}
		switch m.StopReason {
		case "aborted":
			it.Stop, it.StopMessage = StopInterrupted, m.ErrorMessage
		case "error":
			it.Stop, it.StopMessage = StopError, m.ErrorMessage
		}
		if len(it.Parts) == 0 && it.Stop == StopNone {
			return
		}
		idx := s.add(it, changed)
		for p, part := range it.Parts {
			if part.Kind == PartTool && part.Tool.ID != "" {
				s.tools[part.Tool.ID] = toolRef{item: idx, part: p}
				s.pending = append(s.pending, part.Tool.ID)
			}
		}
	case "toolResult":
		ref, ok := s.tools[m.ToolCallID]
		if !ok {
			return
		}
		s.seq++
		t := &s.items[ref.item].Parts[ref.part].Tool
		t.Status = ToolDone
		if m.IsError {
			t.Status = ToolError
		}
		t.Output = clipLines(contentText(m.Content), maxOutputBytes, maxOutputLines)
		var d struct {
			Diff string `json:"diff"`
		}
		if json.Unmarshal(m.Details, &d) == nil && d.Diff != "" {
			t.Diff = clip(d.Diff, maxDiffBytes)
		}
		if len(t.Jobs) > 0 {
			s.startJobs(ref, contentText(m.Content), m.IsError)
		}
		s.dropPending(m.ToolCallID)
		s.touch(ref.item, changed)
		s.applyToolDetails(m, changed)
	}
}

// applyToolDetails picks up session-wide state some tools report: the todo
// list, and background jobs that waiting tools saw settle.
func (s *Session) applyToolDetails(m *ompMessage, changed *[]int) {
	switch m.ToolName {
	case "todo":
		if !m.IsError {
			s.setTodos(m.Details)
		}
	case "vibe_wait":
		var d struct {
			Wait struct {
				Settled []struct {
					JobID  string `json:"jobId"`
					Status string `json:"status"`
				} `json:"settled"`
			} `json:"wait"`
		}
		if json.Unmarshal(m.Details, &d) == nil {
			for _, j := range d.Wait.Settled {
				s.settleJob(j.JobID, j.Status, 0, changed)
			}
		}
	case "hub":
		var d struct {
			Jobs []struct {
				ID         string `json:"id"`
				Status     string `json:"status"`
				DurationMs int64  `json:"durationMs"`
			} `json:"jobs"`
		}
		if json.Unmarshal(m.Details, &d) == nil {
			for _, j := range d.Jobs {
				s.settleJob(j.ID, j.Status, j.DurationMs, changed)
			}
		}
	}
}

// spawnedJob matches how omp's spawning tools name what they started:
// "`DocsLinks` (job `DocsLinks`)", "`world-plan` (turn job `world-plan-t1`)".
var spawnedJob = regexp.MustCompile("`([^`]+)` \\((?:turn )?job `([^`]+)`\\)")

// startJobs gives the jobs a spawning call announced their ids, once its
// result says what was actually started.
func (s *Session) startJobs(ref toolRef, result string, failed bool) {
	t := &s.items[ref.item].Parts[ref.part].Tool
	if failed {
		for i := range t.Jobs {
			t.Jobs[i].Status = ToolError
		}
		return
	}
	ids := map[string]string{}
	var order []string
	for _, m := range spawnedJob.FindAllStringSubmatch(result, -1) {
		if _, ok := ids[m[1]]; !ok {
			order = append(order, m[1])
		}
		ids[m[1]] = m[2]
	}
	// A message steered into a turn already running starts nothing new.
	var jobs []Job
	for _, j := range t.Jobs {
		if id, ok := ids[j.Name]; ok {
			j.ID = id
			delete(ids, j.Name)
			jobs = append(jobs, j)
		}
	}
	for _, name := range order {
		if id, ok := ids[name]; ok {
			jobs = append(jobs, Job{ID: id, Name: name, Status: ToolRunning})
		}
	}
	t.Jobs = jobs
	for i, j := range jobs {
		s.jobs[j.ID] = jobRef{item: ref.item, part: ref.part, job: i}
	}
}

// resultTag is the header omp puts on a delivered background result.
var resultTag = regexp.MustCompile(`<(task-result|vibe-turn) ([^>]*)>`)

var tagAttr = regexp.MustCompile(`(\w[\w-]*)="([^"]*)"`)

// applyAsyncResult settles background jobs when omp delivers their results.
// The details list the job ids; the status is only reliably in the body's
// <task-result status="…"> / <vibe-turn status="…"> headers.
func (s *Session) applyAsyncResult(e *ompEntry, changed *[]int) {
	var d struct {
		Jobs []struct {
			JobID      string `json:"jobId"`
			Status     string `json:"status"`
			DurationMs int64  `json:"durationMs"`
		} `json:"jobs"`
	}
	if json.Unmarshal(e.Details, &d) != nil || len(d.Jobs) == 0 {
		return
	}
	statuses := map[string]string{}
	for _, m := range resultTag.FindAllStringSubmatch(contentText(e.Content), -1) {
		attrs := map[string]string{}
		for _, a := range tagAttr.FindAllStringSubmatch(m[2], -1) {
			attrs[a[1]] = a[2]
		}
		id := attrs["id"]
		if m[1] == "vibe-turn" {
			id = attrs["session"] + "-t" + attrs["turn"]
		}
		statuses[id] = attrs["status"]
	}
	for _, j := range d.Jobs {
		status := j.Status
		if status == "" {
			status = statuses[j.JobID]
		}
		if status == "" {
			status = "completed"
		}
		s.settleJob(j.JobID, status, j.DurationMs, changed)
	}
}

func (s *Session) stopPending(changed *[]int) {
	if len(s.pending) == 0 {
		return
	}
	s.seq++
	for _, id := range s.pending {
		ref := s.tools[id]
		t := &s.items[ref.item].Parts[ref.part].Tool
		t.Status = ToolStopped
		// Nothing was started for a call that never returned.
		t.Jobs = nil
		s.touch(ref.item, changed)
	}
	s.pending = nil
}

func (s *Session) dropPending(id string) {
	for i, p := range s.pending {
		if p == id {
			s.pending = append(s.pending[:i], s.pending[i+1:]...)
			return
		}
	}
}

// detailKeys is where each tool keeps its headline argument.
var detailKeys = map[string]string{
	"bash":  "command",
	"read":  "path",
	"write": "path",
	"glob":  "path",
	"grep":  "pattern",
	"eval":  "code",
}

var fallbackDetailKeys = []string{"command", "path", "pattern", "query", "url", "message", "prompt", "code", "task", "op"}

func newTool(b ompBlock) Tool {
	t := Tool{ID: b.ID, Name: b.Name, Status: ToolRunning}
	var args map[string]any
	if json.Unmarshal(b.Arguments, &args) != nil {
		return t
	}
	// omp asks the model for a short intent ("i") on every call.
	if v, ok := args["i"].(string); ok {
		t.Intent = v
	} else if v, ok := args["title"].(string); ok {
		t.Intent = v
	}
	delete(args, "i")
	t.Jobs = spawnJobs(b.Name, args)
	if b.Name == "ask" {
		t.Questions = askQuestions(b.Arguments)
		askArgs(&t, args)
	}
	// Edits name their file on the script's first line: "[path#hash]".
	if b.Name == "edit" {
		if in, ok := args["input"].(string); ok {
			first, _, _ := strings.Cut(in, "\n")
			if strings.HasPrefix(first, "[") {
				path, _, _ := strings.Cut(strings.TrimPrefix(first, "["), "#")
				t.Detail = strings.TrimSuffix(path, "]")
			}
			delete(args, "input")
		}
	}
	fillToolArgs(&t, args, detailKeys[b.Name])
	return t
}

// askArgs lays out a question tool's questions as the detail.
func askArgs(t *Tool, args map[string]any) {
	if q, ok := askDetail(args["questions"]); ok {
		t.Detail = clip(q, maxDetailBytes)
		delete(args, "questions")
	}
}

// askQuestions decodes an omp ask call's questions for the native answer
// form. The list must match omp's dialog question for question, so it is all
// or nothing: a question without options is valid (omp shows it with only
// "Other") and is kept, but any malformed entry, wrongly typed field or
// duplicate id/label disables the form rather than being dropped. Strings are
// normalized as omp's dialog does (see sanitizeCR). An out-of-range
// recommendation is cleared.
func askQuestions(raw json.RawMessage) []AskQuestion {
	var a struct {
		Questions json.RawMessage `json:"questions"`
	}
	var entries []json.RawMessage
	if json.Unmarshal(raw, &a) != nil || jsonKind(a.Questions) != '[' || json.Unmarshal(a.Questions, &entries) != nil || len(entries) == 0 {
		return nil
	}
	out := make([]AskQuestion, len(entries))
	ids := make(map[string]bool, len(entries))
	for i, e := range entries {
		q, ok := askQuestion(e)
		if !ok || ids[q.ID] {
			return nil
		}
		ids[q.ID] = true
		out[i] = q
	}
	return out
}

// askQuestion validates and decodes one ask question. id, question and
// options are required; header, multi and recommended are optional (absent or
// null) but must have the right type when given.
func askQuestion(raw json.RawMessage) (AskQuestion, bool) {
	var q AskQuestion
	var f map[string]json.RawMessage
	if jsonKind(raw) != '{' || json.Unmarshal(raw, &f) != nil {
		return q, false
	}
	var opts []json.RawMessage
	if !jsonString(f["id"], &q.ID) || !jsonString(f["question"], &q.Question) ||
		jsonKind(f["options"]) != '[' || json.Unmarshal(f["options"], &opts) != nil ||
		!optString(f["header"], &q.Header) {
		return q, false
	}
	if v := f["multi"]; !jsonNull(v) {
		if k := jsonKind(v); (k != 't' && k != 'f') || json.Unmarshal(v, &q.Multi) != nil {
			return q, false
		}
	}
	var rec *float64
	if v := f["recommended"]; !jsonNull(v) {
		var n float64
		if jsonKind(v) == '"' || json.Unmarshal(v, &n) != nil || n != math.Trunc(n) {
			return q, false
		}
		rec = &n
	}
	q.Options = make([]AskOption, len(opts))
	labels := make(map[string]bool, len(opts))
	for i, ro := range opts {
		var of map[string]json.RawMessage
		o := &q.Options[i]
		if jsonKind(ro) != '{' || json.Unmarshal(ro, &of) != nil ||
			!jsonString(of["label"], &o.Label) || labels[o.Label] ||
			!optString(of["description"], &o.Description) || !optString(of["preview"], &o.Preview) {
			return q, false
		}
		labels[o.Label] = true
	}
	if rec != nil && *rec >= 0 && *rec < float64(len(q.Options)) {
		n := int(*rec)
		q.Recommended = &n
	}
	return q, true
}

// jsonKind is the first byte of a JSON value ('{', '[', '"', 't', 'f', 'n',
// a digit or '-'), or 0 when the value is absent.
func jsonKind(raw json.RawMessage) byte {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return 0
	}
	return raw[0]
}

func jsonNull(raw json.RawMessage) bool {
	k := jsonKind(raw)
	return k == 0 || k == 'n'
}

// jsonString decodes a required JSON string into *dst, normalized.
func jsonString(raw json.RawMessage, dst *string) bool {
	if jsonKind(raw) != '"' || json.Unmarshal(raw, dst) != nil {
		return false
	}
	*dst = sanitizeCR(*dst)
	return true
}

// optString is jsonString for a field that may be absent or null.
func optString(raw json.RawMessage, dst *string) bool {
	return jsonNull(raw) || jsonString(raw, dst)
}

var crRun = regexp.MustCompile(`\r+`)

// sanitizeCR mirrors omp's sanitizeCarriageReturns: CRLF becomes LF and any
// remaining run of carriage returns becomes one space.
func sanitizeCR(s string) string {
	if !strings.Contains(s, "\r") {
		return s
	}
	return crRun.ReplaceAllString(strings.ReplaceAll(s, "\r\n", "\n"), " ")
}

// fillToolArgs sets the headline argument (key, else the first common one)
// as Detail unless one is set already, and the rest as compact JSON in Args.
func fillToolArgs(t *Tool, args map[string]any, key string) {
	if t.Detail == "" {
		if _, ok := args[key].(string); !ok {
			key = ""
			for _, k := range fallbackDetailKeys {
				if _, ok := args[k].(string); ok {
					key = k
					break
				}
			}
		}
		if key != "" {
			t.Detail = clip(args[key].(string), maxDetailBytes)
			delete(args, key)
		}
	}
	if len(args) > 0 {
		if raw, err := json.Marshal(args); err == nil {
			t.Args = clip(string(raw), maxArgsBytes)
		}
	}
}

// spawnJobs lists the background agents a call asks for. Their job ids are
// only known once the result names them (see startJobs).
func spawnJobs(tool string, args map[string]any) []Job {
	var jobs []Job
	switch tool {
	case "task":
		tasks, _ := args["tasks"].([]any)
		for _, raw := range tasks {
			task, _ := raw.(map[string]any)
			name, _ := task["name"].(string)
			if name == "" {
				continue
			}
			agent, _ := task["agent"].(string)
			if agent == "" {
				agent = "task"
			}
			jobs = append(jobs, Job{Name: name, Agent: agent, Status: ToolRunning})
		}
	case "vibe_spawn":
		if name, ok := args["name"].(string); ok && name != "" {
			cli, _ := args["cli"].(string)
			jobs = append(jobs, Job{Name: name, Agent: cli, Status: ToolRunning})
		}
	case "vibe_send":
		if name, ok := args["session"].(string); ok && name != "" {
			jobs = append(jobs, Job{Name: name, Status: ToolRunning})
		}
	}
	return jobs
}

// askDetail lays out the ask tool's questions and numbered options; the
// answer itself is picked in the terminal (arrow keys and Enter).
func askDetail(v any) (string, bool) {
	questions, ok := v.([]any)
	if !ok || len(questions) == 0 {
		return "", false
	}
	var b strings.Builder
	for qi, raw := range questions {
		q, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if qi > 0 {
			b.WriteString("\n")
		}
		if text, ok := q["question"].(string); ok {
			b.WriteString(text)
			b.WriteString("\n")
		}
		options, _ := q["options"].([]any)
		for oi, rawOpt := range options {
			opt, ok := rawOpt.(map[string]any)
			if !ok {
				continue
			}
			label, _ := opt["label"].(string)
			fmt.Fprintf(&b, "  %d. %s\n", oi+1, label)
		}
	}
	return strings.TrimRight(b.String(), "\n"), b.Len() > 0
}

// blocks decodes message content, which is either a bare string or a list of
// typed blocks.
func blocks(raw json.RawMessage) []ompBlock {
	var out []ompBlock
	if json.Unmarshal(raw, &out) == nil {
		return out
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return []ompBlock{{Type: "text", Text: text}}
	}
	return nil
}

func contentText(raw json.RawMessage) string {
	var parts []string
	for _, b := range blocks(raw) {
		switch b.Type {
		case "text":
			parts = append(parts, b.Text)
		case "image":
			parts = append(parts, "[image]")
		}
	}
	return strings.Join(parts, "\n")
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && !utf8Start(s[cut]) {
		cut--
	}
	return s[:cut] + fmt.Sprintf("\n… %d more bytes", len(s)-cut)
}

func clipLines(s string, bytesMax, linesMax int) string {
	lines := strings.SplitAfter(s, "\n")
	if len(lines) > linesMax {
		rest := len(lines) - linesMax
		s = strings.Join(lines[:linesMax], "") + fmt.Sprintf("… %d more lines", rest)
	}
	return clip(s, bytesMax)
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

func fileID(st os.FileInfo) (dev, ino uint64) {
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		return uint64(sys.Dev), uint64(sys.Ino) //nolint:unconvert // int32 on darwin
	}
	return 0, 0
}
