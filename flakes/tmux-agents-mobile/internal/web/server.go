// Package web serves the mobile UI: an inbox of agent panes, a single-pane
// viewer fed by SSE, a git diff reader and a new-session form.
package web

import (
	"compress/gzip"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/agents"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/dirs"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/watch"
)

//go:embed templates/*.html templates/chat/*.html static/*
var assets embed.FS

// Server holds the handlers' dependencies.
type Server struct {
	tmux   *tmux.Client
	hub    *watch.Hub
	chat   *watch.ChatHub
	agents *agents.Provider
	git    *diff.Git
	dirs   *dirs.Index
	roots  []string
	log    *slog.Logger
	tpl    *template.Template
	dev    bool
}

// New wires the server. roots are the directories a new session may be created
// in; a directory outside them is rejected, so the form is not a way to start a
// shell anywhere on the machine.
func New(t *tmux.Client, hub *watch.Hub, chat *watch.ChatHub, ag *agents.Provider, g *diff.Git, index *dirs.Index, roots []string, dev bool, log *slog.Logger) (*Server, error) {
	tpl, err := template.New("").ParseFS(assets, "templates/*.html")
	if err != nil {
		return nil, err
	}
	return &Server{tmux: t, hub: hub, chat: chat, agents: ag, git: g, dirs: index, roots: roots, log: log, tpl: tpl, dev: dev}, nil
}

// Handler returns the root handler with all routes and middleware applied.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.inbox)
	mux.HandleFunc("GET /p/{pane}", s.panePage)
	mux.HandleFunc("GET /p/{pane}/events", s.paneEvents)
	mux.HandleFunc("GET /p/{pane}/chat/events", s.chatEvents)
	mux.HandleFunc("GET /p/{pane}/chat/earlier", s.chatEarlier)
	mux.HandleFunc("GET /p/{pane}/history", s.paneHistory)
	mux.HandleFunc("POST /p/{pane}/keys", s.paneKeys)
	mux.HandleFunc("POST /p/{pane}/seen", s.paneSeen)
	mux.HandleFunc("POST /p/{pane}/focus", s.paneFocus)
	mux.HandleFunc("POST /p/{pane}/kill", s.paneKill)
	mux.HandleFunc("GET /p/{pane}/diff", s.diffPage)
	mux.HandleFunc("GET /new", s.newPage)
	mux.HandleFunc("GET /new/dirs", s.dirSuggestions)
	mux.HandleFunc("POST /new", s.newSession)
	mux.Handle("GET /static/", http.FileServerFS(assets))
	// The service worker has to be served from the root: its scope is its own
	// URL, and the whole app needs to be in scope for installability.
	mux.HandleFunc("GET /sw.js", s.rootAsset("static/sw.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("GET /manifest.webmanifest", s.rootAsset("static/manifest.webmanifest", "application/manifest+json"))
	return s.middleware(mux)
}

// Health is the loopback-only liveness endpoint, served on its own listener so
// the authenticated mux never has to make an exception.
func (s *Server) Health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, "ok\n")
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return s.recoverer(s.logger(s.headers(s.originCheck(gzipHandler(next)))))
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.log.Error("panic", "path", r.URL.Path, "value", v)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) logger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.log.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"ms", time.Since(start).Milliseconds(),
			"ip", clientIP(r),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// Flush keeps streaming responses (SSE) working through the recorder.
func (w *statusRecorder) Flush() {
	_ = http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *statusRecorder) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// headers sets the defensive defaults. The app is tailnet-only, but a stray
// reverse proxy or a future public exposure should not be able to frame it or
// leak the pane URL in a Referer.
func (s *Server) headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// Nothing here is worth caching: after a sign-out the back button must not
		// show a page rendered from the previous session.
		if !strings.HasPrefix(r.URL.Path, "/static/") {
			h.Set("Cache-Control", "no-store")
		}
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy",
			"default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

// originCheck rejects cross-site POSTs. The session cookie is already
// SameSite=Lax, so this is belt and braces; it exists so the endpoints that type
// into a live shell cannot be driven from another site at all.
//
// The reliable signal is Sec-Fetch-Site: the browser derives it from the
// document's origin and the request target, so it stays correct behind a TLS
// proxy, tailscale serve, or anything that rewrites Host — which a string
// comparison of Origin against r.Host does not. Only when the browser sends no
// fetch metadata do we fall back to comparing origin and Host, and even then
// only the hostname (a TLS-terminating proxy legitimately changes the scheme).
func (s *Server) originCheck(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			next.ServeHTTP(w, r)
			return
		}

		site := r.Header.Get("Sec-Fetch-Site")
		switch site {
		case "same-origin", "none", "":
			// Fine, or unknown: fall through to the Origin check below.
		default:
			s.refuseCrossOrigin(w, r, "Sec-Fetch-Site: "+site)
			return
		}

		origin := r.Header.Get("Origin")
		if origin == "" {
			next.ServeHTTP(w, r)
			return
		}
		// Sec-Fetch-Site already settled it; Origin is the fallback for clients
		// that send no fetch metadata.
		if site == "" && !sameHostname(origin, r.Host) {
			s.refuseCrossOrigin(w, r, "origin "+origin+" does not match host "+r.Host)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// sameHostname compares the host of a URL with a request Host header, ignoring
// scheme and port: the scheme can legitimately differ behind a TLS terminator,
// and the port is not part of the CSRF threat model once the cookie is
// SameSite=Lax.
func sameHostname(origin, host string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	want := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		want = h
	}
	return strings.EqualFold(u.Hostname(), strings.Trim(want, "[]"))
}

// refuseCrossOrigin explains the refusal in the page as well as the log: the
// phone is where this is seen, and its developer tools are not at hand.
func (s *Server) refuseCrossOrigin(w http.ResponseWriter, r *http.Request, reason string) {
	s.log.Warn("cross-origin POST refused",
		"path", r.URL.Path,
		"method", r.Method,
		"origin", r.Header.Get("Origin"),
		"host", r.Host,
		"forwarded_proto", r.Header.Get("X-Forwarded-Proto"),
		"sec_fetch_site", r.Header.Get("Sec-Fetch-Site"),
		"reason", reason,
	)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	fmt.Fprintf(w, `<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>refused</title>
<body style="font:16px system-ui,sans-serif;background:#11111b;color:#cdd6f4;padding:24px;line-height:1.5">
<h1 style="font-size:18px;color:#f38ba8;margin:0 0 10px">Cross-origin request refused</h1>
<p style="color:#a6adc8">The request came from another origin, so it was not applied.</p>
<dl style="font-family:ui-monospace,monospace;font-size:13px;color:#7f849c;margin:14px 0">
<dt>reason</dt><dd style="margin:0 0 6px 0;color:#cdd6f4">%s</dd>
<dt>origin</dt><dd style="margin:0 0 6px 0;color:#cdd6f4">%s</dd>
<dt>host</dt><dd style="margin:0 0 6px 0;color:#cdd6f4">%s</dd>
</dl>
<p><a href="/" style="color:#89b4fa">back to the inbox</a></p>
</body>
`, template.HTMLEscapeString(reason),
		template.HTMLEscapeString(r.Header.Get("Origin")),
		template.HTMLEscapeString(r.Host))
}

type gzipWriter struct {
	http.ResponseWriter
	gz          *gzip.Writer
	wroteHeader bool
	compress    bool
}

func gzipHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}
		gz := gzip.NewWriter(w)
		gw := &gzipWriter{ResponseWriter: w, gz: gz}
		defer func() { _ = gz.Close() }()
		next.ServeHTTP(gw, r)
	})
}

func (w *gzipWriter) WriteHeader(code int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	ct := w.Header().Get("Content-Type")
	switch {
	case strings.Contains(ct, "event-stream"), strings.HasPrefix(ct, "image/"),
		strings.HasPrefix(ct, "font/"):
		w.compress = false
	default:
		w.compress = strings.HasPrefix(ct, "text/") || strings.HasPrefix(ct, "application/json") ||
			strings.HasPrefix(ct, "application/javascript")
	}
	if w.compress {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Del("Content-Length")
		w.Header().Add("Vary", "Accept-Encoding")
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *gzipWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	if w.compress {
		return w.gz.Write(b)
	}
	return w.ResponseWriter.Write(b)
}

func (w *gzipWriter) Flush() {
	if w.compress {
		_ = w.gz.Flush()
	}
	// Not a type assertion on ResponseWriter: the next writer in the chain may
	// only 'unwrap' to a Flusher (statusRecorder does), and a failed
	// assertion here silently buffers every server-sent event until the
	// response buffer fills.
	_ = http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *gzipWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func clientIP(r *http.Request) string {
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		if i := strings.IndexByte(v, ','); i >= 0 {
			return strings.TrimSpace(v[:i])
		}
		return v
	}
	host := r.RemoteAddr
	if i := strings.LastIndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	return host
}

// FormValue is one hidden input submitted with a menu action.
type FormValue struct {
	Name  string
	Value string
}

// Action is one entry of a page's overflow menu: a link (Href) or a POST
// (Post). Menu actions are the only place that changes state on the pane page,
// so the frame and the composer own the whole screen.
type Action struct {
	Label   string
	Href    string
	Post    string
	Confirm string
	Hidden  []FormValue
	Class   string
}

// Base is the data every page template needs.
type Base struct {
	Title string
	Page  string
	Dev   bool
	Error string

	// Set for sub-pages: the header shows a back arrow, the context label
	// instead of the "agents" brand, and the overflow menu.
	Back       string
	Context    string
	Sub        string
	Glyph      string
	GlyphClass string
	Actions    []Action
}

// stateGlyph mirrors tmux-agents' status glyphs exactly, so the same visual
// language means the same thing on the desktop and the phone:
// `!` input (bold red), `⠿` working (yellow), `●` done unseen (green),
// `○` idle seen (dim).
func stateGlyph(state string, unseen bool) (glyph, class string) {
	switch state {
	case "input":
		return "!", "input"
	case "working":
		return "⠿", "working"
	case "idle":
		if unseen {
			return "●", "done"
		}
		return "○", "idle"
	}
	return "·", "none"
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tpl.ExecuteTemplate(w, name, data); err != nil {
		s.log.Error("template", "name", name, "err", err)
		http.Error(w, "template error", http.StatusInternalServerError)
	}
}

func (s *Server) fail(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, msg+"\n")
}

func validPane(slug string) bool {
	// URLs carry the numeric part of the pane id ("0" for "%0"): a bare "%" is
	// not a valid percent-escape in a URL path, and double-encoding it in every
	// link is a bug waiting to happen.
	if slug == "" || len(slug) > 8 {
		return false
	}
	for _, r := range slug {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// Slug is the URL form of a pane id: "%12" -> "12".
func Slug(id string) string { return strings.TrimPrefix(id, "%") }

func validSessionName(name string) bool {
	if name == "" || len(name) > 40 {
		return false
	}
	for i, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-' || r == '_' || r == '.':
			if i == 0 {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func atoiOr(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}

var errBadPane = errors.New("invalid pane id")

func (s *Server) pane(w http.ResponseWriter, r *http.Request) (tmux.Pane, bool) {
	slug := r.PathValue("pane")
	if !validPane(slug) {
		s.fail(w, http.StatusBadRequest, "invalid pane id")
		return tmux.Pane{}, false
	}
	id := "%" + slug
	p, err := s.tmux.GetPane(r.Context(), id)
	if err != nil {
		// The pane is gone: exited, killed, or its session closed. That is a
		// normal end, not an error - send the browser back to the inbox rather
		// than leaving it on a dead screen.
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return tmux.Pane{}, false
	}
	return p, true
}

// rootAsset serves an embedded file from the site root rather than /static/.
func (s *Server) rootAsset(name, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := assets.ReadFile(name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write(body)
	}
}
