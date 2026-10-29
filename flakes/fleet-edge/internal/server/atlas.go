package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/geoip"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/timeline"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/topology"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/traffic"
)

// gapTolerance is how much later than Step a sample may arrive before the
// timeline reports the intervening stretch as a recording gap.
const gapTolerance = timeline.Step + timeline.Step/2

// liveJitter is the only leniency live resolution grants: the sampler's ticker
// can fire marginally late, so a snapshot whose window closed up to a second
// ago is still the snapshot covering now. Anything later is a recorder outage
// and is reported as such.
const liveJitter = time.Second

// History is the recorder the atlas endpoints read from. It is satisfied by
// *timeline.Recorder; nil means history is not configured at all.
type History interface {
	Persistent() bool
	Latest(ctx context.Context) (timeline.Snapshot, bool, error)
	At(ctx context.Context, at time.Time) (timeline.Snapshot, bool, error)
	Summaries(ctx context.Context, from, to time.Time) ([]timeline.Sample, error)
	Bounds(ctx context.Context) (first, last time.Time, ok bool, err error)
}

// atlasCoverage is the recorded interval: start is the first capture, end the
type atlasCoverage struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

// geoInfo is the provenance block that must accompany any country answer.
type geoInfo struct {
	Available bool   `json:"available"`
	Estimate  bool   `json:"estimate,omitempty"`
	Source    string `json:"source,omitempty"`
	URL       string `json:"url,omitempty"`
	Note      string `json:"note,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

func (s *Server) geoInfo() geoInfo {
	if s.cfg.GeoIP == nil {
		return geoInfo{Reason: "no offline country database configured"}
	}
	return geoInfo{
		Available: true,
		Estimate:  true,
		Source:    geoip.Source,
		URL:       geoip.URL,
		Note:      geoip.Note,
	}
}

// frameCore is what the frame and traffic endpoints share: the resolved
// snapshot identity and everything derived from it, minus the render.
type frameCore struct {
	Mode               string            `json:"mode"`
	At                 string            `json:"at"`
	SnapshotAt         string            `json:"snapshotAt"`
	Live               bool              `json:"live"`
	Recorded           bool              `json:"recorded"`
	SnapshotAgeSeconds int64             `json:"snapshotAgeSeconds"`
	GapSeconds         int64             `json:"gapSeconds"`
	Coverage           *atlasCoverage    `json:"coverage"`
	Traffic            traffic.Payload   `json:"traffic"`
	Countries          map[string]string `json:"countries"`
}

type frameResponse struct {
	frameCore
	SVG   string  `json:"svg"`
	GeoIP geoInfo `json:"geoip"`
}

type trafficResponse struct {
	frameCore
}

// resolved is one answered request: the snapshot's own state (never the live
// poller's) plus the fields shared by both responses.
type resolved struct {
	core       frameCore
	merged     state.Merged
	snapshotAt time.Time
}

// renderSVG renders the diagram of exactly this snapshot. The error is
// returned rather than flattened to an empty string: an empty frame is
// indistinguishable from "nothing to draw", and silently hiding a template
// failure makes replay debugging impossible.
func (s *Server) renderSVG(r resolved) (string, error) {
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, "topology.svg", topology.Build(s.cfg.Topology, r.merged, r.snapshotAt)); err != nil {
		return "", fmt.Errorf("rendering topology.svg: %w", err)
	}
	return buf.String(), nil
}

type timelineSample struct {
	At string `json:"at"`
	timeline.Summary
}

type timelineGap struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

type timelineResponse struct {
	RetentionSeconds int              `json:"retentionSeconds"`
	StepSeconds      int              `json:"stepSeconds"`
	Persistent       bool             `json:"persistent"`
	Start            *string          `json:"start"`
	End              *string          `json:"end"`
	CoverageStart    *string          `json:"coverageStart"`
	CoverageEnd      *string          `json:"coverageEnd"`
	Samples          []timelineSample `json:"samples"`
	Gaps             []timelineGap    `json:"gaps"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// atlasError writes the uniform error body. coverage is included for
// out-of-coverage answers so the UI can show the recorded range.
func atlasError(w http.ResponseWriter, status int, code, msg string, coverage *atlasCoverage) {
	body := map[string]any{"error": msg, "code": code}
	if coverage != nil {
		body["coverage"] = coverage
	}
	writeJSON(w, status, body)
}

// parseAt accepts RFC3339 or a unix timestamp (seconds).
func parseAt(raw string) (time.Time, error) {
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return time.Unix(n, 0).UTC(), nil
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("bad at: %w", err)
	}
	return t.UTC(), nil
}

func fmtTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// coverage returns the recorded interval, or nil when nothing is recorded.
func (s *Server) coverage(ctx context.Context) (*atlasCoverage, error) {
	if s.cfg.History == nil {
		return nil, nil
	}
	first, last, ok, err := s.cfg.History.Bounds(ctx)
	if err != nil || !ok {
		return nil, err
	}
	return &atlasCoverage{Start: fmtTime(first), End: fmtTime(last.Add(timeline.Step))}, nil
}

// gapSeconds is how far at lies outside the recorded window (0 inside).
func gapSeconds(at time.Time, cov *atlasCoverage) int64 {
	if cov == nil {
		return 0
	}
	start, err1 := time.Parse(time.RFC3339, cov.Start)
	end, err2 := time.Parse(time.RFC3339, cov.End)
	switch {
	case err1 != nil || err2 != nil:
		return 0
	case at.Before(start):
		return int64(start.Sub(at) / time.Second)
	case at.After(end):
		return int64(at.Sub(end) / time.Second)
	}
	return 0
}

// resolve answers "what was the fleet at at?". Live and replay share one rule:
// the request must fall inside the window a snapshot covers. A live request
// past the newest window is a recorder outage, not a reason to keep animating
// the last bucket's remaining seconds.
func (s *Server) resolve(ctx context.Context, atRaw, mode string, full bool) (resolved, int, string) {
	var out resolved
	// ?trafficWindow=full is only meaningful for a replay: a live frame's own
	// window is still running, so handing over all of it would report events
	// for a time that has not happened.
	if full && atRaw == "" {
		return out, http.StatusBadRequest, "bad_request"
	}
	if mode == "" {
		mode = traffic.ModeSimulated
	}
	provider, ok := s.cfg.TrafficProviders.Provider(mode)
	if !ok {
		return out, http.StatusBadRequest, "bad_request"
	}
	rec := s.cfg.History
	if rec == nil {
		return out, http.StatusServiceUnavailable, "recording_unavailable"
	}
	live := atRaw == ""
	at := time.Now().UTC()
	var err error
	if !live {
		at, err = parseAt(atRaw)
		if err != nil {
			return out, http.StatusBadRequest, "bad_request"
		}
	}
	var snap timeline.Snapshot
	if live {
		snap, ok, err = rec.Latest(ctx)
		if err != nil {
			return out, http.StatusInternalServerError, "internal"
		}
		if !ok {
			return out, http.StatusServiceUnavailable, "recording_unavailable"
		}
		// Live answers stay replayable: if the sampler has just ticked past
		// the window edge, report the last covered instant rather than an
		// instant that a replay request would reject as a gap.
		windowEnd := time.Unix(snap.TS, 0).UTC().Add(timeline.Step)
		if at.After(windowEnd.Add(liveJitter)) {
			return out, http.StatusServiceUnavailable, "recording_unavailable"
		}
		if !at.Before(windowEnd) {
			at = windowEnd.Add(-time.Second)
		}
	} else {
		snap, ok, err = rec.At(ctx, at)
		if err != nil {
			return out, http.StatusInternalServerError, "internal"
		}
		if !ok {
			return out, http.StatusNotFound, "no_snapshot"
		}
	}
	if err := json.Unmarshal(snap.State, &out.merged); err != nil {
		return out, http.StatusInternalServerError, "internal"
	}
	cov, err := s.coverage(ctx)
	if err != nil {
		return out, http.StatusInternalServerError, "internal"
	}
	snapshotAt := time.Unix(snap.TS, 0).UTC()
	age := int64(at.Sub(snapshotAt) / time.Second)
	if age < 0 {
		age = 0
	}
	out.snapshotAt = snapshotAt
	out.core = frameCore{
		Mode:               mode,
		At:                 fmtTime(at),
		SnapshotAt:         fmtTime(snapshotAt),
		Live:               live,
		Recorded:           true,
		SnapshotAgeSeconds: age,
		GapSeconds:         gapSeconds(at, cov),
		Coverage:           cov,
		Traffic: provider.Payload(traffic.Snapshot{TS: snap.TS, M: out.merged}, traffic.Frame{
			Bucket: snapshotAt,
			At:     at,
			Step:   timeline.Step,
			Full:   full,
			Limit:  time.Now().UTC(),
		}),
		Countries: s.countries(out.merged),
	}
	return out, http.StatusOK, ""
}

// countries resolves the fail2ban-banned addresses of the snapshot, offline.
// Private, reserved and unknown addresses are omitted rather than guessed.
// Simulation actors are never geolocated.
func (s *Server) countries(m state.Merged) map[string]string {
	out := map[string]string{}
	if s.cfg.GeoIP == nil {
		return out
	}
	for _, ip := range bannedIPs(m) {
		if cc, ok := s.cfg.GeoIP.LookupString(ip); ok {
			out[ip] = cc
		}
	}
	return out
}

// bannedIPs is every address fail2ban reported as banned at snapshot time: the
// per-jail banned lists plus every recent ban event, expired or not. An expired
// ban is still worth mapping: the request that earned it happened while it was
// active, and the frame shows what the host actually reported.
func bannedIPs(m state.Merged) []string {
	seen := map[string]bool{}
	var out []string
	add := func(ip string) {
		ip = strings.TrimSpace(ip)
		if ip == "" || seen[ip] {
			return
		}
		seen[ip] = true
		out = append(out, ip)
	}
	for _, h := range m.Hosts {
		if h.Status == nil || h.Status.Fail2ban == nil {
			continue
		}
		fb := h.Status.Fail2ban
		for _, jail := range fb.Jails {
			for _, ip := range jail.BannedIPs {
				add(ip)
			}
		}
		for _, ev := range fb.RecentBans {
			add(ev.IP)
		}
	}
	sort.Strings(out)
	return out
}

// requestOptions is the shared ?at/?mode/?trafficWindow parsing of the frame
// and traffic handlers.
func requestOptions(r *http.Request) (at, mode string, full bool, ok bool) {
	q := r.URL.Query()
	at, mode = q.Get("at"), q.Get("mode")
	switch q.Get("trafficWindow") {
	case "":
		return at, mode, false, true
	case "full":
		// A live frame's window is still running: asking for all of it would
		// report events beyond the present.
		return at, mode, at != "", at != ""
	default:
		return at, mode, false, false
	}
}

func (s *Server) handleAtlasFrame(w http.ResponseWriter, r *http.Request) {
	at, mode, full, ok := requestOptions(r)
	if !ok {
		s.atlasFailure(w, r, http.StatusBadRequest, "bad_request")
		return
	}
	res, status, code := s.resolve(r.Context(), at, mode, full)
	if status != http.StatusOK {
		s.atlasFailure(w, r, status, code)
		return
	}
	svg, err := s.renderSVG(res)
	if err != nil {
		atlasError(w, http.StatusInternalServerError, "render_failed", err.Error(), nil)
		return
	}
	writeJSON(w, http.StatusOK, frameResponse{frameCore: res.core, SVG: svg, GeoIP: s.geoInfo()})
}

func (s *Server) handleAtlasTraffic(w http.ResponseWriter, r *http.Request) {
	at, mode, full, ok := requestOptions(r)
	if !ok {
		s.atlasFailure(w, r, http.StatusBadRequest, "bad_request")
		return
	}
	res, status, code := s.resolve(r.Context(), at, mode, full)
	if status != http.StatusOK {
		s.atlasFailure(w, r, status, code)
		return
	}
	writeJSON(w, http.StatusOK, trafficResponse{frameCore: res.core})
}

// atlasFailure turns a resolution failure into the documented body.
func (s *Server) atlasFailure(w http.ResponseWriter, r *http.Request, status int, code string) {
	coverage, err := s.coverage(r.Context())
	if err != nil {
		status, code = http.StatusInternalServerError, "internal"
	}
	switch code {
	case "bad_request":
		atlasError(w, status, code, "at must be RFC3339 or a unix timestamp, mode simulated or real", nil)
	case "no_snapshot":
		atlasError(w, status, code, "no snapshot covers that time", coverage)
	case "recording_unavailable":
		atlasError(w, status, code, "no recorded snapshot covers that time; recording is not running or the sample is missing", coverage)
	default:
		atlasError(w, status, code, "topology history query failed", nil)
	}
}

func (s *Server) handleAtlasTimeline(w http.ResponseWriter, r *http.Request) {
	hours := 24
	if raw := r.URL.Query().Get("hours"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil {
			atlasError(w, http.StatusBadRequest, "bad_request", "hours must be an integer 1..24", nil)
			return
		}
		hours = min(max(n, 1), 24)
	}
	resp := timelineResponse{
		RetentionSeconds: int(timeline.Retention / time.Second),
		StepSeconds:      int(timeline.Step / time.Second),
		Persistent:       s.cfg.History != nil && s.cfg.History.Persistent(),
		Samples:          []timelineSample{},
		Gaps:             []timelineGap{},
	}
	if s.cfg.History == nil {
		writeJSON(w, http.StatusOK, resp)
		return
	}
	ctx := r.Context()
	first, last, ok, err := s.cfg.History.Bounds(ctx)
	if err != nil {
		atlasError(w, http.StatusInternalServerError, "internal", "topology history query failed", nil)
		return
	}
	if !ok {
		writeJSON(w, http.StatusOK, resp)
		return
	}
	now := time.Now().UTC()
	windowStart := now.Add(-time.Duration(hours) * time.Hour)
	if windowStart.Before(first) {
		windowStart = first
	}
	samples, err := s.cfg.History.Summaries(ctx, windowStart, now)
	if err != nil {
		atlasError(w, http.StatusInternalServerError, "internal", "topology history query failed", nil)
		return
	}
	start, end := fmtTime(windowStart), fmtTime(now)
	resp.Start, resp.End = &start, &end
	covStart, covEnd := fmtTime(first), fmtTime(last.Add(timeline.Step))
	resp.CoverageStart, resp.CoverageEnd = &covStart, &covEnd
	for _, sm := range samples {
		resp.Samples = append(resp.Samples, timelineSample{At: fmtTime(sm.At), Summary: sm.Summary})
	}
	// A stretch with no capture between two samples is a gap: the recorder was
	// stopped, so nothing was observed there.
	cursor := windowStart
	for _, sm := range samples {
		if sm.At.Sub(cursor) > gapTolerance {
			resp.Gaps = append(resp.Gaps, timelineGap{
				Start: fmtTime(cursor.Add(timeline.Step)),
				End:   fmtTime(sm.At),
			})
		}
		cursor = sm.At
	}
	if now.Sub(cursor) > gapTolerance {
		resp.Gaps = append(resp.Gaps, timelineGap{
			Start: fmtTime(cursor.Add(timeline.Step)),
			End:   fmtTime(now),
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// snapshotSVG answers /topology.svg?at=: the diagram of a recorded snapshot,
// never the current one. ok=false means the caller should render live.
func (s *Server) snapshotSVG(w http.ResponseWriter, r *http.Request) bool {
	atRaw := r.URL.Query().Get("at")
	if atRaw == "" {
		return false
	}
	// The SVG is the cursor's health, never a traffic window expansion.
	res, status, code := s.resolve(r.Context(), atRaw, traffic.ModeSimulated, false)
	if status != http.StatusOK {
		s.atlasFailure(w, r, status, code)
		return true
	}
	svg, err := s.renderSVG(res)
	if err != nil {
		atlasError(w, http.StatusInternalServerError, "render_failed", err.Error(), nil)
		return true
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(svg))
	return true
}
