package web

import (
	"errors"
	"net/http"
	"os/user"
	"strconv"

	"github.com/coder/websocket"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/term"
)

// termViewport keeps the browser from zooming the page: on the terminal a
// pinch changes the font size instead (term.js), so the grid is re-fitted and
// the shell resized rather than a scaled bitmap of the old grid.
// interactive-widget=resizes-content makes Android shrink the layout when the
// keyboard opens, so the bottom rows are not hidden behind it.
const termViewport = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover, interactive-widget=resizes-content"

func (s *Server) termPage(w http.ResponseWriter, r *http.Request) {
	if s.terms == nil {
		http.NotFound(w, r)
		return
	}
	who := s.host
	if u, err := user.Current(); err == nil {
		who = u.Username + "@" + s.host
	}
	b := s.base(who, "term")
	b.Viewport = termViewport
	b.Styles = []string{"xterm.css"}
	b.Scripts = []string{"xterm.js", "addon-fit.js", "addon-web-links.js", "addon-unicode11.js", "term.js"}
	// Handled by term.js; the hrefs are what a click does without it.
	b.Actions = []Action{
		{Label: "larger text", Href: "#", Class: "js-font-up"},
		{Label: "smaller text", Href: "#", Class: "js-font-down"},
		{Label: "copy selection", Href: "#", Class: "js-copy"},
		{Label: "copy screen", Href: "#", Class: "js-copy-screen"},
		{Label: "show/hide key bar", Href: "#", Class: "js-keys-toggle"},
		{Label: "new shell", Href: "/term?new=1", Class: "js-new-shell danger"},
	}
	s.render(w, "term.html", b)
}

// termSocket attaches a browser to a shell: the one named by ?id= while it is
// alive, else a new one. ?from= is the first output byte the browser still
// needs, ?gen= the attachment that last drew its screen, ?cols=/&rows= its
// grid.
func (s *Server) termSocket(w http.ResponseWriter, r *http.Request) {
	if s.terms == nil {
		http.NotFound(w, r)
		return
	}
	// This socket is a shell, so it gets a stricter check than the POST
	// routes: the session cookie is SameSite=Lax, which a sibling subdomain
	// (same-site, cross-origin) still receives.
	if reason := crossOriginUpgrade(r); reason != "" {
		s.log.Warn("terminal: cross-origin WebSocket refused",
			"origin", r.Header.Get("Origin"), "host", r.Host,
			"sec_fetch_site", r.Header.Get("Sec-Fetch-Site"), "reason", reason)
		http.Error(w, "cross-origin WebSocket refused", http.StatusForbidden)
		return
	}

	q := r.URL.Query()
	cols, rows := atoiOr(q.Get("cols"), 80), atoiOr(q.Get("rows"), 24)
	from, err := strconv.ParseInt(q.Get("from"), 10, 64)
	if err != nil {
		from = 0
	}
	// Unparsable means no screen drawn by a known attachment, like 0.
	last, _ := strconv.ParseUint(q.Get("gen"), 10, 64)
	sess, created, err := s.terms.Open(q.Get("id"), cols, rows)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, term.ErrTooMany) {
			status = http.StatusServiceUnavailable
		}
		s.log.Error("terminal: open", "err", err)
		http.Error(w, err.Error(), status)
		return
	}
	if created {
		from = 0
	} else {
		// The browser attaching now is the one looking at it: its grid wins.
		_ = sess.Resize(cols, rows)
	}

	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Checked above, with the same rules as the rest of the app
		// (Sec-Fetch-Site first, hostname-only Origin fallback), which also
		// hold behind a proxy that rewrites Host.
		InsecureSkipVerify: true,
	})
	if err != nil {
		s.log.Warn("terminal: upgrade", "err", err)
		return
	}
	sess.Serve(r.Context(), c, from, last, created)
}

// crossOriginUpgrade returns why a WebSocket handshake is not same-origin, or
// "" when it is. Browsers always send Origin on a WebSocket handshake; a
// client with neither header is not a browser and cannot be driven by a page.
func crossOriginUpgrade(r *http.Request) string {
	switch site := r.Header.Get("Sec-Fetch-Site"); site {
	case "same-origin":
		return ""
	case "":
		origin := r.Header.Get("Origin")
		if origin == "" || sameHostname(origin, r.Host) {
			return ""
		}
		return "origin " + origin + " does not match host " + r.Host
	default:
		return "Sec-Fetch-Site: " + site
	}
}
