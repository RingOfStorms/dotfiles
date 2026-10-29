package topology

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func strp(s string) *string { return &s }

// at is a fixed clock so ages never depend on wall time.
var at = time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

// testInventory declares:
//
//	h001  container host by service (two services, one public via the edge)
//	h003  container host by containerHosts only, no services at all
//	gp3   polled laptop, no containers
func testInventory() *inventory.Inventory {
	return &inventory.Inventory{
		Services: map[string]inventory.Service{
			"jellyfin": {Name: "jellyfin", Kind: "nixos", Host: "h001", Description: "media"},
			"photos": {
				Name: "photos", Kind: "nixos", Host: "h001",
				Routes: map[string]inventory.Route{
					"web": {Port: 2283, FQDN: strp("photos.example"), Exposure: "public", Via: []string{"edge"}},
				},
			},
		},
		Hosts: map[string]inventory.Host{
			"h001": {OverlayIP: strp("100.64.0.13"), LanIP: strp("10.12.14.5")},
			"h003": {OverlayIP: strp("100.64.0.4")},
			"gp3":  {Role: "laptop", OverlayIP: strp("100.64.0.15")},
		},
		ContainerHosts: []string{"h001", "h003"},
	}
}

func testSpec() *Spec {
	return &Spec{
		Rows: []Row{{Zones: []Zone{
			{ID: "net", Label: "Internet", Kind: "internet", Flex: 1},
			{ID: "fleet", Label: "Fleet", Kind: "rack", Flex: 3},
		}}},
		Nodes: []NodeSpec{
			{ID: "internet", Label: "Internet", Kind: "internet", Zone: "net"},
			{ID: "edge", Label: "Edge proxy", Kind: "cloud", Zone: "net"},
		},
		DefaultZone: "fleet",
		Hubs:        Hubs{Tailnet: "internet", Edge: "edge", Dashboard: "internet"},
	}
}

func testPoll(host string, polledAt time.Time) state.HostPoll {
	return state.HostPoll{
		Host: host, OK: true, PolledAt: polledAt,
		Status: &state.HostStatus{
			Host:     host,
			Services: map[string]state.ServiceStatus{"jellyfin": {Active: "active", Enabled: true}},
			System: &state.SystemMetrics{
				UptimeSec: 3600, CPUPercent: 12.5,
				MemTotalBytes: 8 << 30, MemUsedBytes: 2 << 30,
			},
		},
	}
}

// allPolls makes every host reachable, so the diagram reflects the merge's
// online verdict rather than any notion of poll age.
func allPolls() map[string]state.HostPoll {
	return map[string]state.HostPoll{
		"h001": testPoll("h001", at),
		"h003": testPoll("h003", at),
		"gp3":  testPoll("gp3", at),
	}
}

func nodesByID(d Diagram) map[string]Node {
	out := make(map[string]Node, len(d.Nodes))
	for _, n := range d.Nodes {
		out[n.ID] = n
	}
	return out
}

func infoByID(t *testing.T, d Diagram) map[string]NodeInfo {
	t.Helper()
	out := map[string]NodeInfo{}
	if err := json.Unmarshal([]byte(d.Meta), &out); err != nil {
		t.Fatalf("meta: %v", err)
	}
	return out
}

func edge(t *testing.T, d Diagram, from, to, kind string) Edge {
	t.Helper()
	for _, e := range d.Edges {
		if e.From == from && e.To == to && e.Kind == kind {
			return e
		}
	}
	t.Fatalf("no %s edge %s->%s in %+v", kind, from, to, d.Edges)
	return Edge{}
}

func TestBuildDeclaredContainerHostWithNoContainers(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(testSpec(), m, at)

	n, ok := nodesByID(d)["h003"]
	if !ok {
		t.Fatal("h003 not placed")
	}
	if !n.ContainerHost {
		t.Error("h003 declared in containerHosts must be a container host")
	}
	// A declared host with nothing on it still counts as a container host,
	// but the station stays empty: services belong to the sidebar.
	if n.SvcCount != 0 || n.SvcFailed != 0 {
		t.Errorf("a host with no services must show no service counts: %d/%d", n.SvcCount, n.SvcFailed)
	}
	ni := infoByID(t, d)["h003"]
	if !ni.ContainerHost {
		t.Error("NodeInfo.containerHost must be true for a declared host with no containers")
	}
	if len(ni.Services) != 0 {
		t.Errorf("expected no services, got %+v", ni.Services)
	}
}

func TestBuildContainerHostFromServiceHost(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(testSpec(), m, at)

	n := nodesByID(d)["h001"]
	if !n.ContainerHost {
		t.Fatal("h001 carries declared services, so it is a container host")
	}
	// The station counts its services instead of listing them.
	if n.SvcCount != 2 || n.SvcFailed != 0 {
		t.Fatalf("service counts = %d/%d, want 2/0", n.SvcCount, n.SvcFailed)
	}
	// Container states come from the poll; the unstatused service is unknown.
	ni := infoByID(t, d)["h001"]
	if len(ni.Services) != 2 {
		t.Fatalf("services = %+v", ni.Services)
	}
	states := map[string]string{}
	for _, s := range ni.Services {
		states[s.Name] = s.State
	}
	if states["jellyfin"] != "active" || states["photos"] != "unknown" {
		t.Errorf("service states = %v", states)
	}
}

func TestBuildPollOnlyHostIsNotContainerHost(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(testSpec(), m, at)

	n := nodesByID(d)["gp3"]
	if n.ContainerHost {
		t.Fatal("a host that only answers polls is not a container host")
	}
	if n.SvcCount != 0 {
		t.Errorf("a poll-only host declares no services, got %d", n.SvcCount)
	}
	if infoByID(t, d)["gp3"].ContainerHost {
		t.Error("NodeInfo.containerHost must be false for a poll-only host")
	}
}

func TestBuildEdgesLiveOnlyBetweenPresentNodes(t *testing.T) {
	inv := testInventory()
	polls := allPolls()
	delete(polls, "gp3") // gp3 is now down
	d := Build(testSpec(), state.MergeAt(inv, polls, at), at)

	if e := edge(t, d, "internet", "h001", "agent"); !e.Live {
		t.Error("online host must have a live edge")
	}
	if e := edge(t, d, "internet", "gp3", "agent"); e.Live {
		t.Error("down host must not have a live edge")
	}
	if e := edge(t, d, "internet", "h003", "agent"); !e.Live {
		t.Error("agent edge to an online host must be live")
	}

	nodes := nodesByID(d)
	if !nodes["internet"].live {
		t.Error("static gear is always live")
	}
	if nodes["gp3"].live {
		t.Error("down host must not be live")
	}
	if !nodes["h001"].live {
		t.Error("online host must be live")
	}
}

// Liveness comes from the merge alone: a host with no successful poll is not
// up, and its LAST known numbers are not shown as current readings.
func TestBuildOfflineHostIsNotLiveAndHasNoMetrics(t *testing.T) {
	inv := testInventory()
	d := Build(testSpec(), state.MergeAt(inv, nil, at), at)

	n := nodesByID(d)["h001"]
	if n.live {
		t.Error("a host with no successful poll must not be live")
	}
	if e := edge(t, d, "internet", "h001", "agent"); e.Live {
		t.Error("offline host must not have a live edge")
	}
	for _, l := range infoByID(t, d)["h001"].Lines {
		if strings.Contains(l, "cpu") {
			t.Errorf("offline host metrics reported: %q", l)
		}
	}
}

func TestBuildNodeInfoCarriesFullMetrics(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(testSpec(), m, at)

	if !nodesByID(d)["h001"].live {
		t.Fatal("an online reachable host must be live")
	}
	ni := infoByID(t, d)["h001"]
	if !strings.Contains(strings.Join(ni.Lines, "|"), "cpu 12%") {
		t.Errorf("NodeInfo.Lines lacks the metrics: %+v", ni.Lines)
	}
	if ni.System == nil || ni.System.CPUPercent != 12.5 {
		t.Errorf("NodeInfo.System = %+v", ni.System)
	}
	if n := nodesByID(d)["h001"]; n.Title == "" {
		t.Error("every station carries a title for its tooltip")
	}
	if !strings.Contains(ni.StateText, "up 1h") {
		t.Errorf("state text = %q", ni.StateText)
	}
}

func TestBuildServiceOnDownHostHasNoMetrics(t *testing.T) {
	inv := testInventory()
	d := Build(testSpec(), state.MergeAt(inv, map[string]state.HostPoll{}, at), at)

	ni := infoByID(t, d)["h001"]
	if ni.State != "down" {
		t.Errorf("state = %q", ni.State)
	}
	if len(ni.Lines) != 0 {
		t.Errorf("no poll, no metrics: %+v", ni.Lines)
	}
	// gp3 is a laptop (not always-on): no poll means asleep, not down.
	if got := infoByID(t, d)["gp3"].StateText; got != "asleep / offline" {
		t.Errorf("gp3 state text = %q", got)
	}
}

func TestBuildDerivedEdges(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(testSpec(), m, at)

	edge(t, d, "internet", "h001", "agent")
	edge(t, d, "internet", "h003", "agent")

	// The only derived edges are agent polls. Overlay membership is a station
	// tag and public reach is a journey drawn on demand, so neither is a
	// permanent rail on the map.
	for _, e := range d.Edges {
		if e.Kind != "agent" {
			t.Errorf("derived edge %s->%s is %q, want only agent edges", e.From, e.To, e.Kind)
		}
	}
}

func TestBuildSkipsEmptyHubs(t *testing.T) {
	spec := testSpec()
	spec.Hubs = Hubs{}
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(spec, m, at)
	if len(d.Edges) != 0 {
		t.Fatalf("no hubs, no derived edges: %+v", d.Edges)
	}
}

func TestBuildSkipsLinksToUnknownNodes(t *testing.T) {
	spec := testSpec()
	// A node whose host vanished from the inventory is skipped, as is a link
	// to an id that never existed: no edge may be drawn to nowhere.
	spec.Nodes = append(spec.Nodes, NodeSpec{ID: "ghost", Host: "gone", Zone: "fleet"})
	spec.Links = []LinkSpec{
		{From: "ghost", To: "h001", Kind: "ethernet"},
		{From: "internet", To: "nope", Kind: "wan"},
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at)
	for _, e := range d.Edges {
		if e.From == "ghost" || e.To == "ghost" || e.To == "nope" {
			t.Errorf("edge to an unresolved node drawn: %+v", e)
		}
	}
	if _, ok := nodesByID(d)["ghost"]; ok {
		t.Error("node bound to a vanished host must not be drawn")
	}
}

func TestBuildSkipsNodeWithMissingHostBinding(t *testing.T) {
	spec := &Spec{
		Rows:  []Row{{Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		Nodes: []NodeSpec{{Host: "gone", Zone: "fleet"}},
	}
	m := state.MergeAt(testInventory(), allPolls(), at)
	d := Build(spec, m, at)
	if len(d.Nodes) != 0 {
		t.Fatalf("node bound to a vanished host must be skipped: %+v", d.Nodes)
	}
	if d.Meta != "{}" {
		t.Errorf("meta = %q", d.Meta)
	}
}

func TestBuildStaticNodeWithoutLabelFallsBackToID(t *testing.T) {
	spec := &Spec{
		Rows:  []Row{{Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		Nodes: []NodeSpec{{ID: "switch", Zone: "fleet"}},
	}
	d := Build(spec, state.MergeAt(testInventory(), nil, at), at)
	if len(d.Nodes) != 1 || d.Nodes[0].Label != "switch" {
		t.Fatalf("nodes = %+v", d.Nodes)
	}
}

func TestBuildDegenerateLayoutStaysSane(t *testing.T) {
	spec := testSpec()
	spec.Width = 0
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at)
	if d.Width != DefaultWidth {
		t.Errorf("width = %d, want %d", d.Width, DefaultWidth)
	}
	if d.Height < minZoneH {
		t.Errorf("height = %d", d.Height)
	}
	for _, n := range d.Nodes {
		if n.W <= 0 || n.H <= 0 {
			t.Errorf("node %s has degenerate box %dx%d", n.ID, n.W, n.H)
		}
	}
	for _, z := range d.Zones {
		if z.W < MinWidth || z.H <= 0 {
			t.Errorf("zone %s has box %dx%d narrower than %d", z.ID, z.W, z.H, MinWidth)
		}
	}

	// A row with no zones contributes nothing to the layout.
	spec.Rows = append([]Row{{}}, spec.Rows...)
	if got := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at); got.Height != d.Height {
		t.Errorf("empty row changed height: %d vs %d", got.Height, d.Height)
	}
}

func TestBuildNodesFitTheirZone(t *testing.T) {
	spec := &Spec{
		Width:       MinWidth,
		Rows:        []Row{{Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		DefaultZone: "fleet",
	}
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at)
	if len(d.Nodes) != 3 {
		t.Fatalf("expected the three hosts placed, got %+v", d.Nodes)
	}
	z := d.Zones[0]
	inner := z.W - 2*zonePad
	for _, n := range d.Nodes {
		if n.W <= 0 || n.W > inner {
			t.Errorf("node %s width %d outside 1..%d", n.ID, n.W, inner)
		}
		if n.H <= 0 {
			t.Errorf("node %s height %d", n.ID, n.H)
		}
		if n.DotX >= n.W {
			t.Errorf("node %s status dot at %d, width %d", n.ID, n.DotX, n.W)
		}
		if n.X+n.W > z.X+z.W {
			t.Errorf("node %s right edge %d past zone right edge %d", n.ID, n.X+n.W, z.X+z.W)
		}
	}
}

func TestValidate(t *testing.T) {
	inv := testInventory()
	valid := func() *Spec { return testSpec() }
	// tenZones builds one row of ten equal zones, which cannot each get
	// MinWidth out of a MinWidth-wide diagram.
	tenZones := func(s *Spec) {
		zones := make([]Zone, 10)
		for i := range zones {
			zones[i] = Zone{ID: string(rune('a' + i)), Flex: 1}
		}
		s.Width = MinWidth
		s.Rows = []Row{{Zones: zones}}
		s.Nodes = nil
		s.DefaultZone = ""
		s.Hubs = Hubs{}
	}

	cases := []struct {
		name    string
		mutate  func(*Spec)
		wantErr string
	}{
		{"valid", func(s *Spec) {}, ""},
		{"zero width falls back to the default", func(s *Spec) { s.Width = 0 }, ""},
		{"negative width", func(s *Spec) { s.Width = -10 }, "negative"},
		{"valid at the default width", func(s *Spec) { s.Width = DefaultWidth }, ""},
		{"ten zones at the minimum width", tenZones, fmt.Sprintf("minimum %d", MinWidth)},
		{"two zones at the minimum width", func(s *Spec) {
			s.Width = MinWidth
			s.Rows[0].Zones = []Zone{{ID: "net", Flex: 1}, {ID: "fleet", Flex: 1}}
		}, fmt.Sprintf("minimum %d", MinWidth)},
		{"flex starves a zone", func(s *Spec) {
			s.Rows[0].Zones = []Zone{{ID: "net", Flex: 50}, {ID: "fleet", Flex: 1}}
		}, `zone "fleet"`},
		{"no zones", func(s *Spec) { s.Rows = nil }, "no zones"},
		{"empty zone id", func(s *Spec) { s.Rows[0].Zones[0].ID = "" }, "empty id"},
		{"duplicate zone", func(s *Spec) { s.Rows[0].Zones[1].ID = "net" }, "duplicate zone"},
		{"negative flex", func(s *Spec) { s.Rows[0].Zones[0].Flex = -1 }, "negative flex"},
		{"unknown default zone", func(s *Spec) { s.DefaultZone = "nowhere" }, "defaultZone"},
		{"node without id or host", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{Zone: "fleet"}) }, "neither id nor host"},
		{"duplicate node", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{ID: "edge", Zone: "net"}) }, "duplicate node"},
		{"unknown zone", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{ID: "x", Zone: "nowhere"}) }, "unknown zone"},
		{"unknown host", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{ID: "x", Host: "ghost", Zone: "fleet"}) }, "unknown inventory host"},
		{"host placed twice", func(s *Spec) {
			s.Nodes = append(s.Nodes, NodeSpec{ID: "x", Host: "h001", Zone: "fleet"}, NodeSpec{ID: "y", Host: "h001", Zone: "fleet"})
		}, "placed twice"},
		{"default zone id collides with host", func(s *Spec) {
			s.Nodes = append(s.Nodes, NodeSpec{ID: "h003", Label: "h003", Zone: "fleet"})
		}, "collides"},
		{"unknown link kind", func(s *Spec) {
			s.Links = append(s.Links, LinkSpec{From: "internet", To: "edge", Kind: "smoke-signal"})
		}, "unknown kind"},
		{"link to unknown node", func(s *Spec) {
			s.Links = append(s.Links, LinkSpec{From: "internet", To: "ghost", Kind: "wan"})
		}, "unknown node"},
		{"self loop", func(s *Spec) {
			s.Links = append(s.Links, LinkSpec{From: "edge", To: "edge", Kind: "wan"})
		}, "self-loop"},
		{"unknown hub", func(s *Spec) { s.Hubs.Edge = "ghost" }, "hubs.edge"},
		{"hidden host not auto-placed", func(s *Spec) { s.Hide = []string{"h003"} }, ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := valid()
			tc.mutate(s)
			err := s.Validate(inv)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err, tc.wantErr)
			}
		})
	}
}

// Every zone Validate accepts is wide enough that layout's own split agrees.
func TestValidateZoneWidthsMatchLayout(t *testing.T) {
	spec := testSpec()
	spec.Width = DefaultWidth
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at)
	widths := zoneWidths(spec.Rows[0], spec.Width)
	if len(d.Zones) != len(widths) {
		t.Fatalf("zones = %d, widths = %d", len(d.Zones), len(widths))
	}
	for i, z := range d.Zones {
		if z.W != widths[i] || z.W < MinWidth {
			t.Errorf("zone %s drawn %d wide, validated %d (minimum %d)", z.ID, z.W, widths[i], MinWidth)
		}
	}
}

func TestValidateHiddenHostIsNotDrawn(t *testing.T) {
	spec := testSpec()
	spec.Hide = []string{"h003"}
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at), at)
	if _, ok := nodesByID(d)["h003"]; ok {
		t.Fatal("hidden host must not be auto-placed")
	}
}

func TestBuildEmptySpec(t *testing.T) {
	d := Build(&Spec{}, state.Merged{}, at)
	if d.Width != DefaultWidth || d.Height < minZoneH {
		t.Fatalf("empty spec diagram = %dx%d", d.Width, d.Height)
	}
	if len(d.Nodes) != 0 || len(d.Edges) != 0 {
		t.Fatalf("empty spec drew content: %+v", d)
	}
	if d.Meta != "{}" {
		t.Errorf("meta = %q", d.Meta)
	}
}

// serviceInventory declares one host whose three services reach it three
// different ways: public through the edge, public through the router, and
// host-only. An unplaced service is declared too and must attach to no station.
func serviceInventory() *inventory.Inventory {
	return &inventory.Inventory{
		Services: map[string]inventory.Service{
			"media": {Name: "media", Kind: "nixos", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 443, Proto: "https", FQDN: strp("media.example"), Exposure: "public", Via: []string{"edge"}},
			}},
			"router-ui": {Name: "router-ui", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 8443, Exposure: "public", Via: []string{"router"}},
			}},
			"vault": {Name: "vault", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 8200, Exposure: "local"},
			}},
			"stray": {Name: "stray", Routes: map[string]inventory.Route{
				"web": {Port: 9000, Exposure: "public", Via: []string{"edge"}},
			}},
		},
		Hosts: map[string]inventory.Host{"h004": {OverlayIP: strp("100.64.0.44")}},
	}
}

// A public route is public only where it genuinely enters from the internet:
// through the edge hub, or through the router when that is what terminates it.
func TestServiceExposureAndRouteOrigin(t *testing.T) {
	spec := &Spec{DefaultZone: "fleet", Nodes: []NodeSpec{{ID: "edge", Label: "Edge", Kind: "cloud", Zone: "fleet"}}}
	d := Build(spec, state.MergeAt(serviceInventory(), map[string]state.HostPoll{}, at), at)

	svcs := map[string]ServiceInfo{}
	for _, s := range infoByID(t, d)["h004"].Services {
		svcs[s.Name] = s
	}
	if len(svcs) != 3 {
		t.Fatalf("services = %+v", svcs)
	}
	if media := svcs["media"]; !media.Public || media.ViaRouter {
		t.Errorf("edge-terminated public route = %+v", media)
	}
	if router := svcs["router-ui"]; router.Public || !router.ViaRouter {
		t.Errorf("router-terminated public route = %+v", router)
	}
	if vault := svcs["vault"]; vault.Public || vault.ViaRouter || vault.Exposure != "local" {
		t.Errorf("host-only route = %+v", vault)
	}
	for _, s := range svcs {
		if s.Name == "stray" {
			t.Error("a service with no declared host must not attach to a station")
		}
	}
}

// The station counts services, not containers: a station with two of three
// services down shows 3/1 without listing a single name.
func TestStationServiceCountsAndFailure(t *testing.T) {
	inv := serviceInventory()
	poll := state.HostPoll{
		Host: "h004", OK: true, PolledAt: at,
		Status: &state.HostStatus{
			Host: "h004",
			Services: map[string]state.ServiceStatus{
				"media":     {Active: "active", Enabled: true},
				"router-ui": {Active: "failed", Enabled: true},
				"vault":     {Active: "inactive", Enabled: false},
			},
		},
	}
	d := Build(&Spec{DefaultZone: "fleet"}, state.MergeAt(inv, map[string]state.HostPoll{"h004": poll}, at), at)

	n := nodesByID(d)["h004"]
	if n.SvcCount != 3 || n.SvcFailed != 2 {
		t.Fatalf("station counts = %d services, %d failing", n.SvcCount, n.SvcFailed)
	}
	if n.Warn != 0 {
		t.Errorf("stopped services are not disk warnings: %d", n.Warn)
	}
	ni := infoByID(t, d)["h004"]
	if ni.SvcFailed != 2 {
		t.Errorf("NodeInfo.SvcFailed = %d", ni.SvcFailed)
	}
}

// driveUnhealthy is the single shared rule behind the station badge, the
// sidebar pill and the history strip: standby is never a fault, every defect
// counter is, and a worn-out drive is.
func TestDriveUnhealthyPredicate(t *testing.T) {
	cases := []struct {
		name string
		drv  state.SmartDrive
		want bool
	}{
		{"healthy", state.SmartDrive{Healthy: true}, false},
		{"healthy with counters of zero", state.SmartDrive{Healthy: true, TempC: 41}, false},
		{"standby and unreadable", state.SmartDrive{Standby: true, Healthy: false, PendingSectors: 4}, false},
		{"failed verdict", state.SmartDrive{Healthy: false}, true},
		{"pending sectors", state.SmartDrive{Healthy: true, PendingSectors: 1}, true},
		{"uncorrectable", state.SmartDrive{Healthy: true, UncorrectableErrors: 2}, true},
		{"media errors", state.SmartDrive{Healthy: true, MediaErrors: 1}, true},
		{"reallocated", state.SmartDrive{Healthy: true, ReallocatedSectors: 8}, true},
		{"worn out", state.SmartDrive{Healthy: true, WearPercentUsed: 100}, true},
		{"worn but usable", state.SmartDrive{Healthy: true, WearPercentUsed: 99}, false},
	}
	for _, c := range cases {
		if got := driveUnhealthy(c.drv); got != c.want {
			t.Errorf("%s: driveUnhealthy = %v, want %v", c.name, got, c.want)
		}
	}
}

// diskProblems counts a drive once and a pool once, however many submounts
// report it, and never counts a spun-down drive or a healthy array.
func TestDiskProblemsCountsEachPoolOnce(t *testing.T) {
	degraded := func(mount string) state.FilesystemMount {
		return state.FilesystemMount{Mount: mount, FSType: "bcachefs", Bcachefs: &state.BcachefsInfo{
			UUID: "pool-a", Degraded: true,
			Devices: []state.BcachefsDevice{{Name: "sda", IOErrorsRead: 3}},
		}}
	}
	st := &state.HostStatus{
		Smart: []state.SmartDrive{
			{Device: "/dev/sda", Healthy: true},
			{Device: "/dev/sdb", Healthy: true, PendingSectors: 2},
			{Device: "/dev/sdc", Standby: true, Healthy: false, MediaErrors: 5},
		},
		Filesystems: []state.FilesystemMount{
			degraded("/mnt/a"),
			degraded("/mnt/a/sub"),
			{Mount: "/", FSType: "ext4"},
			{Mount: "/mnt/ok", FSType: "bcachefs", Bcachefs: &state.BcachefsInfo{UUID: "pool-b"}},
		},
	}
	// One bad drive plus one pool reported by two submounts.
	if got := diskProblems(st); got != 2 {
		t.Fatalf("diskProblems = %d, want 2", got)
	}
	if got := diskProblems(&state.HostStatus{}); got != 0 {
		t.Errorf("an empty status has no problems, got %d", got)
	}
}

// The station is fixed size and its head, icon, dot and counter baselines all
// stay inside the box, whatever the label length.
func TestStationGeometryStaysInsideTheBox(t *testing.T) {
	inv := serviceInventory()
	inv.Hosts["h004"] = inventory.Host{OverlayIP: strp("100.64.0.44")}
	spec := &Spec{
		Width:       DefaultWidth,
		Rows:        []Row{{Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		DefaultZone: "fleet",
		Nodes: []NodeSpec{{
			Host: "h004", Label: "A very long station label that would overflow", Zone: "fleet",
			Badges: []string{"tailnet", "VLAN 20"},
		}},
	}
	d := Build(spec, state.MergeAt(inv, map[string]state.HostPoll{}, at), at)

	n := nodesByID(d)["h004"]
	if n.W != stationW || n.H != stationH {
		t.Fatalf("station = %dx%d, want %dx%d", n.W, n.H, stationW, stationH)
	}
	inside := func(name string, x, y int) {
		if x < 0 || x > n.W || y < 0 || y > n.H {
			t.Errorf("%s (%d,%d) is outside the %dx%d station", name, x, y, n.W, n.H)
		}
	}
	inside("head", n.HeadX, n.HeadY)
	inside("icon", n.IconX, n.IconY)
	inside("dot", n.DotX, n.HeadY)
	inside("tailnet", n.TsX, n.TsY)
	inside("count", n.CountX, n.CountY)
	inside("warn", n.CountX, n.WarnY)
	if n.Tags != "tailnet · VLAN 20" {
		t.Errorf("station tags = %q", n.Tags)
	}
	ni := infoByID(t, d)["h004"]
	if ni.X != float64(n.CenterX()) || ni.Y != float64(n.CenterY()) {
		t.Errorf("NodeInfo anchor = (%v,%v), station centre = (%d,%d)", ni.X, ni.Y, n.CenterX(), n.CenterY())
	}
	if strings.Join(ni.Badges, ",") != "tailnet,VLAN 20" {
		t.Errorf("NodeInfo.Badges = %v", ni.Badges)
	}
}
