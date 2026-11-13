package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func strp(s string) *string { return &s }

type fakeSource struct {
	m state.Merged
}

func (f fakeSource) Current() state.Merged { return f.m }

func sample() state.Merged {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"photos": {
				Name: "photos", Kind: "nixos", Description: "immich",
				Routes: map[string]inventory.Route{
					"web": {FQDN: strp("photos.joshuabell.xyz"), URL: strp("https://photos.joshuabell.xyz"), Exposure: "public", Auth: strp("native"), Via: []string{"edge"}},
				},
			},
		},
		Hosts: map[string]inventory.Host{
			"h001": {User: "root"},
			"gp3":  {User: "josh"},
		},
		ContainerHosts: []string{"h001"},
	}
	polls := map[string]state.HostPoll{
		"h001": {Host: "h001", OK: true, PolledAt: time.Now()},
	}
	return state.Merge(inv, polls, map[string]string{"photos": "h001"})
}

func TestHandleIndexRenders(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/services", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	body := w.Body.String()
	if !strings.Contains(body, "photos") || !strings.Contains(body, "photos.joshuabell.xyz") {
		t.Fatalf("expected body to mention photos route, got: %s", body)
	}
}

func TestServicesShowsCertificateExpiry(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{Certificates: func() []state.Certificate {
		return []state.Certificate{{URL: "https://photos.example.com", Expires: time.Date(2026, 11, 5, 0, 0, 0, 0, time.UTC), Expiring: true}}
	}})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services?tab=tls", nil))
	for _, text := range []string{"TLS certificates", "https://photos.example.com", "2026-11-05", "expires in under 14 days"} {
		if !strings.Contains(w.Body.String(), text) {
			t.Fatalf("missing %q: %s", text, w.Body.String())
		}
	}
}

func TestHandleHosts(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/hosts", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), "h001") {
		t.Fatalf("expected body to mention h001, got: %s", w.Body.String())
	}
}

func TestHandleHealthz(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Fatalf("unexpected healthz response: %d %s", w.Code, w.Body.String())
	}
}

func TestHandleAPIStateJSON(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/api/state.json", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	var got state.Merged
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if len(got.Services) != 1 || got.Services[0].Name != "photos" {
		t.Fatalf("unexpected api state: %+v", got)
	}
}

func TestTopologyRoutesAreNotServed(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	for _, path := range []string{"/topology", "/topology.svg", "/api/topology/frame", "/api/topology/timeline", "/api/topology/traffic", "/static/topology.js"} {
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404", path, w.Code)
		}
	}
}

func TestStaticStyleCSSServed(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	req := httptest.NewRequest(http.MethodGet, "/static/style.css", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	ct := w.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/css") {
		t.Fatalf("expected text/css content type, got %q", ct)
	}
	if !strings.Contains(w.Body.String(), "--bg") {
		t.Fatalf("expected stylesheet body, got: %s", w.Body.String())
	}
}

func TestHostsNoEndpointNotCounted(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts", nil))
	body := w.Body.String()
	if !strings.Contains(body, "no endpoint") || strings.Contains(body, "pill-unreachable") {
		t.Fatalf("expected gp3 as no endpoint and nothing unreachable, got: %s", body)
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	if !strings.Contains(w.Body.String(), "<strong>1</strong>/<strong>1</strong> hosts reachable") {
		t.Fatalf("expected 1/1 hosts reachable, got: %s", w.Body.String())
	}
}

func TestStartPageTilesAndIcons(t *testing.T) {
	cfg := Config{
		Title: "Josh's Homelab",
		Links: []dash.Link{
			{Name: "Photos", URL: "https://photos.joshuabell.xyz", Icon: "immich", Group: "Photos & Docs"},
			{Name: "Radarr", URL: "http://h001:7878", Group: "Media"},
		},
	}
	srv := New(fakeSource{m: sample()}, cfg)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
	body := w.Body.String()
	for _, want := range []string{
		"Photos &amp; Docs",
		"https://cdn.jsdelivr.net/gh/selfhst/icons/svg/immich.svg",
		`<span class="letter">R</span>`,
		"dot-unknown",
		"Josh&#39;s Homelab",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("start page missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, `class="bg"`) {
		t.Fatal("no background configured, but bg div rendered")
	}
}

func TestBackgroundURL(t *testing.T) {
	srv := New(fakeSource{m: sample()}, Config{Background: "https://example.com/bg.png"})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
	if !strings.Contains(w.Body.String(), "https://example.com/bg.png") {
		t.Fatalf("expected background URL, got %s", w.Body.String())
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/assets/bg", nil))
	if w.Code == http.StatusOK {
		t.Fatal("/assets/bg should not be served for a URL background")
	}
}

func TestBackgroundFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bg.svg")
	if err := os.WriteFile(p, []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := New(fakeSource{m: sample()}, Config{Background: p})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts", nil))
	if !strings.Contains(w.Body.String(), "/assets/bg") || strings.Contains(w.Body.String(), p) {
		t.Fatalf("expected /assets/bg reference (not the path), got %s", w.Body.String())
	}
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/assets/bg", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "<svg") {
		t.Fatalf("/assets/bg = %d %s", w.Code, w.Body.String())
	}
}

func TestServicesShowBackupAge(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"fresh": {Name: "fresh", Kind: "nixos"},
			"old":   {Name: "old", Kind: "nixos"},
			"never": {Name: "never", Kind: "nixos"},
		},
		Hosts: map[string]inventory.Host{"h001": {User: "root"}},
	}
	now := time.Now().UTC()
	polls := map[string]state.HostPoll{"h001": {Host: "h001", OK: true, PolledAt: now, Status: &state.HostStatus{Services: map[string]state.ServiceStatus{
		"fresh": {Active: "active", LastBackup: now.Add(-5 * time.Hour).Format(time.RFC3339)},
		"old":   {Active: "active", LastBackup: now.Add(-50 * time.Hour).Format(time.RFC3339)},
		"never": {Active: "active"},
	}}}}
	srv := New(fakeSource{m: state.Merge(inv, polls, map[string]string{"fresh": "h001", "old": "h001", "never": "h001"})}, Config{})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	body := w.Body.String()
	for _, want := range []string{"5h ago", "stale · 2d 2h", ">never<", "1</strong> backups stale"} {
		if !strings.Contains(body, want) {
			t.Errorf("services page lacks %q", want)
		}
	}
	// state API carries it too
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/state.json", nil))
	if !strings.Contains(w.Body.String(), `"backup": "stale"`) {
		t.Errorf("state.json lacks backup state: %s", w.Body.String())
	}
}

func TestHostDetailAndBcachefsDrillDown(t *testing.T) {
	alwaysFalse := false
	inv := &inventory.Inventory{
		Hosts: map[string]inventory.Host{
			"h004": {User: "luser", OverlayIP: strp("100.64.0.17"), Role: "server", Replaces: []string{"h002"}},
			"oren": {User: "josh", OverlayIP: strp("100.64.0.2"), Role: "laptop", AlwaysOn: &alwaysFalse},
		},
		AgentHosts: []string{"h004", "oren"},
	}
	now := time.Now().UTC()
	polls := map[string]state.HostPoll{
		"h004": {
			Host:     "h004",
			OK:       true,
			PolledAt: now,
			Status: &state.HostStatus{
				Host: "h004",
				Time: now.Format(time.RFC3339),
				System: &state.SystemMetrics{
					Kernel:        "6.18.55",
					UptimeSec:     86400,
					Load1:         0.42,
					Load5:         0.38,
					Load15:        0.31,
					CPUPercent:    14.5,
					MemTotalBytes: 64_000_000_000,
					MemUsedBytes:  16_000_000_000,
				},
				Filesystems: []state.FilesystemMount{
					{
						Mount:       "/data",
						FSType:      "bcachefs",
						TotalBytes:  25_000_000_000_000,
						UsedBytes:   10_000_000_000_000,
						UsedPercent: 40.0,
						Bcachefs: &state.BcachefsInfo{
							RawCapacityBytes: 50_000_000_000_000,
							RawUsedBytes:     20_000_000_000_000,
							UsableTotalBytes: 25_000_000_000_000,
							UsableUsedBytes:  10_000_000_000_000,
							DataReplicas:     2,
							MetadataReplicas: 2,
							Devices: []state.BcachefsDevice{
								{Name: "sda", Label: "hdd.0", State: "rw", SizeBytes: 12_000_000_000_000, UsedBytes: 5_000_000_000_000},
							},
						},
					},
				},
				Smart: []state.SmartDrive{
					{Device: "/dev/sda", Model: "ST12000NT001", Healthy: true, TempC: 34, PowerOnHours: 12000},
				},
				Fail2ban: &state.Fail2banSummary{
					Jails: []state.Fail2banJail{{Name: "sshd", CurrentlyBanned: 1, TotalBanned: 5}},
				},
			},
		},
		"oren": {
			Host:     "oren",
			OK:       false,
			Error:    "timeout",
			PolledAt: now,
		},
	}

	srv := New(fakeSource{m: state.Merge(inv, polls, nil)}, Config{})

	// 1. /hosts shows bcachefs usable vs raw and oren as sleep / offline
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("/hosts status = %d", w.Code)
	}
	hostsBody := w.Body.String()
	for _, want := range []string{"<table class=\"hosts-table\">", "load 0.42 / 0.38 / 0.31", "10.0 TB / 25.0 TB usable (40%) · 2x", "raw pool: 20.0 TB / 50.0 TB", "sleep / offline", "← h002"} {
		if !strings.Contains(hostsBody, want) {
			t.Fatalf("/hosts missing %q:\n%s", want, hostsBody)
		}
	}
	for _, unwanted := range []string{"Always-On Servers", "Workstations &amp; Laptops", "Other Inventory Hosts"} {
		if strings.Contains(hostsBody, unwanted) {
			t.Fatalf("/hosts still contains category header %q:\n%s", unwanted, hostsBody)
		}
	}

	// 2. /hosts/h002 redirects to /hosts/h004
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts/h002", nil))
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "/hosts/h004" {
		t.Fatalf("expected 301 redirect /hosts/h002 -> /hosts/h004, got %d (%s)", w.Code, w.Header().Get("Location"))
	}

	// 3. /hosts/h004 renders drill-down charts, bcachefs devices, SMART, fail2ban, and log controls
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/hosts/h004?range=7d", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("/hosts/h004 status = %d: %s", w.Code, w.Body.String())
	}
	detailBody := w.Body.String()
	for _, want := range []string{
		"ST12000NT001",
		"hdd.0",
		"sshd",
		"history-chart",
		`viewBox="0 0 640 210"`,
		"chart-legend",
		"RX (in)",
		"TX (out)",
		"RAM Used",
		"Swap Used",
		"Systemd &amp; Container Logs",
	} {
		if !strings.Contains(detailBody, want) {
			t.Fatalf("/hosts/h004 missing %q:\n%s", want, detailBody)
		}
	}
}

func TestServicesExposeSection(t *testing.T) {
	now := time.Now().Unix()
	var method string
	exp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method = r.Method
		_, _ = w.Write([]byte(`{"rows":[{"service":"app","route":"web","host":"h001","fqdn":"app.example.com","until":0,"state":"committed","dns":"ok","edge":true,"device":"lio"},{"service":"b","route":"web","host":"h001","fqdn":"b.example.com","until":` + strconv.FormatInt(now+3600, 10) + `,"state":"removing","dns":"mismatch","edge":false,"lastError":"boom"}],"owned":[]}`))
	}))
	defer exp.Close()
	inv := &inventory.Inventory{Services: map[string]inventory.Service{}, Hosts: map[string]inventory.Host{}}
	srv := New(fakeSource{m: state.Merge(inv, nil, nil)}, Config{OverridesURL: exp.URL})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services?tab=expose", nil))
	body := w.Body.String()
	for _, want := range []string{"app.example.com", "forever (no expiry)", "removing", "mismatch", ">missing<", "lio"} {
		if !strings.Contains(body, want) {
			t.Errorf("services page lacks %q", want)
		}
	}
	if method != http.MethodGet {
		t.Errorf("export called with %s", method)
	}
	// Export down: page still renders, with the error.
	exp.Close()
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services?tab=expose", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "unreachable") {
		t.Errorf("down: %d", w.Code)
	}
	// Unset: no section.
	srv = New(fakeSource{m: state.Merge(inv, nil, nil)}, Config{})
	w = httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	if strings.Contains(w.Body.String(), "Expose overrides") {
		t.Error("section shown without OverridesURL")
	}
}

func TestServicesBackupsRendersLowTrustHistory(t *testing.T) {
	now := time.Now().UTC()
	local, oldLocal := int64(10<<20), int64(1<<20)
	e := backup.Export{
		Rows: []*backup.Row{{Subject: "canary", Target: "h004", RetentionLocal: "standard", RetentionB2: "local"}},
		Targets: []backup.TargetView{
			{Target: backup.Target{ID: "h004", Enabled: true, Seen: now.Unix(), Stats: map[string]backup.Stats{
				"canary": {LocalBytes: &local, At: now.Unix()},
			}}},
			{Target: backup.Target{ID: "h009", Enabled: true, Seen: now.Add(-24 * time.Hour).Unix(), Stats: map[string]backup.Stats{
				"canary": {LocalBytes: &oldLocal, At: now.Add(-24 * time.Hour).Unix(), WrittenBy: backup.WrittenByLow},
			}}, Stale: true},
		},
		Subjects:  []string{"canary", "forgejo", "unknown"},
		WrittenBy: map[string]string{"forgejo": backup.WrittenByLow, "retired": backup.WrittenByLow},
	}
	export := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(e); err != nil {
			t.Error(err)
		}
	}))
	defer export.Close()
	srv := New(fakeSource{m: sample()}, Config{BackupURL: export.URL})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services?tab=backups", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	page := w.Body.String()
	if !strings.Contains(page, "Read-only summary") || strings.Contains(page, "<form") {
		t.Fatalf("backups summary is not read-only:\n%s", page)
	}
	const warning = `<span class="warn" title="writtenBy: low; possible low-trust data in repository history">low-trust history</span>`
	if strings.Count(page, warning) != 3 {
		t.Errorf("want exactly three low-trust subject warnings:\n%s", page)
	}
	for _, tc := range []struct {
		subject string
		low     bool
	}{
		{"canary", true},
		{"forgejo", true},
		{"retired", true},
		{"unknown", false},
	} {
		var row string
		for _, candidate := range strings.Split(page, "</tr>") {
			if strings.Contains(candidate, "<td>"+tc.subject) {
				row = candidate
				break
			}
		}
		if row == "" {
			t.Fatalf("subject %q missing from rendered backups table:\n%s", tc.subject, page)
		}
		if strings.Contains(row, warning) != tc.low {
			t.Errorf("%s low-trust warning = %t, want %t:\n%s", tc.subject, strings.Contains(row, warning), tc.low, row)
		}
		if !tc.low && (strings.Contains(row, "writtenBy:") || strings.Contains(row, "low-trust history")) {
			t.Errorf("unknown subject has a provenance warning:\n%s", row)
		}
		if tc.subject == "canary" && (!strings.Contains(row, "10.0 MiB") || strings.Contains(row, "1.0 MiB")) {
			t.Errorf("warning displaced selected holder's newer size:\n%s", row)
		}
		if (tc.subject == "forgejo" || tc.subject == "retired") && strings.Count(row, `<td title="">-</td>`) != 2 {
			t.Errorf("provenance-only subject has invented sizes:\n%s", row)
		}
		if tc.subject == "retired" && !strings.Contains(row, "not in inventory") {
			t.Errorf("provenance-only retired subject lacks inventory warning:\n%s", row)
		}
	}
}

// boundSource is a Source that also merges a supplied binding, like
// *state.Poller does in production.
type boundSource struct {
	inv *inventory.Inventory
}

func (b boundSource) Current() state.Merged { return state.Merge(b.inv, nil, nil) }
func (b boundSource) CurrentBound(bound map[string]string) state.Merged {
	return state.Merge(b.inv, nil, bound)
}

func TestServicesBoundHostFromRegistry(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"photos":    {Name: "photos", Kind: "nixos"},
			"orphan":    {Name: "orphan", Kind: "nixos"},
			"elsewhere": {Name: "elsewhere", Kind: "nixos"},
		},
		Hosts: map[string]inventory.Host{"h001": {User: "root"}},
	}
	calls := 0
	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		_, _ = w.Write([]byte(`{"rows":[],"host":{"photos":"h001","elsewhere":"h003"}}`))
	}))
	defer reg.Close()
	srv := New(boundSource{inv: inv}, Config{PlacementsURL: reg.URL})

	render := func() string {
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d", w.Code)
		}
		return w.Body.String()
	}
	page := render()
	// Grouped by the registry's binding, with a row-less service under
	// "unplaced" and never an empty header.
	for _, want := range []string{`<td colspan="7">unplaced</td>`, `<td colspan="7">h001</td>`, `<td colspan="7">h003</td>`} {
		if !strings.Contains(page, want) {
			t.Errorf("services page lacks %q", want)
		}
	}
	if strings.Contains(page, `<td colspan="7"></td>`) {
		t.Error("services page rendered an empty host group header")
	}
	// The export is cached, not refetched on every render.
	render()
	if calls != 1 {
		t.Errorf("registry fetched %d times for two renders", calls)
	}

	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/state.json", nil))
	if !strings.Contains(w.Body.String(), `"boundHost": ""`) {
		t.Errorf("state.json lacks the unplaced service: %s", w.Body.String())
	}
}

func TestServicesNoRegistryMeansUnplaced(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{"photos": {Name: "photos", Kind: "nixos"}},
		Hosts:    map[string]inventory.Host{"h001": {User: "root"}},
	}
	srv := New(boundSource{inv: inv}, Config{})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	if body := w.Body.String(); !strings.Contains(body, `<td colspan="7">unplaced</td>`) {
		t.Errorf("services page without a registry lacks the unplaced group:\n%s", body)
	}
}

func TestServicesUnreachableRegistryIsUnplaced(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{"photos": {Name: "photos", Kind: "nixos"}},
		Hosts:    map[string]inventory.Host{"h001": {User: "root"}},
	}
	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := reg.URL
	reg.Close()
	srv := New(boundSource{inv: inv}, Config{PlacementsURL: url})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/services", nil))
	body := w.Body.String()
	// A registry that never answered has no rows, so nothing is bound.
	if !strings.Contains(body, `<td colspan="7">unplaced</td>`) {
		t.Errorf("unreachable registry fell back to the declaration:\n%s", body)
	}
	if strings.Contains(body, `<td colspan="7">h001</td>`) {
		t.Error("unreachable registry rendered the declared host")
	}
}
