package transcript

import (
	"strings"
	"time"
)

// Reader is one agent session's conversation, kept current by Poll. Readers
// are not safe for concurrent use; the hub serialises access.
type Reader interface {
	// Len is the number of items.
	Len() int
	// Range returns copies of items [from, to).
	Range(from, to int) []Item
	// Poll applies whatever the agent wrote since the last call and returns
	// the indexes of items that changed. ErrReset means the conversation was
	// reloaded from scratch instead.
	Poll() ([]int, error)
	// ID is the agent's own session id.
	ID() string
	// Meta is the session-wide state; MetaRev changes whenever it does.
	Meta() Meta
	MetaRev() int
	// LastActivity is when the newest message was written; zero if unknown.
	LastActivity() time.Time
}

// conversation is the item list both readers build: items with stable ids
// and revisions, the background jobs their tool calls started, and the
// session settings seen so far (for dividers).
type conversation struct {
	items    []*Item
	byID     map[string]int
	jobs     map[string]jobRef
	seq      int
	settings map[string]string

	meta     Meta
	metaRev  int
	activity time.Time
}

type jobRef struct{ item, part, job int }

func (c *conversation) clear() {
	c.items = nil
	c.byID = map[string]int{}
	c.jobs = map[string]jobRef{}
	c.settings = map[string]string{}
	c.meta = Meta{}
	c.metaRev++
	c.activity = time.Time{}
}

// Seq is the latest change number; every item's Rev is at most Seq.
func (c *conversation) Seq() int { return c.seq }

// Len is the number of items.
func (c *conversation) Len() int { return len(c.items) }

// Tail returns copies of the last n items.
func (c *conversation) Tail(n int) []Item {
	return c.Range(max(0, len(c.items)-n), len(c.items))
}

// Range returns copies of items [from, to).
func (c *conversation) Range(from, to int) []Item {
	from = max(0, from)
	to = min(len(c.items), to)
	out := make([]Item, 0, max(0, to-from))
	for i := from; i < to; i++ {
		out = append(out, c.items[i].clone())
	}
	return out
}

// Meta returns a copy of the session-wide state.
func (c *conversation) Meta() Meta {
	return Meta{Title: c.meta.Title, Todos: cloneTodos(c.meta.Todos)}
}

// MetaRev changes whenever Meta does.
func (c *conversation) MetaRev() int { return c.metaRev }

// LastActivity is when the newest message was logged; zero if unknown.
func (c *conversation) LastActivity() time.Time { return c.activity }

// Index returns the position of the item with the given id.
func (c *conversation) Index(id string) (int, bool) {
	i, ok := c.byID[id]
	return i, ok
}

// Since returns copies of items changed after seq, in order.
func (c *conversation) Since(seq int) []Item {
	var out []Item
	for _, it := range c.items {
		if it.Rev > seq {
			out = append(out, it.clone())
		}
	}
	return out
}

func (c *conversation) setTitle(title string) {
	if title != "" && title != c.meta.Title {
		c.meta.Title = title
		c.metaRev++
	}
}

// touch marks item i changed in this round.
func (c *conversation) touch(i int, changed *[]int) {
	c.items[i].Rev = c.seq
	if changed == nil {
		return
	}
	for _, x := range *changed {
		if x == i {
			return
		}
	}
	*changed = append(*changed, i)
}

func (c *conversation) add(it *Item, changed *[]int) int {
	c.seq++
	it.Index = len(c.items)
	c.items = append(c.items, it)
	if it.ID != "" {
		c.byID[it.ID] = it.Index
	}
	c.touch(it.Index, changed)
	return it.Index
}

// replace swaps item i for a rebuilt version of it.
func (c *conversation) replace(i int, it *Item, changed *[]int) {
	c.seq++
	it.Index = i
	c.items[i] = it
	if it.ID != "" {
		c.byID[it.ID] = i
	}
	c.touch(i, changed)
}

// setting records a changed session setting as a divider. Settings logged
// before the conversation starts are the starting state, not a change;
// re-logged values are dropped; back-to-back changes share one divider.
func (c *conversation) setting(id, key, value string, changed *[]int) {
	if value == "" || c.settings[key] == value {
		return
	}
	c.settings[key] = value
	if len(c.items) == 0 {
		return
	}
	if n := len(c.items); c.items[n-1].Kind == KindEvent {
		it := c.items[n-1]
		c.seq++
		replaced := false
		for i := range it.Settings {
			if it.Settings[i].Key == key {
				it.Settings[i].Value, replaced = value, true
			}
		}
		if !replaced {
			it.Settings = append(it.Settings, Setting{Key: key, Value: value})
		}
		c.touch(n-1, changed)
		return
	}
	c.add(&Item{ID: id, Kind: KindEvent, Settings: []Setting{{Key: key, Value: value}}}, changed)
}

// registerJobs indexes the jobs of item i's tool calls that have an id, so
// later results can settle them.
func (c *conversation) registerJobs(i int) {
	for p, part := range c.items[i].Parts {
		for j, job := range part.Tool.Jobs {
			if job.ID != "" {
				c.jobs[job.ID] = jobRef{item: i, part: p, job: j}
			}
		}
	}
}

func (c *conversation) settleRunningJob(id string, changed *[]int) {
	if ref, ok := c.jobs[id]; ok && c.items[ref.item].Parts[ref.part].Tool.Jobs[ref.job].Status == ToolRunning {
		c.settleJob(id, "cancelled", 0, changed)
	}
}

// settleJob ends a background job. status is the agent's word for it:
// completed, failed/aborted/error, cancelled (with any suffix).
func (c *conversation) settleJob(id, status string, durationMs int64, changed *[]int) {
	ref, ok := c.jobs[id]
	if !ok {
		return
	}
	var next ToolStatus
	switch {
	case strings.HasPrefix(status, "completed"):
		next = ToolDone
	case strings.HasPrefix(status, "failed"), strings.HasPrefix(status, "aborted"), strings.HasPrefix(status, "error"):
		next = ToolError
	case strings.HasPrefix(status, "cancelled"):
		next = ToolStopped
	default:
		return
	}
	j := &c.items[ref.item].Parts[ref.part].Tool.Jobs[ref.job]
	if j.Status == next && (durationMs == 0 || j.DurationMs == durationMs) {
		return
	}
	c.seq++
	j.Status = next
	if durationMs > 0 {
		j.DurationMs = durationMs
	}
	c.touch(ref.item, changed)
}
