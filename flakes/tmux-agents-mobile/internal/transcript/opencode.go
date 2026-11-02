package transcript

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// OpenCodeDB is opencode's database, which holds every session (there is no
// per-session file). It is only ever opened read-only, lazily, and shared by
// all opencode panes. Safe for concurrent use.
type OpenCodeDB struct {
	Path string

	mu sync.Mutex
	db *sql.DB
}

// DefaultOpenCodeDBPath mirrors opencode: OPENCODE_DB, resolved against its
// data dir when relative.
func DefaultOpenCodeDBPath() string {
	name := os.Getenv("OPENCODE_DB")
	if name == "" {
		name = "opencode.db"
	}
	if filepath.IsAbs(name) {
		return name
	}
	data := os.Getenv("XDG_DATA_HOME")
	if data == "" {
		home, _ := os.UserHomeDir()
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "opencode", name)
}

// NewOpenCodeDB returns a handle for the database at path; nothing is opened
// until it is first queried.
func NewOpenCodeDB(path string) *OpenCodeDB { return &OpenCodeDB{Path: path} }

func (o *OpenCodeDB) handle() (*sql.DB, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.db != nil {
		return o.db, nil
	}
	if _, err := os.Stat(o.Path); err != nil {
		return nil, err
	}
	db, err := openReadOnly(o.Path, 2)
	if err != nil {
		return nil, err
	}
	o.db = db
	return db, nil
}

// Close releases the database handle.
func (o *OpenCodeDB) Close() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.db == nil {
		return nil
	}
	err := o.db.Close()
	o.db = nil
	return err
}

// FindSession resolves which session an opencode TUI shows, like
// opencode_session in tmux-agents' resume.sh. argv is the TUI's command line
// (it names the session with -s/--session when resumed), cwd its working
// directory and paneTitle the terminal title, `OC | <title>` (cut to 37
// UTF-16 units plus "…" beyond 40). The title wins over the command line
// because the TUI can switch sessions; a bare `OpenCode` title (home screen,
// untitled session) only resolves through the command line.
func (o *OpenCodeDB) FindSession(ctx context.Context, argv []string, cwd, paneTitle string) (string, bool) {
	id := sessionArg(argv)
	title, titled := strings.CutPrefix(paneTitle, "OC | ")
	titled = titled && title != ""
	if !titled && id == "" {
		return "", false
	}
	db, err := o.handle()
	if err != nil {
		return "", false
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if !titled {
		var one int
		if db.QueryRowContext(ctx, `SELECT 1 FROM session_v2 WHERE id = ?`, id).Scan(&one) != nil {
			return "", false
		}
		return id, true
	}
	prefix, cut := strings.CutSuffix(title, "…")
	// A cut through a surrogate pair leaves a replacement character.
	prefix = strings.TrimSuffix(prefix, "\uFFFD")
	matches := func(t string) bool {
		return t == title || (cut && len(t) > len(prefix) && strings.HasPrefix(t, prefix))
	}
	if id != "" {
		var t sql.NullString
		if db.QueryRowContext(ctx, `SELECT title FROM session_v2 WHERE id = ?`, id).Scan(&t) == nil && matches(t.String) {
			return id, true
		}
	}
	if cwd == "" {
		return "", false
	}
	// The session directory is the cwd or, failing that, an ancestor of it.
	rows, err := db.QueryContext(ctx, `SELECT id, title FROM session_v2
		WHERE title IS NOT NULL
		AND (directory = ?1 OR substr(?1, 1, length(directory) + 1) = directory || '/')
		ORDER BY parent_id IS NULL DESC, directory = ?1 DESC, time_updated DESC`, cwd)
	if err != nil {
		return "", false
	}
	defer rows.Close()
	for rows.Next() {
		var sid, t string
		if rows.Scan(&sid, &t) == nil && matches(t) {
			return sid, true
		}
	}
	return "", false
}

func sessionArg(argv []string) string {
	for i, arg := range argv {
		if v, ok := strings.CutPrefix(arg, "--session="); ok {
			return v
		}
		if (arg == "-s" || arg == "--session") && i+1 < len(argv) {
			return argv[i+1]
		}
	}
	return ""
}

// OpenCodeSession is one opencode session's conversation. opencode writes a
// row per message to session_message and rewrites assistant rows in place
// while they stream (tool results land in the same row), so Poll re-reads
// rows that are new or were updated since the last read.
type OpenCodeSession struct {
	conversation
	db *OpenCodeDB
	id string

	stamp dbStamp
	// seen is each applied row's time_updated, so re-read rows that did not
	// change are skipped.
	seen       map[string]int64
	maxSeq     int64
	maxUpdated int64
	rowCount   int64
	maxRowSeq  int64
	// revert is the message a staged revert (undo) rolls back to; it and
	// everything after it are hidden. cutoff is its seq.
	revert string
	cutoff int64
}

var (
	_ Reader = (*OpenCodeSession)(nil)
	_ Reader = (*Session)(nil)
)

// Open reads the whole conversation of session id.
func (o *OpenCodeDB) Open(id string) (*OpenCodeSession, error) {
	s := &OpenCodeSession{db: o, id: id}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// ID is opencode's session id.
func (s *OpenCodeSession) ID() string { return s.id }

func (s *OpenCodeSession) load() error {
	s.clear()
	s.seen = map[string]int64{}
	s.maxSeq, s.maxUpdated, s.cutoff = 0, 0, 0
	stamp, err := statDB(s.db.Path)
	if err != nil {
		return err
	}
	db, err := s.db.handle()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.readSession(ctx, db); err != nil {
		return err
	}
	if s.revert != "" {
		_ = db.QueryRowContext(ctx, `SELECT seq FROM session_message WHERE id = ?`, s.revert).Scan(&s.cutoff)
	}
	if err := s.readCounts(ctx, db); err != nil {
		return err
	}
	if err := s.readRows(ctx, db, nil); err != nil {
		return err
	}
	s.stamp = stamp
	return nil
}

// Poll applies rows written since the last call. ErrReset means the session
// was re-read from scratch: a revert was staged or cleared, or rows were
// deleted.
func (s *OpenCodeSession) Poll() ([]int, error) {
	stamp, err := statDB(s.db.Path)
	if err != nil {
		return nil, err
	}
	if stamp == s.stamp {
		return nil, nil
	}
	db, err := s.db.handle()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	revert, rows, maxRowSeq := s.revert, s.rowCount, s.maxRowSeq
	if err := s.readSession(ctx, db); err != nil {
		return nil, err
	}
	if err := s.readCounts(ctx, db); err != nil {
		return nil, err
	}
	if s.revert != revert || s.rowCount < rows || s.maxRowSeq < maxRowSeq {
		if err := s.load(); err != nil {
			return nil, err
		}
		return nil, ErrReset
	}
	var changed []int
	if err := s.readRows(ctx, db, &changed); err != nil {
		return changed, err
	}
	s.stamp = stamp
	return changed, nil
}

// defaultTitle is what opencode calls a session until it is titled.
var defaultTitle = regexp.MustCompile(`^(New|Child) session - \d{4}-\d\d-\d\dT`)

func (s *OpenCodeSession) readSession(ctx context.Context, db *sql.DB) error {
	var title, revert sql.NullString
	err := db.QueryRowContext(ctx, `SELECT title, revert FROM session_v2 WHERE id = ?`, s.id).Scan(&title, &revert)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNoSession
	}
	if err != nil {
		return err
	}
	if !defaultTitle.MatchString(title.String) {
		s.setTitle(title.String)
	}
	s.revert = ""
	if revert.Valid {
		var r struct {
			MessageID string `json:"messageID"`
		}
		if json.Unmarshal([]byte(revert.String), &r) == nil {
			s.revert = r.MessageID
		}
	}
	return nil
}

func (s *OpenCodeSession) readCounts(ctx context.Context, db *sql.DB) error {
	return db.QueryRowContext(ctx,
		`SELECT count(*), coalesce(max(seq), 0) FROM session_message WHERE session_id = ?`, s.id,
	).Scan(&s.rowCount, &s.maxRowSeq)
}

// updateSlack re-reads rows updated slightly before the newest update seen,
// in case two writes land out of order; seen drops the repeats.
const updateSlack = 2000

func (s *OpenCodeSession) readRows(ctx context.Context, db *sql.DB, changed *[]int) error {
	rows, err := db.QueryContext(ctx, `SELECT id, type, seq, time_updated, data FROM session_message
		WHERE session_id = ? AND (seq > ? OR time_updated >= ?) AND (? = 0 OR seq < ?)
		ORDER BY seq`, s.id, s.maxSeq, s.maxUpdated-updateSlack, s.cutoff, s.cutoff)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var r ocRow
		if err := rows.Scan(&r.id, &r.typ, &r.seq, &r.updated, &r.data); err != nil {
			return err
		}
		s.maxSeq = max(s.maxSeq, r.seq)
		s.maxUpdated = max(s.maxUpdated, r.updated)
		if prev, ok := s.seen[r.id]; ok && prev == r.updated {
			continue
		}
		s.seen[r.id] = r.updated
		if t := time.UnixMilli(r.updated); t.After(s.activity) {
			s.activity = t
		}
		s.apply(r, changed)
	}
	return rows.Err()
}

type ocRow struct {
	id, typ      string
	seq, updated int64
	data         []byte
}

type ocModel struct {
	ID      string `json:"id"`
	Variant string `json:"variant"`
}

type ocError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

type ocPart struct {
	Type  string `json:"type"`
	Text  string `json:"text"`
	ID    string `json:"id"`
	Name  string `json:"name"`
	State struct {
		Status   string          `json:"status"`
		Input    json.RawMessage `json:"input"`
		Content  json.RawMessage `json:"content"`
		Metadata json.RawMessage `json:"metadata"`
		Error    *ocError        `json:"error"`
	} `json:"state"`
}

func (s *OpenCodeSession) apply(r ocRow, changed *[]int) {
	switch r.typ {
	case "user":
		var d struct {
			Text  string `json:"text"`
			Files []struct {
				Mime string `json:"mime"`
				Name string `json:"name"`
			} `json:"files"`
		}
		if json.Unmarshal(r.data, &d) != nil {
			return
		}
		it := &Item{ID: r.id, Kind: KindUser, Text: d.Text}
		for _, f := range d.Files {
			if strings.HasPrefix(f.Mime, "image/") {
				it.Images++
			} else if f.Name != "" {
				it.Files = append(it.Files, f.Name)
			}
		}
		s.put(it, changed)
	case "assistant":
		s.applyAssistant(r, changed)
	case "synthetic":
		var d struct {
			Text        string `json:"text"`
			Description string `json:"description"`
			Metadata    struct {
				Source  string `json:"source"`
				ChildID string `json:"childID"`
				State   string `json:"state"`
			} `json:"metadata"`
		}
		if json.Unmarshal(r.data, &d) != nil {
			return
		}
		label := d.Description
		if d.Metadata.Source == "subagent" {
			s.settleJob(d.Metadata.ChildID, d.Metadata.State, 0, changed)
			label = "subagent"
		}
		// Undescribed ones are reminders for the model (plan mode and such).
		if label != "" {
			s.put(&Item{ID: r.id, Kind: KindNotice, Label: label, Text: clip(d.Text, maxNoticeBytes)}, changed)
		}
	case "compaction":
		var d struct {
			Status  string `json:"status"`
			Reason  string `json:"reason"`
			Summary string `json:"summary"`
		}
		if json.Unmarshal(r.data, &d) != nil {
			return
		}
		label := "context compacted"
		switch {
		case d.Status != "" && d.Status != "completed":
			label = "compacting…"
		case d.Reason == "manual":
			label = "context compacted (manual)"
		}
		s.put(&Item{ID: r.id, Kind: KindCompaction, Label: label, Text: d.Summary}, changed)
	case "model-switched":
		var d struct {
			Model ocModel `json:"model"`
		}
		if json.Unmarshal(r.data, &d) == nil {
			s.settingOnce(r.id, "model", d.Model.ID, changed)
			s.settingOnce(r.id, "thinking", d.Model.Variant, changed)
		}
	case "agent-switched":
		var d struct {
			Agent string `json:"agent"`
		}
		if json.Unmarshal(r.data, &d) == nil {
			s.settingOnce(r.id, "agent", d.Agent, changed)
		}
	case "location-switched":
		var d struct {
			Location struct {
				Directory string `json:"directory"`
			} `json:"location"`
		}
		if json.Unmarshal(r.data, &d) == nil {
			s.settingOnce(r.id, "directory", d.Location.Directory, changed)
		}
	}
}

// settingOnce is setting, except the first value seen for a key is the
// starting state: opencode only records the model on each turn, not up front.
func (s *OpenCodeSession) settingOnce(id, key, value string, changed *[]int) {
	if _, ok := s.settings[key]; !ok && value != "" {
		s.settings[key] = value
		return
	}
	s.setting(id, key, value, changed)
}

func (s *OpenCodeSession) applyAssistant(r ocRow, changed *[]int) {
	var d struct {
		Agent   string   `json:"agent"`
		Model   ocModel  `json:"model"`
		Content []ocPart `json:"content"`
		Error   *ocError `json:"error"`
	}
	if json.Unmarshal(r.data, &d) != nil {
		return
	}
	s.settingOnce(r.id+":settings", "agent", d.Agent, changed)
	s.settingOnce(r.id+":settings", "model", d.Model.ID, changed)
	s.settingOnce(r.id+":settings", "thinking", d.Model.Variant, changed)

	it := &Item{ID: r.id, Kind: KindAssistant}
	for _, p := range d.Content {
		switch p.Type {
		case "reasoning":
			if strings.TrimSpace(p.Text) != "" {
				it.Parts = append(it.Parts, Part{Kind: PartThinking, Text: p.Text})
			}
		case "text":
			if strings.TrimSpace(p.Text) != "" {
				it.Parts = append(it.Parts, Part{Kind: PartText, Text: p.Text})
			}
		case "tool":
			t := ocTool(p)
			if t.Name == "todowrite" && t.Status != ToolError {
				s.setOpenCodeTodos(p.State.Input)
			}
			it.Parts = append(it.Parts, Part{Kind: PartTool, Tool: t})
		}
	}
	if d.Error != nil {
		it.Stop, it.StopMessage = StopError, d.Error.Message
		if d.Error.Type == "aborted" {
			it.Stop = StopInterrupted
		}
	}
	if len(it.Parts) == 0 && it.Stop == StopNone {
		return
	}
	s.put(it, changed)
}

// put adds an item, or replaces the one with its id (a row rewritten in
// place). Background jobs keep the outcome a later message settled them with.
func (s *OpenCodeSession) put(it *Item, changed *[]int) {
	i, ok := s.byID[it.ID]
	if !ok {
		s.registerJobs(s.add(it, changed))
		return
	}
	settled := map[string]Job{}
	for _, p := range s.items[i].Parts {
		for _, j := range p.Tool.Jobs {
			if j.ID != "" && j.Status != ToolRunning {
				settled[j.ID] = j
			}
		}
	}
	for p := range it.Parts {
		for k, j := range it.Parts[p].Tool.Jobs {
			if old, ok := settled[j.ID]; ok && j.Status == ToolRunning {
				it.Parts[p].Tool.Jobs[k] = old
			}
		}
	}
	s.replace(i, it, changed)
	s.registerJobs(i)
}

func (s *OpenCodeSession) setOpenCodeTodos(raw json.RawMessage) {
	var in struct {
		Todos []struct {
			Content string `json:"content"`
			Status  string `json:"status"`
		} `json:"todos"`
	}
	if json.Unmarshal(raw, &in) != nil || in.Todos == nil {
		return
	}
	tasks := make([]TodoTask, 0, len(in.Todos))
	for _, t := range in.Todos {
		status := TodoStatus(t.Status)
		if t.Status == "cancelled" {
			status = TodoAbandoned
		}
		tasks = append(tasks, TodoTask{Content: t.Content, Status: status})
	}
	s.meta.Todos = []TodoPhase{{Tasks: tasks}}
	s.metaRev++
}

// ocDetailKeys is where each opencode tool keeps its headline argument.
var ocDetailKeys = map[string]string{
	"shell":     "command",
	"read":      "path",
	"write":     "path",
	"edit":      "path",
	"glob":      "pattern",
	"grep":      "pattern",
	"webfetch":  "url",
	"websearch": "query",
	"execute":   "code",
	"skill":     "id",
	"subagent":  "prompt",
}

// subagentID finds the child session a subagent call started, in either the
// background notice or the foreground result.
var subagentID = regexp.MustCompile(`sessionID(?::\s*|=")(ses_[A-Za-z0-9]+)`)

func ocTool(p ocPart) Tool {
	t := Tool{ID: p.ID, Name: p.Name}
	switch p.State.Status {
	case "completed":
		t.Status = ToolDone
	case "error":
		t.Status = ToolError
		if p.State.Error != nil && p.State.Error.Type == "aborted" {
			t.Status = ToolStopped
		}
	default:
		t.Status = ToolRunning
	}
	output := ocContentText(p.State.Content)
	if p.State.Error != nil && p.State.Error.Message != "" {
		output = strings.TrimSpace(output + "\n" + p.State.Error.Message)
	}
	if t.Status != ToolRunning {
		t.Output = clipLines(output, maxOutputBytes, maxOutputLines)
	}

	var args map[string]any
	if json.Unmarshal(p.State.Input, &args) != nil {
		args = map[string]any{}
	}
	var meta struct {
		Files []struct {
			File  string `json:"file"`
			Patch string `json:"patch"`
		} `json:"files"`
	}
	_ = json.Unmarshal(p.State.Metadata, &meta)
	switch p.Name {
	case "subagent":
		t.Intent, _ = args["description"].(string)
		agent, _ := args["agent"].(string)
		job := Job{Name: t.Intent, Agent: agent, Status: t.Status}
		if m := subagentID.FindStringSubmatch(output); m != nil {
			job.ID = m[1]
		}
		if t.Status == ToolDone && strings.Contains(output, "working in the background") {
			job.Status = ToolRunning
		}
		if job.Name == "" {
			job.Name = agent
		}
		t.Jobs = []Job{job}
		delete(args, "description")
	case "question":
		askArgs(&t, args)
	case "edit", "write", "patch":
		var diffs []string
		for _, f := range meta.Files {
			if body := unifiedBody(f.Patch); body != "" {
				if len(meta.Files) > 1 {
					body = f.File + "\n" + body
				}
				diffs = append(diffs, body)
			}
		}
		if len(diffs) == 0 && p.Name == "write" {
			if content, ok := args["content"].(string); ok {
				diffs = append(diffs, "+"+strings.ReplaceAll(strings.TrimRight(content, "\n"), "\n", "\n+"))
			}
		}
		if len(diffs) > 0 {
			t.Diff = clip(strings.Join(diffs, "\n"), maxDiffBytes)
		}
		if p.Name == "patch" {
			t.Detail = strings.Join(patchFiles(meta.Files, args["patchText"]), "\n")
		}
		for _, k := range []string{"content", "oldString", "newString", "patchText"} {
			delete(args, k)
		}
	}
	fillToolArgs(&t, args, ocDetailKeys[p.Name])
	return t
}

// unifiedBody drops a unified diff's file headers, keeping hunks.
func unifiedBody(patch string) string {
	var out []string
	for line := range strings.SplitSeq(strings.TrimRight(patch, "\n"), "\n") {
		if strings.HasPrefix(line, "Index: ") || strings.HasPrefix(line, "=") ||
			strings.HasPrefix(line, "--- ") || strings.HasPrefix(line, "+++ ") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// patchFiles names the files a patch touched: from the result once there is
// one, else from the patch's own "*** Update File: path" lines.
func patchFiles(files []struct {
	File  string `json:"file"`
	Patch string `json:"patch"`
}, text any,
) []string {
	var out []string
	for _, f := range files {
		out = append(out, f.File)
	}
	if len(out) > 0 {
		return out
	}
	src, _ := text.(string)
	for line := range strings.SplitSeq(src, "\n") {
		for _, op := range []string{"*** Add File: ", "*** Update File: ", "*** Delete File: "} {
			if path, ok := strings.CutPrefix(line, op); ok {
				out = append(out, strings.TrimSpace(path))
			}
		}
	}
	return out
}

// ocContentText joins a tool result's text blocks; files show as a marker.
func ocContentText(raw json.RawMessage) string {
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		var text string
		if json.Unmarshal(raw, &text) == nil {
			return text
		}
		return ""
	}
	var parts []string
	for _, b := range blocks {
		switch b.Type {
		case "text":
			parts = append(parts, b.Text)
		case "file":
			parts = append(parts, "[file]")
		}
	}
	return strings.Join(parts, "\n")
}
