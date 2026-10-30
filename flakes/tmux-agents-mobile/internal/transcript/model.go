// Package transcript reads an agent's own session log and turns it into a
// list of chat items (user messages, assistant turns with their tool calls,
// notices), so the phone can show the conversation natively instead of a
// re-flowed terminal. Only omp is supported so far; the model is meant to be
// shared by other agents' readers.
package transcript

import "slices"

// Kind is what an item is, which decides how it renders.
type Kind string

const (
	KindUser       Kind = "user"
	KindAssistant  Kind = "assistant"
	KindNotice     Kind = "notice"
	KindCompaction Kind = "compaction"
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
}

// clone copies an item deeply enough that later mutation of the session
// (tool results landing) cannot race a reader rendering the copy.
func (it *Item) clone() Item {
	out := *it
	out.Parts = slices.Clone(it.Parts)
	out.Files = slices.Clone(it.Files)
	return out
}
