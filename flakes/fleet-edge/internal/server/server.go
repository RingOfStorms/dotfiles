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
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/geoip"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/topology"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/traffic"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*
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
	// OverridesURL is fleet-edge-overrides' read-only loopback export
	// (/internal/overrides.json). "" hides the section. The dashboard has
	// no token and no write path: it only GETs this URL.
	OverridesURL string
	// PlacementsURL is the placement registry's read-only loopback export
	// (/internal/placements.json). It is the source of truth for which host a
	// service is bound to; "" means "no registry", so every service is
	// unplaced. Left nil-empty (unset) the state layer falls back to the Nix
	// declaration for tests that predate the registry.
	PlacementsURL string
	// Topology is the hand-written part of /topology (validated by the
	// caller); nil means topology.Default().
	Topology *topology.Spec
	// History records topology snapshots for the atlas replay endpoints.
	// nil disables history: those endpoints report "unavailable" instead of
	// pretending to have recorded anything.
	History History
	// TrafficProviders are the traffic modes the atlas may answer for. nil
	// means the default registry (deterministic simulation plus an explicit
	// "real traffic is not connected" answer); an entry can be swapped for a
	// measured provider without touching the API.
	TrafficProviders traffic.Registry
	// GeoIP is the offline country database for banned addresses; nil means
	// no country answers at all.
	GeoIP *geoip.DB
}

// ExposeRow is one public expose override on /services (from the export).
type ExposeRow struct {
	Service   string `json:"service"`
	Route     string `json:"route"`
	Host      string `json:"host"`
	FQDN      string `json:"fqdn"`
	Until     int64  `json:"until"`
	State     string `json:"state"`
	DNS       string `json:"dns"`
	Edge      bool   `json:"edge"`
	Device    string `json:"device"`
	User      string `json:"user"`
	LastError string `json:"lastError"`
	Left      string `json:"-"`
}

// fetchOverrides GETs the export (short timeout; errors shown, not fatal).
func (s *Server) fetchOverrides(ctx context.Context, now time.Time) ([]ExposeRow, string) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.cfg.OverridesURL, nil)
	if err != nil {
		return nil, err.Error()
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, "fleet-edge-overrides unreachable"
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "fleet-edge-overrides: " + resp.Status
	}
	var e struct {
		Rows []ExposeRow `json:"rows"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&e); err != nil {
		return nil, "bad export: " + err.Error()
	}
	for i := range e.Rows {
		r := &e.Rows[i]
		switch d := time.Unix(r.Until, 0).Sub(now).Round(time.Second); {
		case r.Until == 0:
			r.Left = "forever (no expiry)"
		case d <= 0:
			r.Left = "expired (removal pending)"
		default:
			r.Left = d.String()
		}
	}
	return e.Rows, ""
}

// fetchPlacements GETs the registry export (short timeout; errors reported,
// not fatal) and returns the host each service is bound to: a row's effective
// host, so a move in flight reports its source and a stale row reports
// nothing. The map is never nil.
func (s *Server) fetchPlacements(ctx context.Context) (map[string]string, string) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.cfg.PlacementsURL, nil)
	if err != nil {
		return map[string]string{}, err.Error()
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return map[string]string{}, "fleet-edge-placements unreachable"
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return map[string]string{}, "fleet-edge-placements: " + resp.Status
	}
	var e placements.Export
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&e); err != nil {
		return map[string]string{}, "bad export: " + err.Error()
	}
	if e.Host == nil {
		e.Host = map[string]string{}
	}
	return e.Host, ""
}

// Merged renders the state with placement bindings applied. The registry
// export is cached for placementsTTL so a burst of renders costs one loopback
// GET; a failed refresh keeps the last good map, because a registry hiccup
// must not blank every service at once. With no registry configured, and
// before one has ever answered, no service has a row, so none is placed.
// A Source that cannot take a binding keeps the declarative hosts, which is
// the state layer's own fallback for "no registry at all".
func (s *Server) Merged(ctx context.Context) state.Merged {
	if s.cfg.PlacementsURL == "" {
		if bs, ok := s.src.(BoundSource); ok {
			return bs.CurrentBound(map[string]string{})
		}
		return s.src.Current()
	}
	return s.bound(ctx)
}

// bound merges with the cached registry binding, refreshing it if stale.
func (s *Server) bound(ctx context.Context) state.Merged {
	bs, ok := s.src.(BoundSource)
	if !ok {
		return s.src.Current()
	}
	s.regMu.Lock()
	reg, at := s.reg, s.regAt
	s.regMu.Unlock()
	if time.Since(at) > placementsTTL {
		// Fetch outside the lock: a slow registry must not serialize the
		// renders that are already holding a snapshot. A failed attempt
		// still stamps regAt, so an outage costs one GET per TTL rather
		// than one per page view.
		fresh, err := s.fetchPlacements(ctx)
		s.regMu.Lock()
		s.regAt = time.Now()
		if err == "" {
			reg, s.reg = fresh, fresh
		}
		s.regMu.Unlock()
	}
	if reg == nil {
		// Registered but never answered: no rows are known, so nothing is
		// bound. Guessing from the Nix declaration would reinstate exactly
		// the shadow placement this registry replaces.
		reg = map[string]string{}
	}
	return bs.CurrentBound(reg)
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
	// Expose overrides (public cnt expose), when OverridesURL is set.
	ExposeEnabled bool
	Expose        []ExposeRow
	ExposeError   string
}

// HostCardView wraps state.HostView with pre-rendered sparklines and formatted summary fields.
type HostCardView struct {
	state.HostView
	CPUSparkline template.HTML
	MemPercent   float64
	MemSummary   string
	UptimeStr    string
	NetRxBps     uint64
	NetTxBps     uint64
	DiskReadBps  uint64
	DiskWriteBps uint64
}

// HostsData is the view model for hosts.html.
type HostsData struct {
	state.Merged
	Common
	Hosts           []HostCardView
	PolledTotal     int
	ReachableCount  int
	SleepingCount   int
	UnreachableHost int
}

// TopologyData is the view model for topology.html.
type TopologyData struct {
	Common
	Diagram                        topology.Diagram
	Layers                         []topology.Layer
	Polled, Online, Sleeping, Down int
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

// BoundSource is optionally implemented by Source (e.g. *state.Poller) to
// merge with an explicit placement binding. Without it the server can only
// render the declarative state, which is what the tests exercise.
type BoundSource interface {
	CurrentBound(bound map[string]string) state.Merged
}

// HistorySource is optionally implemented by Source (e.g. *state.Poller) to
// provide SQLite time-series queries and host endpoint URL resolution.
type HistorySource interface {
	Store() *store.Store
	Inventory() *inventory.Inventory
	StatusURLFor(host string) (string, bool)
}

// placementsTTL is how long a fetched registry export is reused. The registry
// sweeps every 30 s, so a fresh read every 10 s is well inside one sweep while
// keeping the loopback GET off the render path.
const placementsTTL = 10 * time.Second

// Server is the read-only fleet-edge HTTP handler. It has no POST
// handlers anywhere: every route is a GET that renders inventory plus
// the latest poll data.
type Server struct {
	src        Source
	cfg        Config
	httpClient *http.Client
	mux        *http.ServeMux

	// reg is the last good placement export (service -> effective host);
	// nil until the first successful fetch. Published maps are never
	// mutated, so readers may use them after the lock is dropped.
	regMu sync.Mutex
	reg   map[string]string
	regAt time.Time // when a fetch last succeeded or failed
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
	if cfg.Topology == nil {
		cfg.Topology = topology.Default()
	}
	if cfg.TrafficProviders == nil {
		cfg.TrafficProviders = traffic.DefaultRegistry(cfg.Topology.Hubs.Router)
	}
	s := &Server{src: src, cfg: cfg, httpClient: hc, mux: http.NewServeMux()}
	s.mux.HandleFunc("/", s.handleStart)
	s.mux.HandleFunc("/services", s.handleServices)
	s.mux.HandleFunc("/hosts", s.handleHosts)
	s.mux.HandleFunc("/hosts/", s.handleHostDetail)
	s.mux.HandleFunc("/topology", s.handleTopology)
	s.mux.HandleFunc("/topology.svg", s.handleTopologySVG)
	s.mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux.HandleFunc("/api/state.json", s.handleAPIState)
	s.mux.HandleFunc("/api/hosts/", s.handleAPIHostSubroute)
	s.mux.HandleFunc("/api/topology/timeline", s.handleAtlasTimeline)
	s.mux.HandleFunc("/api/topology/frame", s.handleAtlasFrame)
	s.mux.HandleFunc("/api/topology/traffic", s.handleAtlasTraffic)
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
	m := s.Merged(r.Context())
	data := StartData{
		Common:      s.common("start"),
		Groups:      dash.Build(m, s.cfg.Links, s.cfg.IconBase),
		GeneratedAt: m.GeneratedAt.Format("2006-01-02 15:04:05 UTC"),
	}
	data.HostsTotal, data.HostsUp = hostCounts(m)
	s.render(w, "start.html", data)
}

func (s *Server) handleServices(w http.ResponseWriter, r *http.Request) {
	m := s.Merged(r.Context())
	// Unplaced services sort first: "" is not an error, it is where a
	// service with no row lives.
	sort.Slice(m.Services, func(i, j int) bool {
		if m.Services[i].BoundHost != m.Services[j].BoundHost {
			return m.Services[i].BoundHost < m.Services[j].BoundHost
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
	if s.cfg.OverridesURL != "" {
		data.ExposeEnabled = true
		data.Expose, data.ExposeError = s.fetchOverrides(r.Context(), time.Now())
	}
	s.render(w, "services.html", data)
}

func (s *Server) enrichHostCard(ctx context.Context, hv state.HostView, now time.Time) HostCardView {
	card := HostCardView{HostView: hv}
	if hv.Status != nil {
		if hv.Status.System != nil {
			sys := hv.Status.System
			card.UptimeStr = FormatUptime(sys.UptimeSec)
			if sys.MemTotalBytes > 0 {
				card.MemPercent = (float64(sys.MemUsedBytes) / float64(sys.MemTotalBytes)) * 100
				card.MemSummary = fmt.Sprintf("%s / %s", FormatBytes(sys.MemUsedBytes), FormatBytes(sys.MemTotalBytes))
			}
		}
		for name, nio := range hv.Status.NetIO {
			if strings.HasPrefix(name, "lo") || strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "ve-") || strings.HasPrefix(name, "br-") || strings.HasPrefix(name, "podman") || strings.HasPrefix(name, "docker") {
				continue
			}
			card.NetRxBps += nio.RxBytesPerSec
			card.NetTxBps += nio.TxBytesPerSec
		}
		for _, dio := range hv.Status.DiskIO {
			card.DiskReadBps += dio.ReadBytesPerSec
			card.DiskWriteBps += dio.WriteBytesPerSec
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
	m := s.Merged(r.Context())
	sort.Slice(m.Hosts, func(i, j int) bool { return m.Hosts[i].Host < m.Hosts[j].Host })
	data := HostsData{Merged: m, Common: s.common("hosts")}
	now := m.GeneratedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}

	for _, hv := range m.Hosts {
		card := s.enrichHostCard(r.Context(), hv, now)
		data.Hosts = append(data.Hosts, card)
		if hv.HasEndpoint {
			data.PolledTotal++
			switch {
			case hv.Reachable:
				data.ReachableCount++
			case hv.StateBadge == "sleeping":
				data.SleepingCount++
			default:
				data.UnreachableHost++
			}
		}
	}
	s.render(w, "hosts.html", data)
}

func (s *Server) diagram(ctx context.Context) topology.Diagram {
	m := s.Merged(ctx)
	now := m.GeneratedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	return topology.Build(s.cfg.Topology, m, now)
}

func (s *Server) handleTopology(w http.ResponseWriter, r *http.Request) {
	d := s.diagram(r.Context())
	data := TopologyData{Common: s.common("topology"), Diagram: d, Layers: topology.Layers}
	// Counted over the drawn hosts, the same way topology.js recounts
	// after each live refresh.
	for _, n := range d.Nodes {
		switch n.State {
		case "online":
			data.Online++
		case "sleeping":
			data.Sleeping++
		case "down":
			data.Down++
		default:
			continue
		}
		data.Polled++
	}
	s.render(w, "topology.html", data)
}

// handleTopologySVG serves the diagram alone: a self-contained download and
// the source topology.js swaps in for live status. With ?at= it replays the
// recorded snapshot of that instant, never the current one.
func (s *Server) handleTopologySVG(w http.ResponseWriter, r *http.Request) {
	if s.snapshotSVG(w, r) {
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := tmpl.ExecuteTemplate(w, "topology.svg", s.diagram(r.Context())); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
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

	m := s.Merged(r.Context())
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

	// Collect services bound to this host and build log viewer options. An
	// unplaced service binds nowhere, so it belongs on no host page.
	for _, svc := range m.Services {
		if svc.BoundHost != "" && svc.BoundHost == found.Host {
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
	m := s.Merged(r.Context())
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(m); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
