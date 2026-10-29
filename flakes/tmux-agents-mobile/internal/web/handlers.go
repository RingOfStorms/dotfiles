package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/agents"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/frame"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
)

// Card is one clickable leaf of the navigator tree, flattened. A session with
// agent panes yields one card per pane; a session with no agent panes yields a
// single card pointing at its active pane, so shell-only worktrees stay
// reachable. Repo and session are context on the card, not rows of their own.
type Card struct {
	Href string

	Repo    string // repo basename, or the worktree path for a non-git session
	Path    string // ~-shortened directory (the pane's cwd when there is one)
	Session string
	Label   string // session AI label
	Branch  string

	Glyph  string // pane state, in the tmux status line's own glyph
	Class  string
	Pane   string // pane label, empty for a shell-only session
	Agent  string
	Window string // "2:tmux-agent-mobile"

	Text string // search haystack
}

// InboxPage is the home screen: one flat card per leaf, plus a filter box.
type InboxPage struct {
	Base
	Cards    []Card
	Total    int
	NoServer bool
	ErrText  string
}

func (s *Server) inbox(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	page := InboxPage{Base: s.base("", "inbox")}
	// The page polls GET /?fragment=cards and swaps the result in place.
	fragment := r.URL.Query().Get("fragment") == "cards"

	if fragment {
		// A stale page (no tmux, expired session, ...) must not be pasted into
		// the card list; the client only swaps responses that say "cards".
		w.Header().Set("X-Fragment", "error")
	}

	// One call to the plugin: it owns the grouping logic, so the phone and the
	// desktop navigator can never disagree about which worktree a session is in.
	rows, err := s.agentRows(ctx)
	if err != nil {
		if fragment {
			s.fail(w, http.StatusServiceUnavailable, "tmux unavailable")
			return
		}
		if errors.Is(err, tmux.ErrNoServer) {
			page.NoServer = true
		} else {
			page.ErrText = err.Error()
		}
		s.render(w, "inbox.html", page)
		return
	}
	page.Cards = s.cards(rows)
	page.Total = len(page.Cards)

	if fragment {
		w.Header().Set("X-Fragment", "cards")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := s.tpl.ExecuteTemplate(w, "cards", page); err != nil {
			s.log.Error("template", "name", "cards", "err", err)
		}
		return
	}
	s.render(w, "inbox.html", page)
}

// cards flattens the ordered tree (repo, session, panes of that session) into
// one card per leaf, carrying the enclosing repo/session as context.
func (s *Server) cards(rows []agents.Row) []Card {
	var cards []Card
	var session Card
	agents := 0

	flush := func() {
		// A session with no agent panes is itself the leaf.
		if session.Session != "" && agents == 0 {
			cards = append(cards, session)
		}
		session, agents = Card{}, 0
	}

	for _, row := range rows {
		switch row.Kind {
		case "repo":
			flush()
		case "session":
			flush()
			session = Card{
				Session: row.Session,
				Label:   row.Label,
				Branch:  row.Branch,
				Href:    "/p/" + Slug(row.Pane),
				Path:    tildeHome(row.Path),
			}
			if row.Repo != "" {
				session.Repo = shortRepo(row.Repo)
			} else {
				// Non-git session: the navigator shows its path instead of a
				// repo name, so the card does too.
				session.Repo = tildeHome(row.Path)
			}
			session.Text = row.Session + " " + row.Label + " " + row.Branch + " " + row.Path
		case "pane":
			agents++
			card := session
			card.Href = "/p/" + Slug(row.Pane)
			card.Path = tildeHome(row.Path)
			card.Pane = row.Label
			if card.Pane == "" {
				card.Pane = row.Agent
			}
			card.Agent = row.Agent
			if row.Window != "" {
				card.Window = row.Window
				if row.WindowName != "" {
					card.Window += ":" + row.WindowName
				}
			}
			card.Glyph, card.Class = stateGlyph(row.State, row.Unseen.Bool())
			card.Text += " " + row.Label + " " + row.Agent + " " + row.Window + " " + row.WindowName + " " + row.Path
			cards = append(cards, card)
		}
	}
	flush()
	return cards
}

// agentRows reads the plugin tree, falling back to plain tmux detection when the
// plugin is not installed.
func (s *Server) agentRows(ctx context.Context) ([]agents.Row, error) {
	rows := s.agents.Rows(ctx)
	if len(rows) > 0 {
		return rows, nil
	}
	if _, err := s.tmux.ListPanes(ctx); err != nil {
		return nil, err
	}
	return rows, nil
}

func shortRepo(root string) string {
	if root == "" {
		return ""
	}
	parts := strings.Split(strings.TrimRight(root, "/"), "/")
	if len(parts) >= 2 && parts[len(parts)-2] == "git_worktrees" {
		return parts[len(parts)-1]
	}
	base := parts[len(parts)-1]
	if i := strings.IndexByte(base, '_'); i > 0 && len(parts) >= 2 && strings.Contains(parts[len(parts)-2], "git_worktrees") {
		base = base[:i]
	}
	return base
}

func tildeHome(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == home {
		return "~"
	}
	if strings.HasPrefix(path, home+"/") {
		return "~" + path[len(home):]
	}
	return path
}

// PanePage is the single-pane viewer.
type PanePage struct {
	Base
	Slug    string
	Pane    tmux.Pane
	Target  string
	Agent   string
	Label   string
	State   string
	Repo    string
	Branch  string
	Fit     bool
	Frame   template.HTML
	Watched bool
}

func (s *Server) panePage(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	slug := Slug(p.ID)
	page := PanePage{
		Base:   s.subBase("pane", "pane", "/", "pane "+p.ID, ""),
		Slug:   slug,
		Pane:   p,
		Target: fmt.Sprintf("%s:%d", p.Session, p.WindowIndex),
		Fit:    r.URL.Query().Get("fit") == "1",
		State:  p.AgentState,
		Label:  p.PaneName,
	}
	if kind, label := agents.Detect(p.Title, p.Command); kind != "" {
		page.Agent = kind
		if page.Label == "" {
			page.Label = label
		}
	}
	for _, row := range s.agents.Rows(ctx) {
		if row.Pane == p.ID {
			page.Repo, page.Branch = row.Repo, row.Branch
			if row.Agent != "" {
				page.Agent = row.Agent
			}
			if row.Label != "" {
				page.Label = row.Label
			}
			if row.State != "" {
				page.State = row.State
			}
			break
		}
	}
	if repo, err := s.git.Find(ctx, p.Path); err == nil {
		page.Repo, page.Branch = repo.Root, repo.Branch
	}
	if raw, err := s.tmux.Capture(ctx, p.ID, tmux.CaptureOpts{Escapes: true, Join: !page.Fit, PreserveTrailing: page.Fit}); err == nil {
		page.Frame = frameHTML(frame.Render(raw, !page.Fit))
	}
	// Header: back to the inbox, the agent's own label, and the pane's state
	// glyph, exactly as the tmux status line renders it.
	title := page.Label
	if title == "" {
		title = page.Agent
	}
	if title == "" {
		title = p.ID
	}
	parts := make([]string, 0, 3)
	if page.Repo != "" {
		parts = append(parts, shortRepo(page.Repo))
	}
	if page.Branch != "" {
		parts = append(parts, page.Branch)
	}
	parts = append(parts, page.Target)
	sub := strings.Join(parts, " · ")
	page.Title = title
	page.Context = title
	page.Sub = sub
	page.Glyph, page.GlyphClass = stateGlyph(page.State, p.AgentUnseen)
	page.Actions = paneActions(slug, page.Fit)
	page.Watched = time.Unix(p.AgentWatchUnix, 0).After(time.Now())
	s.render(w, "pane.html", page)
}

// paneEvents streams frame updates. One watcher per pane, shared by every phone
// looking at it; nothing is captured while nobody is watching.
func (s *Server) paneEvents(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	fit := r.URL.Query().Get("fit") == "1"

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	rc := http.NewResponseController(w)
	flush := func() { _ = rc.Flush() }
	_, _ = io.WriteString(w, "retry: 2000\n\n")
	flush()

	events, cancel := s.hub.Subscribe(p.ID, fit)
	defer cancel()

	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, open := <-events:
			if !open {
				return
			}
			_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", ev.Name, ev.Data)
			flush()
			if ev.Name == "gone" {
				return
			}
		case <-ping.C:
			_, _ = io.WriteString(w, ": ping\n\n")
			flush()
		}
	}
}

func (s *Server) paneHistory(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	lines := atoiOr(r.URL.Query().Get("lines"), 500)
	if lines < 50 {
		lines = 50
	}
	if lines > 5000 {
		lines = 5000
	}
	raw, err := s.tmux.Capture(r.Context(), p.ID, tmux.CaptureOpts{
		Escapes: true, Join: true, Start: -lines, StartSet: true, End: -1, EndSet: true,
	})
	if err != nil {
		s.fail(w, http.StatusGone, err.Error())
		return
	}
	slug := Slug(p.ID)
	base := s.subBase("history", "history", "/p/"+slug, "history", p.Session+":"+fmt.Sprint(p.WindowIndex))
	base.Actions = []Action{
		{Label: "1000 lines", Href: "/p/" + slug + "/history?lines=1000"},
		{Label: "5000 lines", Href: "/p/" + slug + "/history?lines=5000"},
		{Label: "back to pane", Href: "/p/" + slug},
	}
	data := struct {
		Base
		Slug  string
		Pane  tmux.Pane
		Frame template.HTML
		Lines int
	}{
		Base:  base,
		Slug:  slug,
		Pane:  p,
		Frame: frameHTML(frame.Render(raw, true)),
		Lines: lines,
	}
	s.render(w, "history.html", data)
}

func (s *Server) paneKeys(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	ctx := r.Context()

	var (
		text  string
		keys  []string
		enter bool
	)
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		var body struct {
			Key  string `json:"key"`
			Text string `json:"text"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&body); err != nil {
			s.fail(w, http.StatusBadRequest, "invalid json")
			return
		}
		if body.Key != "" {
			keys = []string{body.Key}
		}
		text = body.Text
	} else {
		if err := r.ParseForm(); err != nil {
			s.fail(w, http.StatusBadRequest, "invalid form")
			return
		}
		text = r.PostFormValue("text")
		keys = strings.Fields(r.PostFormValue("keys"))
		enter = r.PostFormValue("enter") == "1"
	}

	if len(text) > 8<<10 {
		s.fail(w, http.StatusRequestEntityTooLarge, "input too large")
		return
	}
	for _, k := range keys {
		if !validKey(k) {
			s.fail(w, http.StatusBadRequest, "invalid key name")
			return
		}
	}

	switch {
	case len(keys) > 0:
		if err := s.tmux.SendKeys(ctx, p.ID, keys...); err != nil {
			s.fail(w, http.StatusInternalServerError, err.Error())
			return
		}
	case strings.Contains(text, "\n"):
		// Multi-line text goes through a paste buffer: the pane's own editor
		// then decides whether Enter submits or inserts a newline.
		if err := s.tmux.Paste(ctx, p.ID, text); err != nil {
			s.fail(w, http.StatusInternalServerError, err.Error())
			return
		}
	case text != "":
		if err := s.tmux.SendText(ctx, p.ID, text); err != nil {
			s.fail(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if enter {
		if err := s.tmux.SendKeys(ctx, p.ID, "Enter"); err != nil {
			s.fail(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// validKey accepts tmux key names only: C-a..C-z, M-x, a fixed set of special
// keys, or a single printable character. It exists because the value is handed
// to `send-keys`, where an unexpected name is a command, not text.
func validKey(k string) bool {
	if k == "" || len(k) > 12 {
		return false
	}
	if len([]rune(k)) == 1 {
		return true
	}
	if len(k) == 3 && (k[0] == 'C' || k[0] == 'M') && k[1] == '-' {
		return k[2] >= 'a' && k[2] <= 'z' || k[2] >= 'A' && k[2] <= 'Z' || k[2] == '-'
	}
	switch k {
	case "Enter", "Escape", "Tab", "BTab", "BSpace", "Space", "DC", "Up", "Down",
		"Left", "Right", "Home", "End", "PPage", "NPage", "IC", "F1", "F2", "F3",
		"F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12":
		return true
	}
	return false
}

func (s *Server) paneSeen(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	// The tick recomputes @agent_win from @agent_unseen on its next pass (2s),
	// so clearing the pane flag is all a "seen" needs.
	if err := s.tmux.UnsetPaneOption(ctx, p.ID, "@agent_unseen"); err != nil {
		s.fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	http.Redirect(w, r, "/p/"+Slug(p.ID), http.StatusSeeOther)
}

func (s *Server) paneFocus(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	if err := s.tmux.FocusOnDesktop(r.Context(), p.ID); err != nil {
		s.fail(w, http.StatusConflict, err.Error())
		return
	}
	http.Redirect(w, r, "/p/"+Slug(p.ID), http.StatusSeeOther)
}

func (s *Server) paneKill(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil || r.PostFormValue("confirm") != "1" {
		s.fail(w, http.StatusBadRequest, "kill requires confirm=1")
		return
	}
	if err := s.tmux.KillPane(r.Context(), p.ID); err != nil {
		s.fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// DiffPage renders git status plus one file's diff.
type DiffPage struct {
	Base
	Slug     string
	Pane     tmux.Pane
	Repo     diff.Repo
	Files    []diff.File
	Selected string
	Result   diff.Result
	Rows     []diff.Row
	View     string
	Staged   bool
	Ctx      int
	IsRepo   bool
	ErrText  string
}

func (s *Server) diffPage(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	slug := Slug(p.ID)
	page := DiffPage{
		Base: s.subBase("diff", "diff", "/p/"+slug, "diff", p.Session+":"+fmt.Sprint(p.WindowIndex)),
		Slug: slug,
		Pane: p,
		Ctx:  atoiOr(r.URL.Query().Get("ctx"), 3),
	}
	page.Staged = r.URL.Query().Get("staged") == "1"
	page.View = "unified"
	if r.URL.Query().Get("view") == "split" {
		page.View = "split"
	}
	repo, err := s.git.Find(ctx, p.Path)
	if err != nil {
		page.ErrText = "not a git worktree"
		s.render(w, "diff.html", page)
		return
	}
	page.Repo, page.IsRepo = repo, true
	page.Sub = shortRepo(repo.Root) + " · " + repo.Branch
	page.Actions = diffActions(page.Slug, r.URL.Query().Get("file"), page.Staged, page.Ctx, page.View)

	files, err := s.git.Status(ctx, repo.Root)
	if err != nil {
		page.ErrText = err.Error()
		s.render(w, "diff.html", page)
		return
	}
	page.Files = files

	selected := r.URL.Query().Get("file")
	if selected == "" && len(files) > 0 {
		selected = files[0].Path
	}
	if selected != "" {
		var file *diff.File
		for i := range files {
			if files[i].Path == selected {
				file = &files[i]
				break
			}
		}
		if file == nil {
			page.ErrText = "file is not modified"
			s.render(w, "diff.html", page)
			return
		}
		res, err := s.git.FileDiff(ctx, repo.Root, selected, page.Staged, file.Untracked, page.Ctx)
		if err != nil {
			page.ErrText = err.Error()
			s.render(w, "diff.html", page)
			return
		}
		res = diff.Display(res)
		// A fully staged change has an empty unstaged diff. Showing a blank
		// table for it reads as broken, so fall back to the staged side.
		if !page.Staged && !file.Untracked && !hasChanges(res) {
			if staged, err := s.git.FileDiff(ctx, repo.Root, selected, true, false, page.Ctx); err == nil {
				if staged = diff.Display(staged); hasChanges(staged) {
					res = staged
					page.Staged = true
				}
			}
		}
		page.Result = res
		if page.View == "split" {
			page.Rows = diff.Split(res.Lines)
		}
		page.Selected = selected
		// Keep the menu consistent with the side that was actually shown.
		page.Actions = diffActions(page.Slug, selected, page.Staged, page.Ctx, page.View)
	}
	s.render(w, "diff.html", page)
}

// hasChanges reports whether a parsed diff actually shows something: mode,
// rename and binary notices count, a hunk made only of context does not.
func hasChanges(res diff.Result) bool {
	for _, l := range res.Lines {
		switch l.Kind {
		case "add", "del":
			return true
		case "meta":
			if !strings.HasPrefix(l.Text, "similarity index") {
				return true
			}
		}
	}
	return false
}

// NewPage renders the new-session form.
type NewPage struct {
	Base
	Home      string
	Sessions  []string
	Programs  []string
	FromPane  string
	FormError string
	Dir       string
	Name      string
	Program   string
	Target    string
}

func (s *Server) newPage(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	page := NewPage{
		Base:     s.base("new session", "new"),
		Programs: []string{"", "omp", "opencode"},
		FromPane: r.URL.Query().Get("pane"),
		Dir:      r.URL.Query().Get("dir"),
		Target:   "session",
	}
	page.Back = "/"
	page.Context = "new session"
	page.Sub = "pick a directory"
	page.Home = s.dirs.Root

	// Default to the directory of the pane we came from, so "new session here"
	// works without typing anything.
	if page.Dir == "" && page.FromPane != "" && validPane(page.FromPane) {
		if p, err := s.tmux.GetPane(ctx, "%"+page.FromPane); err == nil {
			page.Dir = p.Path
		}
	}
	if page.Dir == "" {
		page.Dir = s.dirs.Root
	}

	if panes, err := s.tmux.ListPanes(ctx); err == nil {
		seen := map[string]bool{}
		for _, p := range panes {
			if !seen[p.Session] {
				seen[p.Session] = true
				page.Sessions = append(page.Sessions, p.Session)
			}
		}
		sort.Strings(page.Sessions)
	}
	s.render(w, "new.html", page)
}

// dirSuggestions backs the directory picker: fzf-ranked matches for whatever is
// in the box, indexed once from the app's home directory.
func (s *Server) dirSuggestions(w http.ResponseWriter, r *http.Request) {
	items, err := s.dirs.Search(r.Context(), r.URL.Query().Get("q"))
	if err != nil {
		s.log.Warn("dir suggestions failed", "err", err)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if items == nil {
		items = []string{}
	}
	_ = json.NewEncoder(w).Encode(struct {
		Items []string `json:"items"`
	}{Items: items})
}

func (s *Server) newSession(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		s.fail(w, http.StatusBadRequest, "invalid form")
		return
	}
	ctx := r.Context()
	dir, err := s.allowedDir(strings.TrimSpace(r.PostFormValue("dir")))
	if err != nil {
		errPage := NewPage{
			Base:      s.base("new session", "new"),
			FormError: err.Error(),
			Programs:  []string{"", "omp", "opencode"},
			Dir:       r.PostFormValue("dir"),
			Name:      r.PostFormValue("name"),
			Program:   r.PostFormValue("program"),
			Target:    r.PostFormValue("target"),
		}
		errPage.Back = "/"
		errPage.Context = "new session"
		s.render(w, "new.html", errPage)
		return
	}

	name := strings.TrimSpace(r.PostFormValue("name"))
	if name == "" {
		name = filepath.Base(dir)
	}
	if !validSessionName(name) {
		s.fail(w, http.StatusBadRequest, "session name may only contain letters, digits, '.', '_' and '-'")
		return
	}

	program := r.PostFormValue("program")
	switch program {
	case "", "zsh", "omp", "opencode":
	default:
		s.fail(w, http.StatusBadRequest, "unknown program")
		return
	}

	target := r.PostFormValue("target")
	var paneID string
	if session := r.PostFormValue("session"); target == "window" && validSessionName(session) && s.tmux.HasSession(ctx, session) {
		paneID, err = s.tmux.NewWindow(ctx, session, dir, "")
	} else {
		paneID, err = s.tmux.NewSession(ctx, name, dir, "")
	}
	if err != nil {
		s.fail(w, http.StatusConflict, err.Error())
		return
	}
	if program != "" {
		// Typed at the prompt rather than exec'd, so the shell's aliases and
		// wrappers (nono, omp's model flags) apply exactly as on the desktop.
		time.Sleep(120 * time.Millisecond)
		if err := s.tmux.SendText(ctx, paneID, program); err == nil {
			_ = s.tmux.SendKeys(ctx, paneID, "Enter")
		}
	}
	http.Redirect(w, r, "/p/"+Slug(paneID), http.StatusSeeOther)
}

// allowedDir resolves a user-supplied directory and refuses anything outside
// the configured roots. Symlinks are resolved first so a link cannot smuggle a
// path out of the roots.
func (s *Server) allowedDir(raw string) (string, error) {
	if raw == "" {
		return "", errors.New("a directory is required")
	}
	if strings.HasPrefix(raw, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		raw = filepath.Join(home, raw[2:])
	}
	abs, err := filepath.Abs(raw)
	if err != nil {
		return "", err
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("%s: %w", raw, err)
	}
	info, err := os.Stat(real)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", raw)
	}
	for _, root := range s.roots {
		resolvedRoot, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		if real == resolvedRoot || strings.HasPrefix(real, resolvedRoot+string(os.PathSeparator)) {
			return real, nil
		}
	}
	return "", fmt.Errorf("%s is outside the allowed roots", real)
}

func (s *Server) base(title, page string) Base {
	return Base{Title: title, Page: page, Dev: s.dev}
}

// subBase is the header for a page that lives under a pane.
func (s *Server) subBase(title, page, back, context, sub string) Base {
	b := s.base(title, page)
	b.Back = back
	b.Context = context
	b.Sub = sub
	return b
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

// paneActions is the pane page's overflow menu. Keeping every state-changing
// action in here is what frees the screen for the frame and the composer.
func paneActions(slug string, fit bool) []Action {
	fitLabel := "fit to width"
	if fit {
		fitLabel = "wrap text"
	}
	return []Action{
		{Label: "diff", Href: "/p/" + slug + "/diff"},
		{Label: "history", Href: "/p/" + slug + "/history"},
		{Label: fitLabel, Href: "/p/" + slug + "?fit=" + fmt.Sprint(boolInt(!fit))},
		{Label: "mark seen", Post: "/p/" + slug + "/seen"},
		{Label: "open on desktop", Post: "/p/" + slug + "/focus"},
		{
			Label:   "kill pane",
			Post:    "/p/" + slug + "/kill",
			Confirm: "Kill pane " + slug + "?",
			Hidden:  []FormValue{{Name: "confirm", Value: "1"}},
			Class:   "danger",
		},
		{Label: "sign out", Href: "/auth/logout"},
	}
}

func frameHTML(lines []frame.Line) template.HTML {
	var b strings.Builder
	for _, ln := range lines {
		b.WriteString(`<div class="line" data-n="`)
		b.WriteString(fmt.Sprint(ln.Num))
		b.WriteString(`">`)
		b.WriteString(ln.HTML)
		b.WriteString(`</div>`)
	}
	return template.HTML(b.String())
}

// diffActions rebuilds the diff page's menu, carrying the selected file and
// context through each toggle.
func diffActions(slug, file string, staged bool, ctx int, view string) []Action {
	link := func(label string, mutate func(url.Values)) Action {
		v := url.Values{}
		if file != "" {
			v.Set("file", file)
		}
		if staged {
			v.Set("staged", "1")
		}
		if ctx != 3 {
			v.Set("ctx", fmt.Sprint(ctx))
		}
		mutate(v)
		return Action{Label: label, Href: "/p/" + slug + "/diff?" + v.Encode()}
	}
	stagedLabel := "show staged"
	if staged {
		stagedLabel = "show unstaged"
	}
	viewLabel := "side-by-side"
	if view == "split" {
		viewLabel = "unified"
	}
	return []Action{
		link(viewLabel, func(v url.Values) {
			if view == "split" {
				v.Del("view")
			} else {
				v.Set("view", "split")
			}
		}),
		link(stagedLabel, func(v url.Values) {
			if staged {
				v.Del("staged")
			} else {
				v.Set("staged", "1")
			}
		}),
		link("more context", func(v url.Values) { v.Set("ctx", "8") }),
		link("less context", func(v url.Values) { v.Del("ctx") }),
		{Label: "back to pane", Href: "/p/" + slug},
		{Label: "sign out", Href: "/auth/logout"},
	}
}
