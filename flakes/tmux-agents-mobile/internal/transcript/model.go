// Package transcript reads an agent's own session log and turns it into a
// list of chat items (user messages, assistant turns with their tool calls,
// notices), so the phone can show the conversation natively instead of a
// re-flowed terminal. omp (session JSONL) and opencode (SQLite) are
// supported; both readers build the same items.
package transcript

import "slices"

// Kind is what an item is, which decides how it renders.
type Kind string

const (
	KindUser       Kind = "user"
	KindAssistant  Kind = "assistant"
	KindNotice     Kind = "notice"
	KindCompaction Kind = "compaction"
	// KindEvent is a divider for session settings changing mid-conversation
	// (model, thinking level, mode); see Item.Settings.
	KindEvent Kind = "event"
)

// PartKind is one block of an assistant turn.
type PartKind string

const (
	PartThinking PartKind = "thinking"
	PartText     PartKind = "text"
	PartTool     PartKind = "tool"
)

// ToolStatus is a tool call's lifecycle as far as the log tells it.
type ToolStatus string

const (
	ToolRunning ToolStatus = "running"
	ToolDone    ToolStatus = "done"
	ToolError   ToolStatus = "error"
	ToolStopped ToolStatus = "stopped"
)

// StopKind marks an assistant turn that ended abnormally.
type StopKind string

const (
	StopNone        StopKind = ""
	StopInterrupted StopKind = "interrupted"
	StopError       StopKind = "error"
)

// Item is one visible entry of the conversation.
type Item struct {
	// ID is the log entry's id; stable for the life of the session.
	ID string
	// Index is the item's position in the conversation.
	Index int
	Kind  Kind
	// Rev changes whenever the item does (a tool result arriving for one of
	// its calls), so a viewer can tell which items to re-render.
	Rev int

	// Text is the user's message, a notice's body or a compaction summary.
	Text string
	// Label names a notice (its custom type) or summarises a compaction.
	Label  string
	Images int
	Files  []string

	Parts []Part
	Stop  StopKind
	// StopMessage is the provider's error or "Interrupted by user".
	StopMessage string

	// Settings are an event's changes, in order; consecutive changes share
	// one divider.
	Settings []Setting
}

// Setting is one changed session setting, e.g. {"model", "claude-opus"}.
type Setting struct {
	Key   string
	Value string
}

// Part is one block of an assistant turn.
type Part struct {
	Kind PartKind
	Text string
	Tool Tool
}

// Tool is a tool call and, once it arrives, its result.
type Tool struct {
	ID     string
	Name   string
	Intent string
	// Detail is the call's main argument in readable form: the shell command,
	// the path read, the edit script. Args is everything else.
	Detail string
	Args   string
	Status ToolStatus
	Output string
	// Diff is the unified-ish diff omp records for edits (lines prefixed with
	// '+', '-' or ' ').
	Diff string
	// Jobs are the background agents or sessions the call started, kept
	// current as their results arrive.
	Jobs []Job
	// Questions are an omp ask call's structured questions, set once when the
	// call is parsed and never mutated afterwards, so clones share them.
	Questions []AskQuestion
}

// AskQuestion is one question of an omp ask call.
type AskQuestion struct {
	ID       string      `json:"id"`
	Question string      `json:"question"`
	Header   string      `json:"header,omitempty"`
	Options  []AskOption `json:"options"`
	Multi    bool        `json:"multi,omitempty"`
	// Recommended is the index into Options omp suggests, nil when unset.
	Recommended *int `json:"recommended,omitempty"`
}

// Recommends reports whether option i is the recommended one.
func (q AskQuestion) Recommends(i int) bool {
	return q.Recommended != nil && *q.Recommended == i
}

// AskOption is one predefined answer of an ask question.
type AskOption struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
	Preview     string `json:"preview,omitempty"`
}

// Job is one background agent (a task subagent, a vibe session turn) started
// by a tool call. Its Status reuses the tool lifecycle.
type Job struct {
	ID         string
	Name       string
	Agent      string
	Status     ToolStatus
	DurationMs int64
}

// TodoStatus is a todo task's state, as omp's todo tool records it.
type TodoStatus string

const (
	TodoPending    TodoStatus = "pending"
	TodoInProgress TodoStatus = "in_progress"
	TodoCompleted  TodoStatus = "completed"
	TodoBlocked    TodoStatus = "blocked"
	TodoAbandoned  TodoStatus = "abandoned"
)

// TodoPhase is a named group of the agent's todo list.
type TodoPhase struct {
	Name  string     `json:"name"`
	Tasks []TodoTask `json:"tasks"`
}

// TodoTask is one entry of the agent's todo list.
type TodoTask struct {
	Content string     `json:"content"`
	Status  TodoStatus `json:"status"`
	Blocker string     `json:"blocker,omitempty"`
}

// clone copies an item deeply enough that later mutation of the session
// (tool results landing) cannot race a reader rendering the copy.
func (it *Item) clone() Item {
	out := *it
	out.Parts = slices.Clone(it.Parts)
	for i := range out.Parts {
		out.Parts[i].Tool.Jobs = slices.Clone(out.Parts[i].Tool.Jobs)
	}
	out.Files = slices.Clone(it.Files)
	out.Settings = slices.Clone(it.Settings)
	return out
}

// Meta is session-wide state that is not part of the conversation flow: the
// title omp gave the session and the agent's current todo list.
type Meta struct {
	Title string
	Todos []TodoPhase
}

func cloneTodos(phases []TodoPhase) []TodoPhase {
	out := slices.Clone(phases)
	for i := range out {
		out[i].Tasks = slices.Clone(out[i].Tasks)
	}
	return out
}
