// Package server implements the read-only fleet-edge HTTP dashboard.
package server

import (
	"embed"
	"encoding/json"
	"html/template"
	"io/fs"
	"net/http"
	"sort"
	"strings"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*.css
var staticFS embed.FS

var tmpl = template.Must(template.ParseFS(templateFS, "templates/*.html"))

// Config holds the personalization knobs. The zero value is a plain
// dashboard: no background, default icon CDN, no extra links.
type Config struct {
	// Title shown in the nav and <title>; "" means "fleet-edge".
	Title string
	// Background is an http(s) URL used directly, or a local file path
	// served at /assets/bg. "" means no background image.
	Background string
	// IconBase is the CDN template for named icons ({name} substituted);
	// "" means dash.DefaultIconBase.
	IconBase string
	// Links are extra start-page entries (non-container apps).
	Links []dash.Link
}

// Common is embedded in every page's view model.
type Common struct {
	Page       string
	Title      string
	Background string // URL for the background image, "" for none
}

// StartData is the view model for start.html (the app tile grid).
type StartData struct {
	Common
	Groups      []dash.Group
	GeneratedAt string
	HostsTotal  int
	HostsUp     int
}

// IndexData is the view model for services.html: the merged state plus
// a small summary the template renders without needing template funcs.
type IndexData struct {
	state.Merged
	Common
	TotalServices int
	ActiveCount   int
	FailedCount   int
	// BackupStale: services whose last backup is older than 36h.
	BackupStale int
	HostsTotal  int
	HostsUp     int
}

// HostsData is the view model for hosts.html.
type HostsData struct {
	state.Merged
	Common
}

// Source supplies the current merged state. Implemented by *state.Poller;
// an interface here keeps the server testable without a running poller.
type Source interface {
	Current() state.Merged
}

// Server is the read-only fleet-edge HTTP handler. It has no POST
// handlers anywhere: every route is a GET that renders inventory plus
// the latest poll data.
type Server struct {
	src Source
	cfg Config
	mux *http.ServeMux
}

func isURL(s string) bool {
	return strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://")
}

// New builds a Server backed by src.
func New(src Source, cfg Config) *Server {
	if cfg.Title == "" {
		cfg.Title = "fleet-edge"
	}
	s := &Server{src: src, cfg: cfg, mux: http.NewServeMux()}
	s.mux.HandleFunc("/", s.handleStart)
	s.mux.HandleFunc("/services", s.handleServices)
	s.mux.HandleFunc("/hosts", s.handleHosts)
	s.mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux.HandleFunc("/api/state.json", s.handleAPIState)
	s.mux.Handle("/static/", http.StripPrefix("/static/", staticHandler()))
	if cfg.Background != "" && !isURL(cfg.Background) {
		path := cfg.Background
		s.mux.HandleFunc("/assets/bg", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "public, max-age=3600")
			http.ServeFile(w, r, path)
		})
	}
	return s
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func staticHandler() http.Handler {
	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		panic(err)
	}
	return http.FileServer(http.FS(sub))
}

func (s *Server) common(page string) Common {
	c := Common{Page: page, Title: s.cfg.Title}
	switch {
	case s.cfg.Background == "":
	case isURL(s.cfg.Background):
		c.Background = s.cfg.Background
	default:
		c.Background = "/assets/bg"
	}
	return c
}

func hostCounts(m state.Merged) (total, up int) {
	for _, h := range m.Hosts {
		if h.HasEndpoint {
			total++
		}
		if h.Reachable {
			up++
		}
	}
	return
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *Server) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	m := s.src.Current()
	data := StartData{
		Common:      s.common("start"),
		Groups:      dash.Build(m, s.cfg.Links, s.cfg.IconBase),
		GeneratedAt: m.GeneratedAt.Format("2006-01-02 15:04:05 UTC"),
	}
	data.HostsTotal, data.HostsUp = hostCounts(m)
	s.render(w, "start.html", data)
}

func (s *Server) handleServices(w http.ResponseWriter, r *http.Request) {
	m := s.src.Current()
	sort.Slice(m.Services, func(i, j int) bool {
		if m.Services[i].DeclaredHost != m.Services[j].DeclaredHost {
			return m.Services[i].DeclaredHost < m.Services[j].DeclaredHost
		}
		return m.Services[i].Name < m.Services[j].Name
	})
	data := IndexData{Merged: m, Common: s.common("services"), TotalServices: len(m.Services)}
	for _, svc := range m.Services {
		switch svc.Active {
		case "active":
			data.ActiveCount++
		case "failed":
			data.FailedCount++
		}
		if svc.Backup == "stale" {
			data.BackupStale++
		}
	}
	data.HostsTotal, data.HostsUp = hostCounts(m)
	s.render(w, "services.html", data)
}

func (s *Server) handleHosts(w http.ResponseWriter, r *http.Request) {
	m := s.src.Current()
	sort.Slice(m.Hosts, func(i, j int) bool { return m.Hosts[i].Host < m.Hosts[j].Host })
	s.render(w, "hosts.html", HostsData{Merged: m, Common: s.common("hosts")})
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok"))
}

func (s *Server) handleAPIState(w http.ResponseWriter, r *http.Request) {
	m := s.src.Current()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(m); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
