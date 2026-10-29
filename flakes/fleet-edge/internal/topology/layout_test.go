package topology

import (
	"encoding/json"
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
	// A declared host with nothing on it still says it is a container host.
	if n.ChipsLabel == nil || !strings.Contains(strings.ToLower(n.ChipsLabel.Text), "container") {
		t.Fatalf("chips label = %+v", n.ChipsLabel)
	}
	if len(n.Chips) != 0 {
		t.Errorf("expected no chips, got %+v", n.Chips)
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
	if n.ChipsLabel == nil || !strings.Contains(strings.ToLower(n.ChipsLabel.Text), "container") {
		t.Fatalf("chips label = %+v", n.ChipsLabel)
	}
	if len(n.Chips) != 2 || n.Chips[0].Name != "jellyfin" || n.Chips[1].Name != "photos" {
		t.Fatalf("chips = %+v", n.Chips)
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
	if n.ChipsLabel != nil {
		t.Fatalf("no chips and no containers: label must be nil, got %+v", n.ChipsLabel)
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

	if e := edge(t, d, "internet", "h001", "tailnet"); !e.Live {
		t.Error("online host must have a live edge")
	}
	if e := edge(t, d, "internet", "gp3", "tailnet"); e.Live {
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
	if e := edge(t, d, "internet", "h001", "tailnet"); e.Live {
		t.Error("offline host must not have a live edge")
	}
	for _, l := range n.Lines {
		if l.Class == "metrics" {
			t.Errorf("offline host metrics line drawn: %q", l.Text)
		}
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
	var metricsLine string
	for _, l := range nodesByID(d)["h001"].Lines {
		if l.Class == "metrics" {
			metricsLine = l.Text
		}
	}
	if !strings.Contains(metricsLine, "cpu 12%") || !strings.Contains(metricsLine, "mem 25%") || !strings.Contains(metricsLine, "up 1h") {
		t.Fatalf("metrics line = %q", metricsLine)
	}
	ni := infoByID(t, d)["h001"]
	if !strings.Contains(strings.Join(ni.Lines, "|"), "cpu 12%") {
		t.Errorf("NodeInfo.Lines lacks the metrics: %+v", ni.Lines)
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

	edge(t, d, "edge", "h001", "public")
	edge(t, d, "internet", "h001", "tailnet")
	edge(t, d, "internet", "h003", "agent")

	// Only hosts with an overlay IP get a tailnet edge.
	for _, e := range d.Edges {
		if e.Kind == "tailnet" && e.To == "edge" {
			t.Errorf("static node must not get a tailnet edge: %+v", e)
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
		{"ten zones at the minimum width", tenZones, "minimum 200"},
		{"two zones at the minimum width", func(s *Spec) {
			s.Width = MinWidth
			s.Rows[0].Zones = []Zone{{ID: "net", Flex: 1}, {ID: "fleet", Flex: 1}}
		}, "minimum 200"},
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
