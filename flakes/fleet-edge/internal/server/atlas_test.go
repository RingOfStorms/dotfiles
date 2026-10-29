package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/geoip"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/timeline"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/traffic"
)

// fakeHistory is an in-memory History implementation with explicit control of
// capture times, so gap and coverage boundaries are testable exactly.
type fakeHistory struct {
	snaps []timeline.Snapshot
	err   error
}

func (f *fakeHistory) Persistent() bool { return false }

func (f *fakeHistory) Latest(context.Context) (timeline.Snapshot, bool, error) {
	if f.err != nil {
		return timeline.Snapshot{}, false, f.err
	}
	if len(f.snaps) == 0 {
		return timeline.Snapshot{}, false, nil
	}
	return f.snaps[len(f.snaps)-1], true, nil
}

func (f *fakeHistory) At(_ context.Context, at time.Time) (timeline.Snapshot, bool, error) {
	if f.err != nil {
		return timeline.Snapshot{}, false, f.err
	}
	ts := at.Unix()
	var best timeline.Snapshot
	found := false
	for _, s := range f.snaps {
		if s.TS <= ts {
			best, found = s, true
		}
	}
	if !found || ts-best.TS >= int64(timeline.Step/time.Second) {
		return timeline.Snapshot{}, false, nil
	}
	return best, true, nil
}

func (f *fakeHistory) Summaries(_ context.Context, from, to time.Time) ([]timeline.Sample, error) {
	if f.err != nil {
		return nil, f.err
	}
	var out []timeline.Sample
	for _, s := range f.snaps {
		if s.TS >= from.Unix() && s.TS <= to.Unix() {
			out = append(out, timeline.Sample{At: time.Unix(s.TS, 0).UTC(), Summary: s.Summary})
		}
	}
	return out, nil
}

func (f *fakeHistory) Bounds(context.Context) (time.Time, time.Time, bool, error) {
	if f.err != nil {
		return time.Time{}, time.Time{}, false, f.err
	}
	if len(f.snaps) == 0 {
		return time.Time{}, time.Time{}, false, nil
	}
	return time.Unix(f.snaps[0].TS, 0).UTC(),
		time.Unix(f.snaps[len(f.snaps)-1].TS, 0).UTC(), true, nil
}

// snapshotAt builds a recorded snapshot of sample() stamped at ts.
func snapshotAt(t *testing.T, ts time.Time) timeline.Snapshot {
	t.Helper()
	doc, err := json.Marshal(sample())
	if err != nil {
		t.Fatal(err)
	}
	return timeline.Snapshot{
		TS:      ts.Unix(),
		State:   doc,
		Summary: timeline.Summarize(sample()),
	}
}

func atlasServer(t *testing.T, snaps ...timeline.Snapshot) *Server {
	t.Helper()
	h := &fakeHistory{snaps: snaps}
	return New(fakeSource{m: sample()}, Config{History: h})
}

func getJSON(t *testing.T, srv *Server, path string, status int, v any) {
	t.Helper()
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	if w.Code != status {
		t.Fatalf("GET %s = %d, want %d (%s)", path, w.Code, status, w.Body.String())
	}
	if v != nil {
		if err := json.Unmarshal(w.Body.Bytes(), v); err != nil {
			t.Fatalf("GET %s: decode: %v (%s)", path, err, w.Body.String())
		}
	}
}

type errBody struct {
	Error string `json:"error"`
	Code  string `json:"code"`
}

func TestAtlasFrameReplaysRecordedSnapshot(t *testing.T) {
	captured := time.Now().UTC().Add(-10 * time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, captured))
	at := captured.Add(12 * time.Second).Format(time.RFC3339)

	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame?at="+at, http.StatusOK, &frame)
	if !frame.Recorded {
		t.Error("frame is not marked recorded")
	}
	if frame.SnapshotAt != captured.Format(time.RFC3339) {
		t.Errorf("snapshotAt = %q, want %q", frame.SnapshotAt, captured.Format(time.RFC3339))
	}
	if frame.SnapshotAgeSeconds != 12 {
		t.Errorf("snapshotAgeSeconds = %d, want 12", frame.SnapshotAgeSeconds)
	}
	if frame.GapSeconds != 0 {
		t.Errorf("gapSeconds = %d, want 0 inside coverage", frame.GapSeconds)
	}
	if !strings.Contains(frame.SVG, "<svg") {
		t.Error("frame has no SVG")
	}
	if !frame.Traffic.Simulated || !frame.Traffic.Available {
		t.Errorf("traffic = %+v, want available simulated payload", frame.Traffic)
	}
}

func TestAtlasFrameGapIs404NeverOlderSnapshot(t *testing.T) {
	captured := time.Now().UTC().Add(-10 * time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, captured))
	// Exactly one Step later: the window [captured, captured+30s) has closed.
	at := captured.Add(timeline.Step).Format(time.RFC3339)
	var body errBody
	getJSON(t, srv, "/api/topology/frame?at="+at, http.StatusNotFound, &body)
	if body.Code != "no_snapshot" {
		t.Errorf("code = %q, want no_snapshot", body.Code)
	}
	// One second earlier still belongs to the snapshot.
	inside := captured.Add(timeline.Step - time.Second).Format(time.RFC3339)
	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame?at="+inside, http.StatusOK, &frame)
	if frame.SnapshotAt != captured.Format(time.RFC3339) {
		t.Errorf("snapshotAt = %q, want %q", frame.SnapshotAt, captured.Format(time.RFC3339))
	}
}

func TestAtlasFrameUnavailableWithoutHistory(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	var body errBody
	getJSON(t, srv, "/api/topology/frame", http.StatusServiceUnavailable, &body)
	if body.Code != "recording_unavailable" {
		t.Errorf("code = %q, want recording_unavailable", body.Code)
	}
}

func TestAtlasLiveFrameStaleIs503(t *testing.T) {
	stale := time.Now().UTC().Add(-5 * time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, stale))
	var body errBody
	getJSON(t, srv, "/api/topology/frame", http.StatusServiceUnavailable, &body)
	if body.Code != "recording_unavailable" {
		t.Errorf("code = %q, want recording_unavailable", body.Code)
	}
}

func TestAtlasLiveFrameWithinWindow(t *testing.T) {
	fresh := time.Now().UTC().Add(-2 * time.Second).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, fresh))
	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame", http.StatusOK, &frame)
	if !frame.Live || !frame.Recorded {
		t.Errorf("live=%v recorded=%v, want both true", frame.Live, frame.Recorded)
	}
	// A live answer must stay replayable at the instant it reported.
	var replay frameResponse
	getJSON(t, srv, "/api/topology/frame?at="+frame.At, http.StatusOK, &replay)
	if replay.SnapshotAt != frame.SnapshotAt {
		t.Errorf("replay snapshotAt = %q, live was %q", replay.SnapshotAt, frame.SnapshotAt)
	}
}

func TestAtlasRealModeNeverSimulates(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, captured))
	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame?mode=real&at="+captured.Format(time.RFC3339), http.StatusOK, &frame)
	if frame.Traffic.Available || frame.Traffic.Simulated {
		t.Errorf("real mode available=%v simulated=%v, want false/false", frame.Traffic.Available, frame.Traffic.Simulated)
	}
	if frame.Traffic.Reason == "" {
		t.Error("real mode has no reason")
	}
	if len(frame.Traffic.Events) != 0 {
		t.Errorf("real mode invented %d events", len(frame.Traffic.Events))
	}
	if !strings.Contains(frame.SVG, "<svg") {
		t.Error("real mode frame has no SVG")
	}
}

func TestAtlasBadModeAndAt(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute)
	srv := atlasServer(t, snapshotAt(t, captured))
	for _, path := range []string{
		"/api/topology/frame?mode=bogus",
		"/api/topology/frame?at=not-a-time",
	} {
		var body errBody
		getJSON(t, srv, path, http.StatusBadRequest, &body)
		if body.Code != "bad_request" {
			t.Errorf("%s: code = %q, want bad_request", path, body.Code)
		}
	}
}

func TestAtlasTrafficIsDeterministic(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, captured))
	// The last covered second, so every event of the bucket is behind cut.
	at := captured.Add(timeline.Step - time.Second).Format(time.RFC3339)
	var first, second trafficResponse
	getJSON(t, srv, "/api/topology/traffic?at="+at, http.StatusOK, &first)
	getJSON(t, srv, "/api/topology/traffic?at="+at, http.StatusOK, &second)
	// Requests may arrive in the same second and interleave; compare IDs.
	if len(first.Traffic.Events) == 0 {
		t.Fatal("no simulated events for an online host with a public route")
	}
	for _, ev := range first.Traffic.Events {
		if !strings.HasPrefix(ev.ID, "sim-") {
			t.Errorf("event id %q is not namespaced as simulated", ev.ID)
		}
		if !strings.HasPrefix(ev.At, captured.Format("2006-01-02T15:04")) {
			continue // formatting check below
		}
	}
	ids := func(p traffic.Payload) string {
		var b strings.Builder
		for _, ev := range p.Events {
			b.WriteString(ev.ID)
			b.WriteByte(',')
		}
		return b.String()
	}
	if ids(first.Traffic) != ids(second.Traffic) {
		t.Errorf("traffic differs between identical requests:\n%s\n%s", ids(first.Traffic), ids(second.Traffic))
	}
}

func TestAtlasTrafficOmitsSVG(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute)
	srv := atlasServer(t, snapshotAt(t, captured))
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/topology/traffic?at="+captured.Format(time.RFC3339), nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"svg", "geoip"} {
		if _, ok := raw[key]; ok {
			t.Errorf("traffic response unexpectedly carries %q", key)
		}
	}
	if _, ok := raw["traffic"]; !ok {
		t.Error("traffic response has no traffic")
	}
}

func TestAtlasTimelineGaps(t *testing.T) {
	base := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	snaps := []timeline.Snapshot{
		snapshotAt(t, base),
		snapshotAt(t, base.Add(timeline.Step)),
		// A 10 minute hole, then recording resumes.
		snapshotAt(t, base.Add(10*time.Minute)),
	}
	srv := atlasServer(t, snaps...)
	var resp timelineResponse
	getJSON(t, srv, "/api/topology/timeline?hours=1", http.StatusOK, &resp)
	if len(resp.Samples) != 3 {
		t.Fatalf("samples = %d, want 3", len(resp.Samples))
	}
	// One interior gap (the 10 minute hole) plus the trailing gap of a
	// recorder that stopped 50 minutes ago: recording is not running now.
	if len(resp.Gaps) != 2 {
		t.Fatalf("gaps = %+v, want an interior and a trailing gap", resp.Gaps)
	}
	interior := resp.Gaps[0]
	if interior.Start != base.Add(2*timeline.Step).Format(time.RFC3339) ||
		interior.End != base.Add(10*time.Minute).Format(time.RFC3339) {
		t.Errorf("interior gap = %+v", interior)
	}
	if resp.Gaps[1].Start != base.Add(10*time.Minute+timeline.Step).Format(time.RFC3339) {
		t.Errorf("trailing gap = %+v", resp.Gaps[1])
	}
	if resp.CoverageStart == nil || *resp.CoverageStart != base.Format(time.RFC3339) {
		t.Errorf("coverageStart = %v", resp.CoverageStart)
	}
}

func TestAtlasTimelineEmpty(t *testing.T) {
	srv := atlasServer(t)
	var resp timelineResponse
	getJSON(t, srv, "/api/topology/timeline", http.StatusOK, &resp)
	if resp.Start != nil || resp.CoverageStart != nil {
		t.Errorf("empty history reports bounds: %+v", resp)
	}
	if resp.Samples == nil || resp.Gaps == nil {
		t.Error("empty history must encode [] not null")
	}
	if resp.StepSeconds != int(timeline.Step/time.Second) || resp.RetentionSeconds != int(timeline.Retention/time.Second) {
		t.Errorf("step/retention = %d/%d", resp.StepSeconds, resp.RetentionSeconds)
	}
}

func TestAtlasTimelineHoursValidation(t *testing.T) {
	srv := atlasServer(t)
	var body errBody
	getJSON(t, srv, "/api/topology/timeline?hours=abc", http.StatusBadRequest, &body)
	if body.Code != "bad_request" {
		t.Errorf("code = %q", body.Code)
	}
	var resp timelineResponse
	getJSON(t, srv, "/api/topology/timeline?hours=999", http.StatusOK, &resp)
}

func TestTopologySVGReplayNeverServesLive(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	srv := atlasServer(t, snapshotAt(t, captured))
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/topology.svg?at="+captured.Format(time.RFC3339), nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d (%s)", w.Code, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "image/svg+xml") {
		t.Errorf("content-type = %q", ct)
	}
	if !strings.Contains(w.Body.String(), "<svg") {
		t.Error("no SVG body")
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/topology.svg?at="+captured.Add(time.Hour).Format(time.RFC3339), nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("out-of-coverage svg = %d, want 404", w.Code)
	}
	if strings.Contains(w.Body.String(), "<svg") {
		t.Error("out-of-coverage svg returned a diagram")
	}
}

func TestAtlasCountriesUseBannedAddresses(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dbip.csv")
	if err := os.WriteFile(path, []byte("ip_start,ip_end,country\n8.8.8.0,8.8.8.255,US\n1.1.1.0,1.1.1.255,AU\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := geoip.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	merged := sample()
	fb := &state.Fail2banSummary{
		Jails: []state.Fail2banJail{{Name: "sshd", BannedIPs: []string{"8.8.8.8", "10.0.0.9"}}},
		RecentBans: []state.Fail2banBanEvent{
			{Jail: "nginx", IP: "1.1.1.1", Active: false},
		},
	}
	for i := range merged.Hosts {
		if merged.Hosts[i].Host == "h001" {
			s := merged.Hosts[i].Status
			if s == nil {
				s = &state.HostStatus{Host: "h001"}
			}
			s.Fail2ban = fb
			merged.Hosts[i].Status = s
		}
	}
	got := (&Server{cfg: Config{GeoIP: db}}).countries(merged)
	want := map[string]string{"8.8.8.8": "US", "1.1.1.1": "AU"}
	if len(got) != len(want) {
		t.Fatalf("countries = %v, want %v (private address must be omitted)", got, want)
	}
	for ip, cc := range want {
		if got[ip] != cc {
			t.Errorf("%s = %q, want %q", ip, got[ip], cc)
		}
	}
	if _, ok := got["10.0.0.9"]; ok {
		t.Error("private address was geolocated")
	}
}

func TestAtlasFrameGeoIPUnavailableWithoutDatabase(t *testing.T) {
	captured := time.Now().UTC().Add(-time.Minute)
	srv := atlasServer(t, snapshotAt(t, captured))
	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame?at="+captured.Format(time.RFC3339), http.StatusOK, &frame)
	if frame.GeoIP.Available {
		t.Error("geoip reported available without a database")
	}
	if frame.GeoIP.Reason == "" {
		t.Error("geoip has no reason without a database")
	}
	if frame.Countries == nil || len(frame.Countries) != 0 {
		t.Errorf("countries = %v, want empty", frame.Countries)
	}
}

func TestAtlasFrameGeoIPMetadataWithDatabase(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dbip.csv")
	if err := os.WriteFile(path, []byte("8.8.8.0,8.8.8.255,US\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := geoip.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	captured := time.Now().UTC().Add(-time.Minute)
	srv := New(fakeSource{m: sample()}, Config{
		History: &fakeHistory{snaps: []timeline.Snapshot{snapshotAt(t, captured)}},
		GeoIP:   db,
	})
	var frame frameResponse
	getJSON(t, srv, "/api/topology/frame?at="+captured.Format(time.RFC3339), http.StatusOK, &frame)
	if !frame.GeoIP.Available || !frame.GeoIP.Estimate {
		t.Errorf("available=%v estimate=%v, want true/true", frame.GeoIP.Available, frame.GeoIP.Estimate)
	}
	if frame.GeoIP.Source == "" || frame.GeoIP.Note == "" || frame.GeoIP.URL == "" {
		t.Error("country answer lacks attribution")
	}
}

func TestBannedIPsIncludesExpiredBans(t *testing.T) {
	m := sample()
	for i := range m.Hosts {
		if m.Hosts[i].Host != "h001" {
			continue
		}
		s := m.Hosts[i].Status
		if s == nil {
			s = &state.HostStatus{Host: "h001"}
		}
		s.Fail2ban = &state.Fail2banSummary{
			Jails: []state.Fail2banJail{{Name: "sshd", BannedIPs: []string{"203.0.113.5"}}},
			RecentBans: []state.Fail2banBanEvent{
				{Jail: "sshd", IP: "198.51.100.7", Active: false},
				{Jail: "sshd", IP: "203.0.113.5", Active: true},
			},
		}
		m.Hosts[i].Status = s
	}
	got := bannedIPs(m)
	want := []string{"198.51.100.7", "203.0.113.5"}
	if len(got) != len(want) {
		t.Fatalf("bannedIPs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("bannedIPs[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestGapSeconds(t *testing.T) {
	start := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	cov := &atlasCoverage{Start: start.Format(time.RFC3339), End: start.Add(time.Hour).Format(time.RFC3339)}
	if got := gapSeconds(start.Add(30*time.Minute), cov); got != 0 {
		t.Errorf("inside coverage gapSeconds = %d, want 0", got)
	}
	if got := gapSeconds(start.Add(-90*time.Second), cov); got != 90 {
		t.Errorf("before coverage gapSeconds = %d, want 90", got)
	}
	if got := gapSeconds(start.Add(2*time.Hour), cov); got != 3600 {
		t.Errorf("after coverage gapSeconds = %d, want 3600", got)
	}
	if got := gapSeconds(start, nil); got != 0 {
		t.Errorf("nil coverage gapSeconds = %d, want 0", got)
	}
}

// TestTopologySVGUnchangedWithoutAt guards the plain download path.
func TestTopologySVGUnchangedWithoutAt(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/topology.svg", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "<svg") {
		t.Fatalf("live svg = %d", w.Code)
	}
}

func TestAtlasGeoIPReservedAddresses(t *testing.T) {
	for _, s := range []string{"10.0.0.1", "127.0.0.1", "100.64.0.1", "192.168.1.1", "fd00::1", "fe80::1", "203.0.113.9"} {
		if geoip.Global(netip.MustParseAddr(s)) {
			t.Errorf("%s treated as globally routable", s)
		}
	}
	if !geoip.Global(netip.MustParseAddr("8.8.8.8")) {
		t.Error("8.8.8.8 is not treated as globally routable")
	}
}

func TestTrafficPayloadModesRegistered(t *testing.T) {
	reg := traffic.DefaultRegistry("router")
	for _, mode := range []string{traffic.ModeSimulated, traffic.ModeReal} {
		if _, ok := reg.Provider(mode); !ok {
			t.Errorf("mode %q not registered", mode)
		}
	}
	if got := reg.Modes(); len(got) != 2 {
		t.Errorf("Modes() = %v, want 2 entries", got)
	}
}
