// Package server implements the read-only fleet-edge HTTP dashboard.
package server

import (
	"embed"
	"encoding/json"
	"html/template"
	"net/http"
	"sort"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

//go:embed templates/*.html
var templateFS embed.FS

var tmpl = template.Must(template.ParseFS(templateFS, "templates/*.html"))

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
	mux *http.ServeMux
}

// New builds a Server backed by src.
func New(src Source) *Server {
	s := &Server{src: src, mux: http.NewServeMux()}
	s.mux.HandleFunc("/", s.handleIndex)
	s.mux.HandleFunc("/hosts", s.handleHosts)
	s.mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux.HandleFunc("/api/state.json", s.handleAPIState)
	return s
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	m := s.src.Current()
	sort.Slice(m.Services, func(i, j int) bool { return m.Services[i].Name < m.Services[j].Name })
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.ExecuteTemplate(w, "index.html", m); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *Server) handleHosts(w http.ResponseWriter, r *http.Request) {
	m := s.src.Current()
	sort.Slice(m.Hosts, func(i, j int) bool { return m.Hosts[i].Host < m.Hosts[j].Host })
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.ExecuteTemplate(w, "hosts.html", m); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
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
