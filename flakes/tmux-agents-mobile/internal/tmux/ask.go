package tmux

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// This file answers omp's ask dialog by typing into the pane. A running omp
// only takes terminal keys, so the driver reads the dialog off the screen
// before every key and waits for the screen to show each key's effect; it
// never replays a fixed key sequence. Anything it cannot recognise stops it
// before a key that could change an answer.
//
// The screen format is omp's AskDialogComponent (pi-tui overlays/ask-dialog.ts):
// a rounded panel titled "Ask" (or "Ask (Ns)" with a countdown) holding a tab
// bar (several questions, or any multi-select), the question or "Review
// answers", a divider, the answer rows, a divider and a key-hint footer. Each
// row is the cursor ("❯ " or two spaces), a radio/checkbox marker and the
// label; the last row is "Other (type your own)", which opens a "Custom
// answer" prompt where Enter submits.
//
// Key semantics it relies on: Up/Down move the cursor and clamp; Space toggles
// a multi-select option; Enter picks a single-select option and moves on (or
// submits a dialog that has only that question), opens the custom prompt on
// Other, and submits on the review tab; Tab cycles the questions and then the
// review tab. Multi-select questions are always left with Tab, since Enter on
// a lone multi-select question submits at once.

// AskTerminal is the pane I/O the ask driver needs.
type AskTerminal interface {
	// Screen returns the visible screen, SGR sequences included: the active
	// tab differs from the others only by its style.
	Screen(ctx context.Context) (string, error)
	SendKeys(ctx context.Context, keys ...string) error
	Paste(ctx context.Context, text string) error
}

type paneTerminal struct {
	c    *Client
	pane string
}

// AskTerminal returns the pane as the ask driver's terminal.
func (c *Client) AskTerminal(pane string) AskTerminal { return paneTerminal{c: c, pane: pane} }

func (t paneTerminal) Screen(ctx context.Context) (string, error) {
	return t.c.Capture(ctx, t.pane, CaptureOpts{Escapes: true})
}

func (t paneTerminal) SendKeys(ctx context.Context, keys ...string) error {
	return t.c.SendKeys(ctx, t.pane, keys...)
}

func (t paneTerminal) Paste(ctx context.Context, text string) error {
	return t.c.Paste(ctx, t.pane, text)
}

// AskForm is the ask call the dialog shows, as the session log recorded it.
type AskForm struct {
	Questions []AskFormQuestion
}

// AskFormQuestion is one question; Options are the raw option labels.
type AskFormQuestion struct {
	ID          string
	Header      string
	Question    string
	Options     []string
	Multi       bool
	Recommended int // index into Options, -1 when none
}

// AskAnswer is the wanted state of one question: option indexes, plus custom
// text when HasCustom.
type AskAnswer struct {
	Selected  []int
	Custom    string
	HasCustom bool
}

// DriveAsk types the answers into the pane's ask dialog and submits it. check
// is called before every key and must fail once the ask is no longer pending.
// It returns after the submitting key; whether omp accepted the answers is
// for the caller to confirm from the session log.
func DriveAsk(ctx context.Context, term AskTerminal, form AskForm, answers []AskAnswer, check func(context.Context) error) error {
	d := &askDriver{term: term, qs: form.Questions, check: check, poll: 40 * time.Millisecond, step: 4 * time.Second}
	return d.run(ctx, answers)
}

const (
	askOtherLabel     = "Other (type your own)"
	askRecommended    = " (Recommended)"
	askReviewHeader   = "Review answers"
	askGuardHint      = "typing edits your prompt"
	askPromptTitle    = "Custom answer:"
	askNotePrompt     = "Note for "
	askTabLabelWidth  = 16
	askNoteMarker     = "✎ note"
	askDetailIndent   = 6
	askTabSpaces      = "   "
	askReservedChat   = "Chat about this"
	askReservedNext   = "Next →"
	askSubmitRowLabel = "Submit"
)

type askDriver struct {
	term    AskTerminal
	qs      []AskFormQuestion
	check   func(context.Context) error
	poll    time.Duration // between screen reads while waiting
	step    time.Duration // how long one key may take to show
	touched bool          // a key that can change an answer was sent
}

// fail builds an error; once answers may have changed it says so, and that
// submitting again starts over from what the screen shows.
func (d *askDriver) fail(format string, args ...any) error {
	msg := "ask dialog: " + fmt.Sprintf(format, args...)
	if d.touched {
		msg += " (the terminal dialog is still open and may hold some of these answers; submitting again re-checks every one)"
	}
	return errors.New(msg)
}

func (d *askDriver) run(ctx context.Context, answers []AskAnswer) error {
	if len(d.qs) == 0 || len(answers) != len(d.qs) {
		return d.fail("expected %d answers, got %d", len(d.qs), len(answers))
	}
	tabs := len(d.qs) > 1
	for qi, q := range d.qs {
		if err := checkAskAnswer(q, answers[qi]); err != nil {
			return d.fail("question %q: %v", q.ID, err)
		}
		tabs = tabs || q.Multi
	}
	if err := d.check(ctx); err != nil {
		return err
	}
	v, err := d.view(ctx)
	if err != nil {
		return err
	}
	if err := d.usable(v); err != nil {
		return err
	}
	if strings.Contains(v.footer, askGuardHint) {
		// A composer draft owns typing until Up or Down hands the keys to
		// the dialog; that key does nothing else.
		if v, err = d.send(ctx, v, "Up", "the dialog to take the keyboard", func(v askView) bool {
			return v.kind == viewAsk && !strings.Contains(v.footer, askGuardHint)
		}); err != nil {
			return err
		}
	}
	if tabs {
		if err := d.verifyTabs(v); err != nil {
			return err
		}
		// Which tab is open is not readable from text alone, so go to the
		// review tab (the one with its own header) and one tab on from there.
		for i := 0; !isReview(v); i++ {
			if i > len(d.qs) {
				return d.fail("could not find the review tab")
			}
			if v, err = d.tab(ctx, v, "the next tab", nil); err != nil {
				return err
			}
		}
		if v, err = d.tab(ctx, v, "the first question", func(v askView) bool { return !isReview(v) }); err != nil {
			return err
		}
	}
	for qi, q := range d.qs {
		if q.Multi {
			v, err = d.multi(ctx, v, qi, answers[qi])
		} else {
			v, err = d.single(ctx, v, qi, answers[qi], tabs)
		}
		if err != nil {
			return err
		}
	}
	if !tabs {
		return nil // a lone single-select question submits on its answer
	}
	return d.review(ctx, v, answers)
}

func checkAskAnswer(q AskFormQuestion, a AskAnswer) error {
	seen := map[int]bool{}
	for _, i := range a.Selected {
		if i < 0 || i >= len(q.Options) || seen[i] {
			return fmt.Errorf("invalid option index %d", i)
		}
		seen[i] = true
	}
	if a.HasCustom && strings.TrimSpace(a.Custom) == "" {
		return errors.New("empty custom answer")
	}
	if !q.Multi {
		n := len(a.Selected)
		if a.HasCustom {
			n++
		}
		if n != 1 {
			return errors.New("needs exactly one answer")
		}
	}
	return nil
}

func (d *askDriver) usable(v askView) error {
	switch v.kind {
	case viewAsk:
		return nil
	case viewHidden:
		return d.fail("the ask dialog is hidden in the terminal; show it there first")
	case viewPrompt:
		return d.fail("a text prompt of the ask dialog is open in the terminal; finish or cancel it there first")
	case viewNote:
		return d.fail("a note prompt of the ask dialog is open in the terminal; finish or cancel it there first")
	case viewOther:
		return d.fail("the terminal shows an ask dialog in a layout this app does not recognise")
	}
	return d.fail("no ask dialog is visible in the terminal")
}

// verifyTabs checks the tab bar names this form's questions, in order.
func (d *askDriver) verifyTabs(v askView) error {
	if len(v.header) < 2 {
		return d.fail("the dialog has no question tabs, but this ask needs them")
	}
	if d.tabRows(v.header) < 0 {
		return d.fail("the dialog's tabs do not match this ask; it may be a different question")
	}
	return nil
}

// tabRows returns how many header rows the tab bar takes (it wraps when the
// chips do not fit), or -1 when the header does not name this form's tabs in
// order.
func (d *askDriver) tabRows(header []string) int {
	for r := 1; r <= len(header); r++ {
		if d.tabsIn(normText(strings.Join(header[:r], " "))) {
			return r
		}
	}
	return -1
}

func (d *askDriver) tabsIn(hay string) bool {
	at := 0
	for i := 0; i <= len(d.qs); i++ {
		want := askSubmitRowLabel
		if i < len(d.qs) {
			want = askTabLabel(d.qs[i], i)
		}
		n := []rune(normText(want))
		if len(n) > 6 {
			n = n[:6]
		}
		j := strings.Index(hay[at:], string(n))
		if j < 0 {
			return false
		}
		at += j + len(string(n))
	}
	return true
}

// single answers a single-select question; it ends on the next tab, or after
// the submitting key when the question is alone (tabs false).
func (d *askDriver) single(ctx context.Context, v askView, qi int, a AskAnswer, tabs bool) (askView, error) {
	q := d.qs[qi]
	target := len(q.Options)
	if !a.HasCustom {
		target = a.Selected[0]
	}
	v, m, err := d.moveTo(ctx, v, q, target)
	if err != nil {
		return v, err
	}
	row := m.cursorRow()
	if row.note {
		return v, d.fail("question %q has a note on this answer in the terminal; answer it there", q.ID)
	}
	if !a.HasCustom {
		if !tabs {
			return v, d.press(ctx, "Enter")
		}
		return d.advance(ctx, v, qi, "Enter")
	}
	if row.checked {
		// A custom answer is already set: the prompt would open with it, and
		// it cannot be cleared reliably by keys.
		if !customShown(row, a.Custom) {
			return v, d.fail("question %q already has a different custom answer in the terminal; change it there", q.ID)
		}
		if tabs {
			return d.advance(ctx, v, qi, "Tab")
		}
		if v, err = d.openPrompt(ctx, v); err != nil {
			return v, err
		}
		if !promptHolds(v, a.Custom) {
			return v, d.fail("the custom-answer prompt open in the terminal does not show the expected text; finish it there")
		}
		return v, d.press(ctx, "Enter")
	}
	if v, err = d.openPrompt(ctx, v); err != nil {
		return v, err
	}
	if v, err = d.paste(ctx, v, a.Custom); err != nil {
		return v, err
	}
	if !tabs {
		return v, d.press(ctx, "Enter")
	}
	return d.advance(ctx, v, qi, "Enter")
}

// multi sets every checkbox of a multi-select question to the wanted state,
// reading each one as the cursor passes it, then the custom answer, and moves
// to the next tab.
func (d *askDriver) multi(ctx context.Context, v askView, qi int, a AskAnswer) (askView, error) {
	q := d.qs[qi]
	want := make(map[int]bool, len(a.Selected))
	for _, i := range a.Selected {
		want[i] = true
	}
	var (
		m   askMatch
		err error
	)
	for r := 0; r < len(q.Options); r++ {
		if v, m, err = d.moveTo(ctx, v, q, r); err != nil {
			return v, err
		}
		row := m.cursorRow()
		if row.note && want[r] {
			return v, d.fail("question %q has a note on %q in the terminal; answer it there", q.ID, q.Options[r])
		}
		if row.checked == want[r] {
			continue
		}
		was := row.checked
		if v, err = d.send(ctx, v, "Space", "the checkbox to toggle", func(v askView) bool {
			mm, err := d.match(v, q)
			return err == nil && mm.cursor == r && mm.cursorRow().checked != was
		}); err != nil {
			return v, err
		}
	}
	if v, m, err = d.moveTo(ctx, v, q, len(q.Options)); err != nil {
		return v, err
	}
	row := m.cursorRow()
	switch {
	case row.note && a.HasCustom:
		return v, d.fail("question %q has a note on its custom answer in the terminal; answer it there", q.ID)
	case row.checked && !a.HasCustom:
		return v, d.fail("question %q has a custom answer in the terminal that this answer drops; clear it there", q.ID)
	case row.checked:
		if !customShown(row, a.Custom) {
			return v, d.fail("question %q already has a different custom answer in the terminal; change it there", q.ID)
		}
		return d.advance(ctx, v, qi, "Tab")
	case a.HasCustom:
		if v, err = d.openPrompt(ctx, v); err != nil {
			return v, err
		}
		if v, err = d.paste(ctx, v, a.Custom); err != nil {
			return v, err
		}
		// A non-empty custom answer moves on by itself (to the review tab
		// when this is the only question).
		return d.advance(ctx, v, qi, "Enter")
	}
	return d.advance(ctx, v, qi, "Tab")
}

// review checks every answer on the review tab, then submits.
func (d *askDriver) review(ctx context.Context, v askView, answers []AskAnswer) error {
	if !isReview(v) {
		return d.fail("expected the review tab")
	}
	got := map[int]string{}
	for step := 0; ; step++ {
		for _, l := range v.body {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(t, "Note:") {
				return d.fail("the terminal dialog has a note attached to an answer; submit it there")
			}
			if sm := reviewLineRE.FindStringSubmatch(t); sm != nil {
				n, _ := strconv.Atoi(sm[1])
				got[n] = t
			}
		}
		if reviewSubmitVisible(v) {
			break
		}
		if step > 4*len(d.qs)+8 {
			return d.fail("could not scroll the review tab to its end")
		}
		var err error
		before := v.bodyKey
		if v, err = d.send(ctx, v, "Down", "the review to scroll", func(v askView) bool {
			return isReview(v) && v.bodyKey != before
		}); err != nil {
			return err
		}
	}
	for qi, q := range d.qs {
		line, ok := got[qi+1]
		want := fmt.Sprintf("%d. %s: %s", qi+1, askTabLabel(q, qi), askSummary(q, answers[qi]))
		if !ok || !reviewMatches(line, want) {
			return d.fail("the review tab shows %q, expected %q; not submitted", line, want)
		}
	}
	return d.press(ctx, "Enter")
}

// moveTo moves the cursor to row target of question q, one key at a time,
// confirming each move on screen.
func (d *askDriver) moveTo(ctx context.Context, v askView, q AskFormQuestion, target int) (askView, askMatch, error) {
	m, err := d.match(v, q)
	if err != nil {
		return v, m, err
	}
	for steps := 0; m.cursor != target; steps++ {
		if steps > len(q.Options)+2 {
			return v, m, d.fail("could not move to the answer row")
		}
		key, next := "Down", m.cursor+1
		if m.cursor > target {
			key, next = "Up", m.cursor-1
		}
		before := v.bodyKey
		if v, err = d.send(ctx, v, key, "the cursor to move", func(v askView) bool {
			if v.bodyKey == before {
				return false
			}
			mm, err := d.match(v, q)
			if err != nil || mm.cursor != next {
				return false
			}
			m = mm
			return true
		}); err != nil {
			return v, m, err
		}
	}
	return v, m, nil
}

// advance sends key, which leaves question qi, and waits for the next tab.
func (d *askDriver) advance(ctx context.Context, v askView, qi int, key string) (askView, error) {
	toReview := qi == len(d.qs)-1
	what := "the next question"
	if toReview {
		what = "the review tab"
	}
	return d.tab(ctx, v, what, func(v askView) bool { return isReview(v) == toReview }, key)
}

// tab sends Tab (or keys) and waits until the header shows another tab and ok
// holds.
func (d *askDriver) tab(ctx context.Context, v askView, what string, ok func(askView) bool, keys ...string) (askView, error) {
	key := "Tab"
	if len(keys) > 0 {
		key = keys[0]
	}
	before := v.headerRaw
	return d.send(ctx, v, key, what, func(v askView) bool {
		return v.kind == viewAsk && v.headerRaw != before && (ok == nil || ok(v))
	})
}

func (d *askDriver) openPrompt(ctx context.Context, v askView) (askView, error) {
	return d.send(ctx, v, "Enter", "the custom-answer prompt", func(v askView) bool {
		return v.kind == viewPrompt
	})
}

func (d *askDriver) paste(ctx context.Context, v askView, text string) (askView, error) {
	if err := d.check(ctx); err != nil {
		return v, err
	}
	before := v.bodyKey
	d.touched = true
	if err := d.term.Paste(ctx, text); err != nil {
		return v, d.fail("paste: %v", err)
	}
	return d.await(ctx, "the custom answer to appear", func(v askView) bool {
		return v.kind == viewPrompt && v.bodyKey != before && promptHolds(v, text)
	})
}

// send presses key and waits for ok.
func (d *askDriver) send(ctx context.Context, v askView, key, what string, ok func(askView) bool) (askView, error) {
	if err := d.press(ctx, key); err != nil {
		return v, err
	}
	return d.await(ctx, what, ok)
}

// press sends one key after confirming the ask is still pending.
func (d *askDriver) press(ctx context.Context, key string) error {
	if err := d.check(ctx); err != nil {
		if d.touched {
			return d.fail("%v", err)
		}
		return err
	}
	if key == "Space" || key == "Enter" {
		d.touched = true
	}
	if err := d.term.SendKeys(ctx, key); err != nil {
		return d.fail("send %s: %v", key, err)
	}
	return nil
}

func (d *askDriver) view(ctx context.Context) (askView, error) {
	s, err := d.term.Screen(ctx)
	if err != nil {
		return askView{}, d.fail("read screen: %v", err)
	}
	return parseAskScreen(s), nil
}

func (d *askDriver) await(ctx context.Context, what string, ok func(askView) bool) (askView, error) {
	deadline := time.Now().Add(d.step)
	for {
		v, err := d.view(ctx)
		if err != nil {
			return v, err
		}
		if ok(v) {
			return v, nil
		}
		if !time.Now().Before(deadline) {
			return v, d.fail("timed out waiting for %s; the terminal shows %s", what, v.describe())
		}
		select {
		case <-ctx.Done():
			return v, d.fail("%v while waiting for %s", ctx.Err(), what)
		case <-time.After(d.poll):
		}
	}
}

// askMatch is a question view resolved against the form: the visible rows
// and the absolute index of the first one and of the cursor.
type askMatch struct {
	rows   []askRow
	first  int
	cursor int
}

func (m askMatch) cursorRow() askRow { return m.rows[m.cursor-m.first] }

// match resolves the view as question q.
func (d *askDriver) match(v askView, q AskFormQuestion) (askMatch, error) {
	if v.kind != viewAsk {
		return askMatch{}, d.fail("the ask dialog is not showing a question")
	}
	if isReview(v) {
		return askMatch{}, d.fail("the ask dialog shows the review tab, expected question %q", q.ID)
	}
	if q.Question != "" {
		start := 0
		if len(d.qs) > 1 || q.Multi {
			start = d.tabRows(v.header)
		}
		if start < 0 || !questionShown(v.header[start:], q.Question) {
			return askMatch{}, d.fail("cannot confirm the terminal shows question %q; not submitted", q.ID)
		}
	}
	rows := parseAskRows(v.body)
	if len(rows) == 0 {
		return askMatch{}, d.fail("no answer rows on screen for question %q", q.ID)
	}
	cursor := -1
	for i, r := range rows {
		if r.multi != q.Multi {
			return askMatch{}, d.fail("the dialog shows a different kind of question than %q", q.ID)
		}
		if r.cursor {
			if cursor >= 0 {
				return askMatch{}, d.fail("two highlighted rows on screen")
			}
			cursor = i
		}
	}
	if cursor < 0 {
		return askMatch{}, d.fail("no highlighted row on screen for question %q", q.ID)
	}
	want := append(askDisplayLabels(q), askOtherLabel)
	first := -1
	for o := 0; o+len(rows) <= len(want); o++ {
		fits := true
		for i, r := range rows {
			if !r.matches(want[o+i]) {
				fits = false
				break
			}
		}
		if fits {
			if first >= 0 {
				return askMatch{}, d.fail("cannot tell the answer rows of question %q apart", q.ID)
			}
			first = o
		}
	}
	if first < 0 {
		return askMatch{}, d.fail("the rows on screen are not the options of question %q", q.ID)
	}
	return askMatch{rows: rows, first: first, cursor: first + cursor}, nil
}

// ---- screen parsing ----

type askViewKind int

const (
	viewNone askViewKind = iota
	viewAsk
	viewPrompt
	viewNote
	viewHidden
	viewOther
)

// askView is the ask dialog (or its prompt) as read off the screen. Lines are
// panel contents without borders or SGR; headerRaw keeps the header's SGR,
// which is where the active tab shows.
type askView struct {
	kind      askViewKind
	title     string
	header    []string
	headerRaw string
	body      []string
	bodyKey   string
	footer    string
}

func (v askView) describe() string {
	switch v.kind {
	case viewAsk:
		h := ""
		if len(v.header) > 0 {
			h = v.header[len(v.header)-1]
		}
		return fmt.Sprintf("the ask dialog at %q", h)
	case viewPrompt, viewNote:
		return fmt.Sprintf("the prompt %q", v.title)
	case viewHidden:
		return "the ask dialog hidden"
	case viewOther:
		return "an unrecognised ask dialog"
	}
	return "no ask dialog"
}

var (
	escapeRE      = regexp.MustCompile(`\x1b\[[0-9;:?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]`)
	panelTopRE    = regexp.MustCompile(`^[╭+][─-] (.*?) ?[─-]*[╮+]$`)
	panelRuleRE   = regexp.MustCompile(`^[├╰+][─-]+[┤╯+]$`)
	askTitleRE    = regexp.MustCompile(`^Ask(?: \(\d+s\))?$`)
	askHiddenRE   = regexp.MustCompile(`^Ask(?: \(\d+s\))? hidden:`)
	reviewLineRE  = regexp.MustCompile(`^(\d+)\. `)
	pasteMarkerRE = regexp.MustCompile(`\[Paste #\d+, (\+\d+ lines|\d+ chars)\]`)
)

func stripEscapes(s string) string { return escapeRE.ReplaceAllString(s, "") }

// parseAskScreen finds the bottom-most ask panel, custom-answer prompt or
// hidden-dialog line on the screen.
func parseAskScreen(screen string) askView {
	raw := strings.Split(strings.TrimRight(screen, "\n"), "\n")
	plain := make([]string, len(raw))
	top, hidden := -1, -1
	var title string
	for i, l := range raw {
		plain[i] = strings.TrimSpace(stripEscapes(l))
		if askHiddenRE.MatchString(plain[i]) {
			hidden = i
			continue
		}
		if m := panelTopRE.FindStringSubmatch(plain[i]); m != nil {
			t := strings.TrimSpace(m[1])
			if askTitleRE.MatchString(t) || strings.HasPrefix(t, askPromptTitle) || strings.HasPrefix(t, askNotePrompt) {
				top, title = i, t
			}
		}
	}
	if hidden > top {
		return askView{kind: viewHidden}
	}
	if top < 0 {
		return askView{}
	}
	if !askTitleRE.MatchString(title) {
		kind := viewPrompt
		if strings.HasPrefix(title, askNotePrompt) {
			kind = viewNote
		}
		var body []string
		for _, l := range plain[top+1:] {
			if panelRuleRE.MatchString(l) {
				return askView{kind: kind, title: title, body: body, bodyKey: strings.Join(body, "\n")}
			}
			c, ok := panelRow(l)
			if !ok {
				break
			}
			body = append(body, c)
		}
		return askView{kind: viewOther, title: title}
	}
	v := askView{kind: viewAsk, title: title}
	var headerRaw []string
	section := 0 // header, body, footer
	for i := top + 1; i < len(plain); i++ {
		l := plain[i]
		if panelRuleRE.MatchString(l) {
			section++
			if section == 3 {
				break
			}
			continue
		}
		c, ok := panelRow(l)
		if !ok {
			return askView{kind: viewOther, title: title}
		}
		switch section {
		case 0:
			v.header = append(v.header, c)
			headerRaw = append(headerRaw, raw[i])
		case 1:
			v.body = append(v.body, c)
		default:
			if v.footer != "" {
				return askView{kind: viewOther, title: title}
			}
			v.footer = c
		}
	}
	if section != 3 || len(v.header) == 0 || len(v.body) == 0 || !strings.Contains(v.footer, "cancel") {
		return askView{kind: viewOther, title: title}
	}
	stripScrollbar(v.body)
	v.headerRaw = strings.Join(headerRaw, "\n")
	v.bodyKey = strings.Join(v.body, "\n")
	return v
}

// panelRow returns the content of a "│ … │" panel row.
func panelRow(l string) (string, bool) {
	for _, bar := range []string{"│", "|"} {
		if len(l) >= 2*len(bar) && strings.HasPrefix(l, bar) && strings.HasSuffix(l, bar) {
			c := l[len(bar) : len(l)-len(bar)]
			return strings.TrimRight(strings.TrimPrefix(c, " "), " "), true
		}
	}
	return "", false
}

// stripScrollbar drops the scroll bar column the answer list grows when its
// rows overflow: every line then ends in a track or thumb glyph.
func stripScrollbar(body []string) {
	for _, l := range body {
		if !strings.HasSuffix(l, "│") && !strings.HasSuffix(l, "█") {
			return
		}
	}
	for i, l := range body {
		_, n := utf8.DecodeLastRuneInString(l)
		body[i] = strings.TrimRight(l[:len(l)-n], " ")
	}
}

func isReview(v askView) bool {
	return v.kind == viewAsk && len(v.header) > 0 && v.header[len(v.header)-1] == askReviewHeader && reviewSubmitPresent(v)
}

// reviewSubmitPresent reports whether the review tab's footer says Enter
// submits; the Submit row itself may be scrolled out of view.
func reviewSubmitPresent(v askView) bool {
	return strings.Contains(v.footer, "submit")
}

func reviewSubmitVisible(v askView) bool {
	for _, l := range v.body {
		for _, c := range askCursors {
			if l == c+" "+askSubmitRowLabel {
				return true
			}
		}
	}
	return false
}

// Glyphs of omp's unicode, nerd-font and ASCII symbol presets.
var askCursors = []string{"❯", "\uf054", ">"}

type askMarker struct {
	glyph          string
	multi, checked bool
}

var askMarkers = []askMarker{
	{"☑", true, true}, {"☐", true, false}, {"◉", false, true}, {"○", false, false},
	{"\uf14a", true, true}, {"\uf096", true, false}, {"\uf192", false, true}, {"\uf10c", false, false},
	{"[x]", true, true}, {"[ ]", true, false}, {"(o)", false, true}, {"( )", false, false},
}

// askRow is one answer row as rendered.
type askRow struct {
	cursor, multi, checked, note bool
	label                        string
	detail                       []string // description, preview or custom-answer lines
	partial                      bool     // the label may continue past what was read
}

// matches reports whether the row shows display label want.
func (r askRow) matches(want string) bool {
	got, w := normText(r.label), normText(want)
	if got == w {
		return true
	}
	return r.partial && got != "" && strings.HasPrefix(w, got)
}

func parseAskRows(body []string) []askRow {
	var rows []askRow
	indent := 0
	inLabel := false
	for i, l := range body {
		if r, ind, ok := parseAskRowStart(l); ok {
			// The ASCII marker's label indent equals the description indent,
			// so a wrapped label cannot be told from a description there.
			r.partial = ind == askDetailIndent
			rows = append(rows, r)
			indent, inLabel = ind, true
		} else if len(rows) > 0 {
			r := &rows[len(rows)-1]
			if inLabel && indent != askDetailIndent && len(l) > indent && strings.Count(l[:indent], " ") == indent && l[indent] != ' ' {
				r.label += " " + strings.TrimSpace(l[indent:])
				r.note, r.label = trimNote(r.label, r.note)
			} else {
				inLabel = false
				if t := strings.TrimSpace(l); t != "" {
					r.detail = append(r.detail, t)
				}
			}
		} else {
			continue
		}
		if i == len(body)-1 && l != "" {
			rows[len(rows)-1].partial = true // cut off by the scroll window
		}
	}
	return rows
}

func parseAskRowStart(l string) (askRow, int, bool) {
	var r askRow
	rest, ok := strings.CutPrefix(l, "  ")
	if !ok {
		for _, c := range askCursors {
			if after, found := strings.CutPrefix(l, c+" "); found {
				rest, r.cursor, ok = after, true, true
				break
			}
		}
		if !ok {
			return r, 0, false
		}
	}
	for _, m := range askMarkers {
		if after, found := strings.CutPrefix(rest, m.glyph+" "); found {
			r.multi, r.checked = m.multi, m.checked
			r.note, r.label = trimNote(after, false)
			return r, 2 + cellWidth(m.glyph) + 1, true
		}
	}
	return r, 0, false
}

func trimNote(label string, note bool) (bool, string) {
	if t, found := strings.CutSuffix(label, askNoteMarker); found {
		return true, strings.TrimRight(t, " ")
	}
	return note, label
}

// customShown reports whether the Other row's preview shows exactly text.
func customShown(r askRow, text string) bool {
	if len(r.detail) == 0 {
		return false
	}
	shown := strings.Join(r.detail, " ")
	return !strings.HasSuffix(shown, "…") && normText(shown) == normText(text)
}

// promptHolds reports whether the prompt shows the start or the end of text
// (a long answer scrolls inside the editor).
func promptHolds(v askView, text string) bool {
	hay := normText(strings.Join(v.body, ""))
	// omp collapses large pastes into a marker but expands their stored text
	// on submit. Match its exact line/UTF-16 count instead of visible text.
	lines, chars := strings.Count(text, "\n")+1, 0
	for _, r := range strings.ReplaceAll(text, "\t", "   ") {
		chars++
		if r > 0xffff {
			chars++
		}
	}
	if lines > 10 || chars > 1000 {
		want := fmt.Sprintf("%d chars", chars)
		if lines > 10 {
			want = fmt.Sprintf("+%d lines", lines)
		}
		for _, line := range v.body {
			for _, marker := range pasteMarkerRE.FindAllStringSubmatch(line, -1) {
				if marker[1] == want {
					return true
				}
			}
		}
	}
	t := []rune(normText(text))
	if len(t) == 0 {
		return false
	}
	n := min(len(t), 16)
	return strings.Contains(hay, string(t[:n])) || strings.Contains(hay, string(t[len(t)-n:]))
}

func reviewMatches(line, want string) bool {
	got, w := normText(line), normText(want)
	if got == w {
		return true
	}
	// A line wider than the dialog is cut with an ellipsis.
	return strings.HasSuffix(line, "…") && got != "" && strings.HasPrefix(w, got)
}

var (
	mdLinkTargetRE = regexp.MustCompile(`\]\([^)]*\)`)
	mdFenceInfoRE  = regexp.MustCompile("(?m)^\\s*(```|~~~)[^\\n]*$")
)

// questionShown reports whether the question rows equal the source question.
// Markdown changes punctuation, so only letters and digits must match; an
// ellipsis permits a prefix. omp prints link targets as "text (url)" but drops
// fence info lines; link targets and fence info are each optional, so every
// combination is accepted.
func questionShown(rows []string, question string) bool {
	raw := strings.Join(rows, " ")
	shown := questionText(raw)
	if shown == "" {
		return false
	}
	noFence := mdFenceInfoRE.ReplaceAllString(question, "")
	for _, src := range []string{
		question,
		noFence,
		mdLinkTargetRE.ReplaceAllString(question, "]"),
		mdLinkTargetRE.ReplaceAllString(noFence, "]"),
	} {
		want := questionText(src)
		if want != "" && (shown == want || (strings.Contains(raw, "…") && strings.HasPrefix(want, shown))) {
			return true
		}
	}
	return false
}

func questionText(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// normText drops whitespace, inline markdown markers and ellipses, so rendered
// and source text compare equal however they were wrapped or styled.
func normText(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsSpace(r) || strings.ContainsRune("*_`~…", r) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// ---- omp's labels ----

var askCRRun = regexp.MustCompile(`\r+`)

func sanitizeCR(s string) string {
	if !strings.Contains(s, "\r") {
		return s
	}
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return askCRRun.ReplaceAllString(s, " ")
}

// askDisplayLabels mirrors displayOptionLabels: the recommendation badge, then
// numeric suffixes for labels that collide with each other or a reserved row.
func askDisplayLabels(q AskFormQuestion) []string {
	taken := map[string]bool{askOtherLabel: true, askReservedChat: true, askReservedNext: true}
	out := make([]string, len(q.Options))
	for i, l := range q.Options {
		base := sanitizeCR(l)
		if q.Recommended == i && !strings.HasSuffix(base, askRecommended) {
			base += askRecommended
		}
		c := base
		for n := 2; taken[c]; n++ {
			c = fmt.Sprintf("%s (%d)", base, n)
		}
		taken[c] = true
		out[i] = c
	}
	return out
}

// askTabLabel mirrors questionTabLabel: header, else id, else Qn, cut to 16
// columns.
func askTabLabel(q AskFormQuestion, i int) string {
	name := strings.TrimSpace(q.Header)
	if name == "" {
		name = sanitizeCR(q.ID)
	}
	if name == "" {
		name = fmt.Sprintf("Q%d", i+1)
	}
	name = strings.ReplaceAll(name, "\t", askTabSpaces)
	return truncateCells(name, askTabLabelWidth)
}

// askSummary mirrors renderAnswerSummary, the review tab's answer text.
func askSummary(q AskFormQuestion, a AskAnswer) string {
	labels := askDisplayLabels(q)
	picked := make(map[int]bool, len(a.Selected))
	for _, i := range a.Selected {
		picked[i] = true
	}
	var parts []string
	for i := range q.Options {
		if picked[i] {
			parts = append(parts, labels[i])
		}
	}
	custom := strings.Join(strings.Fields(strings.ReplaceAll(a.Custom, "\t", askTabSpaces)), " ")
	if q.Multi {
		if a.HasCustom {
			parts = append(parts, "Other: “"+custom+"”")
		}
		if len(parts) == 0 {
			return "unanswered"
		}
		return strings.Join(parts, ", ")
	}
	if a.HasCustom {
		return "“" + custom + "”"
	}
	if len(parts) == 0 {
		return "unanswered"
	}
	return parts[0]
}

func truncateCells(s string, width int) string {
	w := 0
	for _, r := range s {
		w += cellWidth(string(r))
	}
	if w <= width {
		return s
	}
	var b strings.Builder
	w = 0
	for _, r := range s {
		cw := cellWidth(string(r))
		if w+cw > width-1 {
			break
		}
		b.WriteRune(r)
		w += cw
	}
	return b.String() + "…"
}

// cellWidth approximates the terminal width of s: wide East Asian and emoji
// runes take two columns.
func cellWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115f, r >= 0x2e80 && r <= 0xa4cf, r >= 0xac00 && r <= 0xd7a3,
			r >= 0xf900 && r <= 0xfaff, r >= 0xfe30 && r <= 0xfe4f, r >= 0xff00 && r <= 0xff60,
			r >= 0xffe0 && r <= 0xffe6, r >= 0x1f300 && r <= 0x1faff, r >= 0x20000 && r <= 0x3fffd:
			w += 2
		default:
			w++
		}
	}
	return w
}
