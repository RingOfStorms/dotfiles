package web

import (
	"context"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// gitCommands are the shell functions the git submenu can run. Each runs in a
// fresh shell split next to the pane (so an agent's prompt is never typed
// into) and the phone lands on that shell to watch it. arg says whether the
// command takes the menu's text field: "" none, "required", "optional".
var gitCommands = []struct {
	Name, Label, Arg, Placeholder string
}{
	{"branch", "branch", "required", "branch name"},
	{"branchdel", "branchdel", "optional", "branch (default: current)"},
	{"gcamp", "gcamp (commit all, AI msg)", "", ""},
	{"push", "push", "", ""},
	{"pullmaster", "pullmaster", "", ""},
}

// gitArg is what a branch name may look like; anything else is refused rather
// than quoted, since it is typed into an interactive shell.
var gitArg = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$`)

// paneGit runs one of gitCommands in a new shell split from the pane.
func (s *Server) paneGit(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		s.fail(w, http.StatusBadRequest, "invalid form")
		return
	}
	name := r.PostFormValue("cmd")
	arg := strings.TrimSpace(r.PostFormValue("arg"))
	line := ""
	for _, c := range gitCommands {
		if c.Name != name {
			continue
		}
		line = c.Name
		switch {
		case arg != "" && c.Arg == "":
			s.fail(w, http.StatusBadRequest, name+" takes no argument")
			return
		case arg == "" && c.Arg == "required":
			s.fail(w, http.StatusBadRequest, name+" needs an argument")
			return
		case arg != "" && !gitArg.MatchString(arg) || strings.Contains(arg, ".."):
			s.fail(w, http.StatusBadRequest, "invalid branch name")
			return
		case arg != "":
			line += " " + arg
		}
	}
	if line == "" {
		s.fail(w, http.StatusBadRequest, "unknown command")
		return
	}
	ctx := r.Context()
	id, err := s.tmux.SplitWindow(ctx, p.ID, "")
	if err != nil {
		s.fail(w, http.StatusConflict, err.Error())
		return
	}
	s.startProgram(ctx, id, line)
	http.Redirect(w, r, "/p/"+Slug(id)+"?view=wrap", http.StatusSeeOther)
}

// paneWorkspace opens a new window (workspace) in the pane's session at the
// main checkout of its repo: from a linked worktree that is the repo's root,
// not the worktree. Outside git it is the pane's own directory.
func (s *Server) paneWorkspace(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		s.fail(w, http.StatusBadRequest, "invalid form")
		return
	}
	program := r.PostFormValue("program")
	switch program {
	case "", "omp":
	default:
		s.fail(w, http.StatusBadRequest, "unknown program")
		return
	}
	ctx := r.Context()
	dir := s.repoMain(ctx, p.Path)
	id, err := s.tmux.NewWindow(ctx, p.Session, dir, "")
	if err != nil {
		s.fail(w, http.StatusConflict, err.Error())
		return
	}
	s.startProgram(ctx, id, program)
	http.Redirect(w, r, "/p/"+Slug(id)+awaitQuery(program), http.StatusSeeOther)
}

// repoMain is the main checkout holding dir, or dir when it is not in git.
func (s *Server) repoMain(ctx context.Context, dir string) string {
	if s.git == nil {
		return dir
	}
	common, err := s.git.CommonDir(ctx, dir)
	if err != nil || common == "" {
		return dir
	}
	if filepath.Base(common) == ".git" {
		return filepath.Dir(common)
	}
	// A bare common dir has no checkout of its own; stay where we are.
	return dir
}

// paneNative answers whether the conversation view can show the pane yet:
// 204 when the agent's session log is found, 404 otherwise. The terminal view
// polls it after a new agent pane opens, then switches over.
func (s *Server) paneNative(w http.ResponseWriter, r *http.Request) {
	p, ok := s.pane(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if s.chat != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if _, err := s.chat.Locate(ctx, p); err == nil {
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}
	w.WriteHeader(http.StatusNotFound)
}

// gitActions is the git submenu for a pane.
func gitActions(slug string) []Action {
	out := make([]Action, 0, len(gitCommands))
	for _, c := range gitCommands {
		a := Action{Label: c.Label, Post: "/p/" + slug + "/git", Hidden: []FormValue{{Name: "cmd", Value: c.Name}}}
		if c.Arg != "" {
			a.Input, a.InputRequired, a.Label = c.Placeholder, c.Arg == "required", c.Name
		}
		if c.Name == "branchdel" {
			a.Confirm = "Remove the branch worktree?"
			a.Class = "danger"
		}
		out = append(out, a)
	}
	return out
}

// awaitQuery marks a redirect to a pane that was just told to start an agent,
// so the page switches to the conversation once the agent's log appears.
func awaitQuery(program string) string {
	if program == "" {
		return ""
	}
	return "?await=1"
}
