package tmux

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Captured shape from omp 18.13.3 AskDialogComponent, unicode preset.
const singleAskScreen = `╭─ Ask ──────────────────────────────────╮
│ Database?                              │
├────────────────────────────────────────┤
│ ❯ ○ SQLite                             │
│   ○ Postgres                           │
│   ○ Other (type your own)              │
├────────────────────────────────────────┤
│ ⏎ select · n note · ↑/↓ move · ⎋ cancel │
╰────────────────────────────────────────╯`

type readOnlyAskScreen struct {
	screen string
	writes int
}

func (s *readOnlyAskScreen) Screen(context.Context) (string, error)    { return s.screen, nil }
func (s *readOnlyAskScreen) SendKeys(context.Context, ...string) error { s.writes++; return nil }
func (s *readOnlyAskScreen) Paste(context.Context, string) error       { s.writes++; return nil }

func TestAskRefusesDifferentQuestionBeforeTyping(t *testing.T) {
	term := &readOnlyAskScreen{screen: singleAskScreen}
	form := AskForm{Questions: []AskFormQuestion{{ID: "q", Question: "Delete database?", Options: []string{"SQLite", "Postgres"}, Recommended: -1}}}
	err := DriveAsk(context.Background(), term, form, []AskAnswer{{Selected: []int{0}}}, func(context.Context) error { return nil })
	if err == nil || term.writes != 0 {
		t.Fatalf("different question accepted: error=%v writes=%d", err, term.writes)
	}
}

func TestAskDoesNotSubmitAfterCallSettles(t *testing.T) {
	term := &readOnlyAskScreen{screen: singleAskScreen}
	form := AskForm{Questions: []AskFormQuestion{{ID: "q", Question: "Database?", Options: []string{"SQLite", "Postgres"}, Recommended: -1}}}
	calls := 0
	gone := errors.New("call settled")
	err := DriveAsk(context.Background(), term, form, []AskAnswer{{Selected: []int{0}}}, func(context.Context) error {
		calls++
		if calls > 1 {
			return gone
		}
		return nil
	})
	if !errors.Is(err, gone) || term.writes != 0 {
		t.Fatalf("stale answer typed: error=%v writes=%d", err, term.writes)
	}
}

func TestAskRecognisesExpandedPasteSizes(t *testing.T) {
	long := strings.Repeat("x", 1001)
	lines := strings.TrimSuffix(strings.Repeat("line\n", 12), "\n")
	if !promptHolds(askView{body: []string{"> [Paste #1, 1001 chars]"}}, long) || !promptHolds(askView{body: []string{"> [Paste #2, +12 lines]"}}, lines) {
		t.Fatal("large paste marker was not recognised")
	}
	if promptHolds(askView{body: []string{"> [Paste #1, 1002 chars]"}}, long) {
		t.Fatal("different paste size accepted")
	}
}

func TestAskQuestionAfterWrappedTabsAndMarkdown(t *testing.T) {
	var qs []AskFormQuestion
	for i := range 7 {
		qs = append(qs, AskFormQuestion{ID: fmt.Sprintf("q%d", i), Header: fmt.Sprintf("Long header %02d", i)})
	}
	d := &askDriver{qs: qs}
	// Real omp 18.13.3 header at 120 columns: tabs wrap onto two rows.
	header := []string{
		"Long header 00    Long header 01    Long header 02    Long header 03    Long header 04    Long header 05",
		"Long header 06    Submit",
		"Use docs (https://example.com/v0) and cfg_0?",
	}
	start := d.tabRows(header)
	if start != 2 {
		t.Fatalf("tab rows = %d, want 2", start)
	}
	if !questionShown(header[start:], "Use **[docs](https://example.com/v0)** and `cfg_0`?") {
		t.Fatal("rendered markdown question was refused")
	}
	// omp keeps the link target but drops the fence info line.
	mixed := "See [docs](https://e.io):\n\n```go\nx := 1\n```"
	if !questionShown([]string{"See docs (https://e.io):", "x := 1"}, mixed) {
		t.Fatal("question with link and fenced code was refused")
	}
	if questionShown([]string{"See docs (https://e.io):", "x := 2"}, mixed) {
		t.Fatal("different code was accepted")
	}
	if questionShown([]string{"and cfg_0?"}, "Use docs and cfg_0?") {
		t.Fatal("a suffix of the question was accepted")
	}
}
