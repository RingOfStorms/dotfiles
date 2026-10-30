package transcript

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"syscall"
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
	Path string

	items []*Item
	byID  map[string]int
	tools map[string]toolRef
	// pending are tool calls still waiting for a result, in call order.
	pending []string
	seq     int
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
	CustomType   string          `json:"customType"`
	Display      bool            `json:"display"`
	Content      json.RawMessage `json:"content"`
	Message      *ompMessage     `json:"message"`
	Summary      string          `json:"summary"`
	ShortSummary string          `json:"shortSummary"`
}

type ompMessage struct {
	Role         string          `json:"role"`
	Content      json.RawMessage `json:"content"`
	StopReason   string          `json:"stopReason"`
	ErrorMessage string          `json:"errorMessage"`
	ToolCallID   string          `json:"toolCallId"`
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

// link is the cheap first-pass decode: just enough to follow the tree.
type link struct {
	Type     string  `json:"type"`
	ID       string  `json:"id"`
	ParentID *string `json:"parentId"`
}

// Open reads a whole session log.
func Open(path string) (*Session, error) {
	s := &Session{Path: path}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// Seq is the latest change number; every item's Rev is at most Seq.
func (s *Session) Seq() int { return s.seq }

// Len is the number of items.
func (s *Session) Len() int { return len(s.items) }

// Tail returns copies of the last n items.
func (s *Session) Tail(n int) []Item {
	return s.Range(max(0, len(s.items)-n), len(s.items))
}

// Range returns copies of items [from, to).
func (s *Session) Range(from, to int) []Item {
	from = max(0, from)
	to = min(len(s.items), to)
	out := make([]Item, 0, max(0, to-from))
	for i := from; i < to; i++ {
		out = append(out, s.items[i].clone())
	}
	return out
}

// Index returns the position of the item with the given id.
func (s *Session) Index(id string) (int, bool) {
	i, ok := s.byID[id]
	return i, ok
}

// Since returns copies of items changed after seq, in order.
func (s *Session) Since(seq int) []Item {
	var out []Item
	for _, it := range s.items {
		if it.Rev > seq {
			out = append(out, it.clone())
		}
	}
	return out
}

func (s *Session) reset() {
	s.items = nil
	s.byID = map[string]int{}
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
	leaf := ""
	for start := 0; start < len(data); {
		end := start + bytes.IndexByte(data[start:], '\n')
		var l link
		if json.Unmarshal(data[start:end], &l) == nil {
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

func (s *Session) reload() error {
	if err := s.load(); err != nil {
		return err
	}
	return ErrReset
}

// touch marks item i changed in this round.
func (s *Session) touch(i int, changed *[]int) {
	s.items[i].Rev = s.seq
	if changed == nil {
		return
	}
	for _, c := range *changed {
		if c == i {
			return
		}
	}
	*changed = append(*changed, i)
}

func (s *Session) add(it *Item, changed *[]int) int {
	s.seq++
	it.Index = len(s.items)
	s.items = append(s.items, it)
	if it.ID != "" {
		s.byID[it.ID] = it.Index
	}
	s.touch(it.Index, changed)
	return it.Index
}

func (s *Session) apply(e *ompEntry, changed *[]int) {
	switch e.Type {
	case "message":
		if e.Message != nil {
			s.applyMessage(e, changed)
		}
	case "custom_message":
		if e.Display {
			s.add(&Item{ID: e.ID, Kind: KindNotice, Label: e.CustomType, Text: clip(contentText(e.Content), maxNoticeBytes)}, changed)
		}
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
		if e.CustomType == "session_exit" {
			s.stopPending(changed)
		}
	}
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
		s.dropPending(m.ToolCallID)
		s.touch(ref.item, changed)
	}
}

func (s *Session) stopPending(changed *[]int) {
	if len(s.pending) == 0 {
		return
	}
	s.seq++
	for _, id := range s.pending {
		ref := s.tools[id]
		s.items[ref.item].Parts[ref.part].Tool.Status = ToolStopped
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

	if b.Name == "ask" {
		if q, ok := askDetail(args["questions"]); ok {
			t.Detail = clip(q, maxDetailBytes)
			delete(args, "questions")
		}
	}

	key := detailKeys[b.Name]
	if t.Detail != "" {
		key = ""
	}
	if _, ok := args[key].(string); !ok {
		key = ""
		for _, k := range fallbackDetailKeys {
			if _, ok := args[k].(string); ok {
				key = k
				break
			}
		}
	}
	if key != "" && t.Detail == "" {
		t.Detail = clip(args[key].(string), maxDetailBytes)
		delete(args, key)
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
	if len(args) > 0 {
		if raw, err := json.Marshal(args); err == nil {
			t.Args = clip(string(raw), maxArgsBytes)
		}
	}
	return t
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
