package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

// paneLocks serialises everything that types into a pane. An ask answer is a
// sequence of keys that must not interleave with /keys input (or a second
// answer), so both take the pane's lock and refuse while it is held.
type paneLocks struct {
	mu   sync.Mutex
	held map[string]bool
}

// tryLock takes the pane's lock without waiting; ok is false while another
// request holds it.
func (l *paneLocks) tryLock(pane string) (unlock func(), ok bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.held[pane] {
		return nil, false
	}
	if l.held == nil {
		l.held = map[string]bool{}
	}
	l.held[pane] = true
	return func() {
		l.mu.Lock()
		delete(l.held, pane)
		l.mu.Unlock()
	}, true
}

// askAnswerBody is one answer of POST /p/{pane}/ask.
type askAnswerBody struct {
	ID              string   `json:"id"`
	SelectedOptions []string `json:"selectedOptions"`
	CustomInput     *string  `json:"customInput,omitempty"`
}

type askBody struct {
	ToolID  string          `json:"toolId"`
	Answers []askAnswerBody `json:"answers"`
}

const (
	maxAskBody       = 64 << 10
	maxCustomAnswer  = 4 << 10
	askDriveTimeout  = 90 * time.Second
	askResultTimeout = 15 * time.Second
	askResultPoll    = 150 * time.Millisecond
)

// paneAsk answers a pending omp ask call by driving its terminal dialog. The
// request names the tool call; the call must still be running in the live
// session log, and the dialog on screen must be that call's, or nothing is
// typed. The response waits for omp to log the tool result, so success means
// omp accepted the answers, not just that keys were sent.
func (s *Server) paneAsk(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	if s.chat == nil {
		s.fail(w, http.StatusNotFound, "native chat is disabled")
		return
	}
	var body askBody
	dec := json.NewDecoder(io.LimitReader(r.Body, maxAskBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		s.fail(w, http.StatusBadRequest, "invalid json")
		return
	}
	if body.ToolID == "" {
		s.fail(w, http.StatusBadRequest, "missing toolId")
		return
	}

	unlock, ok := s.input.tryLock(p.ID)
	if !ok {
		s.fail(w, http.StatusConflict, "input is already being sent to this pane; try again")
		return
	}
	defer unlock()

	ctx := r.Context()
	target, err := s.chat.Locate(ctx, p)
	if err != nil {
		s.fail(w, http.StatusConflict, "no agent session found for this pane")
		return
	}
	if target.Kind != transcript.AgentOmp {
		s.fail(w, http.StatusConflict, "native answers are only supported for omp")
		return
	}
	sess, err := transcript.Open(target.Ref)
	if err != nil {
		s.fail(w, http.StatusInternalServerError, "cannot read the session log: "+err.Error())
		return
	}
	pending := &askPending{r: sess, id: body.ToolID, at: -1}
	tool, err := pending.running()
	if err != nil {
		s.fail(w, http.StatusConflict, err.Error())
		return
	}
	form, answers, err := askPlan(tool.Questions, body.Answers)
	if err != nil {
		s.fail(w, http.StatusBadRequest, err.Error())
		return
	}

	driveCtx, cancel := context.WithTimeout(ctx, askDriveTimeout)
	defer cancel()
	check := func(ctx context.Context) error {
		current, err := s.tmux.GetPane(ctx, p.ID)
		if err != nil || current.PID != p.PID || current.Dead || current.InMode {
			return errors.New("the pane changed or entered copy mode; not submitted")
		}
		live, err := s.chat.Locate(ctx, current)
		if err != nil || live != target {
			return errors.New("the pane switched agent sessions; not submitted")
		}
		_, err = pending.running()
		return err
	}
	if err := tmux.DriveAsk(driveCtx, s.tmux.AskTerminal(p.ID), form, answers, check); err != nil {
		s.log.Warn("ask answer refused", "pane", p.ID, "tool", body.ToolID, "err", err)
		s.fail(w, http.StatusConflict, err.Error())
		return
	}

	// The submitting key is sent; omp logs the result when the dialog closes.
	status, err := pending.await(ctx, askResultTimeout)
	switch {
	case err != nil:
		s.log.Warn("ask answer unconfirmed", "pane", p.ID, "tool", body.ToolID, "err", err)
		s.fail(w, http.StatusGatewayTimeout, "answers were sent to the terminal, but omp has not recorded a result yet; check the terminal")
	case status.Status == transcript.ToolDone:
		w.WriteHeader(http.StatusNoContent)
	default:
		msg := strings.TrimSpace(status.Output)
		if msg == "" {
			msg = string(status.Status)
		}
		s.fail(w, http.StatusConflict, "omp recorded the ask as "+string(status.Status)+": "+clipAskMessage(msg))
	}
}

func clipAskMessage(s string) string {
	const max = 300
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

// askPending follows one ask call in a live session log. It re-reads the log
// on every question instead of trusting what the page saw.
type askPending struct {
	r  transcript.Reader
	id string
	at int // item index holding the call, -1 until found
}

var errAskGone = errors.New("this question is no longer pending in omp; reload the chat")

// lookup polls the log and returns the call's current state.
func (a *askPending) lookup() (transcript.Tool, bool, error) {
	if _, err := a.r.Poll(); err != nil {
		if !errors.Is(err, transcript.ErrReset) {
			return transcript.Tool{}, false, err
		}
		a.at = -1
	}
	if a.at >= 0 && a.at < a.r.Len() {
		if t, ok := askToolIn(a.r.Range(a.at, a.at+1), a.id); ok {
			return t, true, nil
		}
	}
	a.at = -1
	// Newest first: a pending ask is near the end.
	const chunk = 64
	for to := a.r.Len(); to > 0; to -= chunk {
		from := max(0, to-chunk)
		items := a.r.Range(from, to)
		for i := len(items) - 1; i >= 0; i-- {
			if t, ok := askToolIn(items[i:i+1], a.id); ok {
				a.at = from + i
				return t, true, nil
			}
		}
	}
	return transcript.Tool{}, false, nil
}

func askToolIn(items []transcript.Item, id string) (transcript.Tool, bool) {
	for _, it := range items {
		for _, part := range it.Parts {
			if part.Kind == transcript.PartTool && part.Tool.ID == id {
				return part.Tool, true
			}
		}
	}
	return transcript.Tool{}, false
}

// running returns the call while it is an ask still waiting for its answer.
func (a *askPending) running() (transcript.Tool, error) {
	t, ok, err := a.lookup()
	if err != nil {
		return transcript.Tool{}, fmt.Errorf("cannot read the session log: %w", err)
	}
	if !ok || t.Name != "ask" || t.Status != transcript.ToolRunning {
		return transcript.Tool{}, errAskGone
	}
	if len(t.Questions) == 0 {
		return transcript.Tool{}, errors.New("this ask has no questions the phone can answer; use the terminal")
	}
	return t, nil
}

// await waits for the call's result to be logged.
func (a *askPending) await(ctx context.Context, timeout time.Duration) (transcript.Tool, error) {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(askResultPoll)
	defer tick.Stop()
	for {
		t, ok, err := a.lookup()
		if err != nil {
			return transcript.Tool{}, err
		}
		if !ok {
			return transcript.Tool{}, errAskGone
		}
		if t.Status != transcript.ToolRunning {
			return t, nil
		}
		select {
		case <-ctx.Done():
			return transcript.Tool{}, ctx.Err()
		case <-deadline.C:
			return transcript.Tool{}, errors.New("timed out waiting for the tool result")
		case <-tick.C:
		}
	}
}

// askPlan validates the submitted answers against the call's questions and
// turns them into the driver's form: one answer per question, in order, with
// option labels resolved to indexes.
func askPlan(questions []transcript.AskQuestion, answers []askAnswerBody) (tmux.AskForm, []tmux.AskAnswer, error) {
	if len(answers) != len(questions) {
		return tmux.AskForm{}, nil, fmt.Errorf("expected %d answers, got %d", len(questions), len(answers))
	}
	form := tmux.AskForm{Questions: make([]tmux.AskFormQuestion, len(questions))}
	out := make([]tmux.AskAnswer, len(questions))
	ids := make(map[string]bool, len(questions))
	for qi, q := range questions {
		if ids[q.ID] {
			return tmux.AskForm{}, nil, fmt.Errorf("question id %q is repeated; answer this ask in the terminal", q.ID)
		}
		ids[q.ID] = true
		a := answers[qi]
		if a.ID != q.ID {
			return tmux.AskForm{}, nil, fmt.Errorf("answer %d is for %q, expected %q", qi+1, a.ID, q.ID)
		}
		labels := make([]string, len(q.Options))
		index := make(map[string]int, len(q.Options))
		for oi, o := range q.Options {
			if _, dup := index[o.Label]; dup {
				return tmux.AskForm{}, nil, fmt.Errorf("question %q repeats option %q; answer it in the terminal", q.ID, o.Label)
			}
			index[o.Label] = oi
			labels[oi] = o.Label
		}
		rec := -1
		if q.Recommended != nil {
			rec = *q.Recommended
		}
		form.Questions[qi] = tmux.AskFormQuestion{ID: q.ID, Header: q.Header, Question: q.Question, Options: labels, Multi: q.Multi, Recommended: rec}

		seen := make(map[int]bool, len(a.SelectedOptions))
		var picked []int
		for _, label := range a.SelectedOptions {
			oi, ok := index[label]
			if !ok {
				return tmux.AskForm{}, nil, fmt.Errorf("question %q has no option %q", q.ID, label)
			}
			if seen[oi] {
				return tmux.AskForm{}, nil, fmt.Errorf("option %q is selected twice for %q", label, q.ID)
			}
			seen[oi] = true
			picked = append(picked, oi)
		}
		ans := tmux.AskAnswer{Selected: picked}
		if a.CustomInput != nil {
			text, err := customAnswer(*a.CustomInput)
			if err != nil {
				return tmux.AskForm{}, nil, fmt.Errorf("question %q: %w", q.ID, err)
			}
			if text != "" {
				ans.Custom, ans.HasCustom = text, true
			}
		}
		if !q.Multi {
			n := len(picked)
			if ans.HasCustom {
				n++
			}
			if n != 1 {
				return tmux.AskForm{}, nil, fmt.Errorf("question %q needs exactly one answer: one option or your own text", q.ID)
			}
		}
		out[qi] = ans
	}
	return form, out, nil
}

// customAnswer normalises typed text for the terminal's custom-answer editor.
// It arrives there as one bracketed paste, so control characters (an escape
// could end the paste early and run keys) are refused, and line endings are
// plain newlines. Whitespace-only text means no custom answer.
func customAnswer(s string) (string, error) {
	if len(s) > maxCustomAnswer {
		return "", errors.New("custom answer is too long")
	}
	if !utf8.ValidString(s) {
		return "", errors.New("custom answer is not valid text")
	}
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.TrimSpace(s)
	for _, r := range s {
		if r == '\n' || r == '\t' {
			continue
		}
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return "", errors.New("custom answer contains control characters")
		}
	}
	if s != "" && looksLikeImagePaths(s) {
		// omp's prompt turns a paste of nothing but image paths into image
		// attachments, which is not the text answer the user typed.
		return "", errors.New("a custom answer made only of image paths cannot be sent from the phone")
	}
	return s, nil
}

func looksLikeImagePaths(s string) bool {
	for _, f := range strings.Fields(s) {
		f = strings.Trim(f, `"'`)
		if !strings.ContainsAny(f, `/\~`) {
			return false
		}
		switch strings.ToLower(path.Ext(f)) {
		case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".avif":
		default:
			return false
		}
	}
	return true
}
