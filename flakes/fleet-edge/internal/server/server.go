// Package server implements the read-only fleet-edge HTTP dashboard.
package server

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*.css
var staticFS embed.FS

var tmpl = template.Must(
	template.New("").Funcs(template.FuncMap{
		"formatBytes":  FormatBytes,
		"formatRate":   FormatRate,
		"formatUptime": FormatUptime,
		"pct": func(used, total uint64) float64 {
			if total == 0 {
				return 0
			}
			p := (float64(used) / float64(total)) * 100
			if p > 100 {
				return 100
			}
			return p
		},
	}).ParseFS(templateFS, "templates/*.html"),
)

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
	// HTTPClient is used for proxying /api/hosts/{name}/logs.json to fleet-agent.
	HTTPClient *http.Client
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
	BackupStale   int
	HostsTotal    int
	HostsUp       int
}

// HostCardView wraps state.HostView with pre-rendered sparklines and formatted summary fields.
type HostCardView struct {
	state.HostView
	CPUSparkline template.HTML
	MemPercent   float64
	MemSummary   string
	UptimeStr    string
}

// HostsData is the view model for hosts.html.
type HostsData struct {
	state.Merged
	Common
	ServerHosts      []HostCardView
	WorkstationHosts []HostCardView
	OtherHosts       []HostCardView
}

// LogTargetOption represents one selectable log source in the drill-down log viewer.
type LogTargetOption struct {
	Kind   string // "guest" or "unit"
	Target string
	Label  string
}

// HostDetailData is the view model for host_detail.html (/hosts/{name}).
type HostDetailData struct {
	Common
	Host             HostCardView
	RangeKey         string
	Ranges           []string
	CPUChart         template.HTML
	MemChart         template.HTML
	NetChart         template.HTML
	DiskChart        template.HTML
	TempChart        template.HTML
	Events           []store.Event
	Services         []state.ServiceView
	HostUnits        []state.ServiceStatus
	LogTargets       []LogTargetOption
	SelectedLogKind  string
	SelectedLogTgt   string
	SelectedLogLines string
	LogEntries       []LogEntryView
	LogError         string
}

// LogEntryView matches fleet-agent's /logs.json response entry.
type LogEntryView struct {
	Time     string `json:"time"`
	Unit     string `json:"unit,omitempty"`
	Priority int    `json:"priority"`
	Message  string `json:"message"`
}

// Source supplies the current merged state. Implemented by *state.Poller;
// an interface here keeps the server testable without a running poller.
type Source interface {
	Current() state.Merged
}

// HistorySource is optionally implemented by Source (e.g. *state.Poller) to
// provide SQLite time-series queries and host endpoint URL resolution.
type HistorySource interface {
	Store() *store.Store
	Inventory() *inventory.Inventory
	StatusURLFor(host string) (string, bool)
}

// Server is the read-only fleet-edge HTTP handler. It has no POST
// handlers anywhere: every route is a GET that renders inventory plus
// the latest poll data.
type Server struct {
	src        Source
	cfg        Config
	httpClient *http.Client
	mux        *http.ServeMux
}

func isURL(s string) bool {
	return strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://")
}

// New builds a Server backed by src.
func New(src Source, cfg Config) *Server {
	if cfg.Title == "" {
		cfg.Title = "fleet-edge"
	}
	hc := cfg.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 5 * time.Second}
	}
	s := &Server{src: src, cfg: cfg, httpClient: hc, mux: http.NewServeMux()}
	s.mux.HandleFunc("/", s.handleStart)
	s.mux.HandleFunc("/services", s.handleServices)
	s.mux.HandleFunc("/hosts", s.handleHosts)
	s.mux.HandleFunc("/hosts/", s.handleHostDetail)
	s.mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux.HandleFunc("/api/state.json", s.handleAPIState)
	s.mux.HandleFunc("/api/hosts/", s.handleAPIHostSubroute)
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
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
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

func (s *Server) enrichHostCard(ctx context.Context, hv state.HostView, now time.Time) HostCardView {
	card := HostCardView{HostView: hv}
	if hv.Status != nil && hv.Status.System != nil {
		sys := hv.Status.System
		card.UptimeStr = FormatUptime(sys.UptimeSec)
		if sys.MemTotalBytes > 0 {
			card.MemPercent = (float64(sys.MemUsedBytes) / float64(sys.MemTotalBytes)) * 100
			card.MemSummary = fmt.Sprintf("%s / %s", FormatBytes(sys.MemUsedBytes), FormatBytes(sys.MemTotalBytes))
		}
	}

	var cpuVals []float64
	if hs, ok := s.src.(HistorySource); ok && hs.Store() != nil {
		samples, err := hs.Store().QuerySamples(ctx, hv.Host, hv.Replaces, now.Add(-6*time.Hour).Unix(), now.Unix()+60)
		if err == nil && len(samples) > 0 {
			for _, sm := range samples {
				cpuVals = append(cpuVals, sm.CPUPct)
			}
		}
	}
	if len(cpuVals) == 0 && hv.Status != nil && hv.Status.System != nil {
		cpuVals = []float64{hv.Status.System.CPUPercent, hv.Status.System.CPUPercent}
	}
	card.CPUSparkline = RenderSparklineSVG(cpuVals, 100, "var(--accent)")
	return card
}

func (s *Server) handleHosts(w http.ResponseWriter, r *http.Request) {
	m := s.src.Current()
	sort.Slice(m.Hosts, func(i, j int) bool { return m.Hosts[i].Host < m.Hosts[j].Host })
	data := HostsData{Merged: m, Common: s.common("hosts")}
	now := m.GeneratedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}

	for _, hv := range m.Hosts {
		card := s.enrichHostCard(r.Context(), hv, now)
		switch {
		case !hv.HasEndpoint:
			data.OtherHosts = append(data.OtherHosts, card)
		case hv.AlwaysOn:
			data.ServerHosts = append(data.ServerHosts, card)
		default:
			data.WorkstationHosts = append(data.WorkstationHosts, card)
		}
	}
	s.render(w, "hosts.html", data)
}

func parseRangeWindow(rangeKey string) (string, time.Duration) {
	switch rangeKey {
	case "1h":
		return "1h", time.Hour
	case "24h":
		return "24h", 24 * time.Hour
	case "7d":
		return "7d", 7 * 24 * time.Hour
	case "30d":
		return "30d", 30 * 24 * time.Hour
	case "1y":
		return "1y", 365 * 24 * time.Hour
	default:
		return "24h", 24 * time.Hour
	}
}

func (s *Server) handleHostDetail(w http.ResponseWriter, r *http.Request) {
	rawName := strings.TrimPrefix(r.URL.Path, "/hosts/")
	rawName = strings.TrimSuffix(rawName, "/")
	if rawName == "" || strings.Contains(rawName, "/") {
		http.NotFound(w, r)
		return
	}

	// Redirect retired host names (e.g. /hosts/h002 -> /hosts/h004)
	if hs, ok := s.src.(HistorySource); ok && hs.Inventory() != nil {
		if canon := hs.Inventory().CanonicalHost(rawName); canon != rawName {
			target := "/hosts/" + canon
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, target, http.StatusMovedPermanently)
			return
		}
	}

	m := s.src.Current()
	var found *state.HostView
	for i := range m.Hosts {
		if m.Hosts[i].Host == rawName {
			found = &m.Hosts[i]
			break
		}
	}
	if found == nil {
		// Check if any host lists rawName in Replaces even without HistorySource
		for i := range m.Hosts {
			for _, old := range m.Hosts[i].Replaces {
				if old == rawName {
					http.Redirect(w, r, "/hosts/"+m.Hosts[i].Host, http.StatusMovedPermanently)
					return
				}
			}
		}
		http.NotFound(w, r)
		return
	}

	now := m.GeneratedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	rangeKey, win := parseRangeWindow(r.URL.Query().Get("range"))
	sinceTS := now.Add(-win).Unix()
	untilTS := now.Unix()

	card := s.enrichHostCard(r.Context(), *found, now)
	detail := HostDetailData{
		Common:   s.common("hosts"),
		Host:     card,
		RangeKey: rangeKey,
		Ranges:   []string{"1h", "24h", "7d", "30d", "1y"},
	}

	// Collect services on this host and build log viewer options
	for _, svc := range m.Services {
		if svc.DeclaredHost == found.Host {
			detail.Services = append(detail.Services, svc)
			kind := "guest"
			if svc.Kind == "podman" {
				kind = "unit"
			}
			detail.LogTargets = append(detail.LogTargets, LogTargetOption{
				Kind:   kind,
				Target: svc.Name,
				Label:  fmt.Sprintf("%s (%s)", svc.Name, svc.Kind),
			})
		}
	}
	if found.Status != nil {
		var unitNames []string
		for u := range found.Status.HostUnits {
			unitNames = append(unitNames, u)
		}
		sort.Strings(unitNames)
		for _, u := range unitNames {
			detail.HostUnits = append(detail.HostUnits, found.Status.HostUnits[u])
			detail.LogTargets = append(detail.LogTargets, LogTargetOption{
				Kind:   "unit",
				Target: u + ".service",
				Label:  u + ".service (host unit)",
			})
		}
	}
	// Standard allowlisted host units if not already listed
	for _, stdUnit := range []string{"fleet-agent.service", "nginx.service", "fail2ban.service", "sshd.service", "tailscaled.service"} {
		already := false
		for _, lt := range detail.LogTargets {
			if lt.Target == stdUnit {
				already = true
				break
			}
		}
		if !already {
			detail.LogTargets = append(detail.LogTargets, LogTargetOption{
				Kind:   "unit",
				Target: stdUnit,
				Label:  stdUnit + " (host)",
			})
		}
	}

	// Query time-series samples and events
	var samples []store.Sample
	if hs, ok := s.src.(HistorySource); ok && hs.Store() != nil {
		samples, _ = hs.Store().QuerySamples(r.Context(), found.Host, found.Replaces, sinceTS, untilTS)
		detail.Events, _ = hs.Store().QueryEvents(r.Context(), found.Host, found.Replaces)
	}
	if len(samples) == 0 && found.Status != nil && found.Status.System != nil {
		sys := found.Status.System
		samples = []store.Sample{
			{
				Host:     found.Host,
				TS:       now.Unix() - 60,
				CPUPct:   sys.CPUPercent,
				CPUMax:   sys.CPUPercent,
				MemUsed:  sys.MemUsedBytes,
				MemTotal: sys.MemTotalBytes,
				SwapUsed: sys.SwapUsedBytes,
				TempMaxC: found.MaxTempC,
			},
			{
				Host:     found.Host,
				TS:       now.Unix(),
				CPUPct:   sys.CPUPercent,
				CPUMax:   sys.CPUPercent,
				MemUsed:  sys.MemUsedBytes,
				MemTotal: sys.MemTotalBytes,
				SwapUsed: sys.SwapUsedBytes,
				TempMaxC: found.MaxTempC,
			},
		}
	}

	var cpuPts, memPts, netPts, diskPts, tempPts []ChartPoint
	var memMax float64
	for _, sm := range samples {
		cpuPts = append(cpuPts, ChartPoint{TS: sm.TS, Val: sm.CPUPct, Val2: sm.CPUMax})
		memPts = append(memPts, ChartPoint{TS: sm.TS, Val: float64(sm.MemUsed), Val2: float64(sm.SwapUsed)})
		if float64(sm.MemTotal) > memMax {
			memMax = float64(sm.MemTotal)
		}
		netPts = append(netPts, ChartPoint{TS: sm.TS, Val: float64(sm.NetRxBps), Val2: float64(sm.NetTxBps)})
		diskPts = append(diskPts, ChartPoint{TS: sm.TS, Val: float64(sm.DiskRBps), Val2: float64(sm.DiskWBps)})
		tempPts = append(tempPts, ChartPoint{TS: sm.TS, Val: sm.TempMaxC})
	}

	detail.CPUChart = RenderHistoryChartSVG(cpuPts, sinceTS, untilTS, 100, "%", "var(--accent)", "var(--amber)", detail.Events)
	detail.MemChart = RenderHistoryChartSVG(memPts, sinceTS, untilTS, memMax, "B", "var(--green)", "var(--amber)", detail.Events)
	detail.NetChart = RenderHistoryChartSVG(netPts, sinceTS, untilTS, 0, "B/s", "var(--accent)", "var(--green)", detail.Events)
	detail.DiskChart = RenderHistoryChartSVG(diskPts, sinceTS, untilTS, 0, "B/s", "var(--amber)", "var(--red)", detail.Events)
	detail.TempChart = RenderHistoryChartSVG(tempPts, sinceTS, untilTS, 100, "°C", "var(--red)", "", detail.Events)

	// Optional on-demand log tail if ?log_target=... is requested
	detail.SelectedLogKind = r.URL.Query().Get("log_kind")
	detail.SelectedLogTgt = r.URL.Query().Get("log_target")
	detail.SelectedLogLines = r.URL.Query().Get("log_lines")
	if detail.SelectedLogLines == "" {
		detail.SelectedLogLines = "100"
	}
	if detail.SelectedLogTgt != "" {
		if detail.SelectedLogKind == "" {
			detail.SelectedLogKind = "unit"
		}
		entries, err := s.fetchHostLogs(r.Context(), found.Host, detail.SelectedLogKind, detail.SelectedLogTgt, detail.SelectedLogLines)
		if err != nil {
			detail.LogError = err.Error()
		} else {
			detail.LogEntries = entries
		}
	}

	s.render(w, "host_detail.html", detail)
}

func (s *Server) handleAPIHostSubroute(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/hosts/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	host, action := parts[0], parts[1]
	switch action {
	case "logs.json":
		kind := r.URL.Query().Get("kind")
		if kind == "" {
			kind = "unit"
		}
		target := r.URL.Query().Get("target")
		lines := r.URL.Query().Get("lines")
		if lines == "" {
			lines = "200"
		}
		entries, err := s.fetchHostLogs(r.Context(), host, kind, target, lines)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"host":    host,
			"kind":    kind,
			"target":  target,
			"entries": entries,
		})
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) fetchHostLogs(ctx context.Context, host, kind, target, lines string) ([]LogEntryView, error) {
	hs, ok := s.src.(HistorySource)
	if !ok {
		return nil, fmt.Errorf("log proxy unavailable")
	}
	statusURL, ok := hs.StatusURLFor(host)
	if !ok || statusURL == "" {
		return nil, fmt.Errorf("unknown host %q", host)
	}
	logsURL := strings.TrimSuffix(statusURL, "/status.json") + "/logs.json"
	q := url.Values{}
	q.Set("kind", kind)
	q.Set("target", target)
	q.Set("lines", lines)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, logsURL+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("agent returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var payload struct {
		Entries []LogEntryView `json:"entries"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&payload); err != nil {
		return nil, err
	}
	return payload.Entries, nil
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok"))
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
