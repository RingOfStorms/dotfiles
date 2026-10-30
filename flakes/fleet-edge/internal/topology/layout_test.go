package topology

import (
	"encoding/json"
	"fmt"
	"math"
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

// testSpec is two columns: a cloud holding the edge hub, and the rack holding
// the stations. The edge region is a plain cloud, not a route region, so the
// derived public cloud only appears in the spec that asks for it.
func testSpec() *Spec {
	return &Spec{
		Columns: []Column{
			{ID: "outside", Label: "Outside", Flex: 1, Zones: []Zone{
				{ID: "net", Label: "Internet", Kind: "internet", Flex: 1},
			}},
			{ID: "inside", Label: "Inside", Flex: 3, Zones: []Zone{
				{ID: "fleet", Label: "Fleet", Kind: "rack", Flex: 1},
			}},
		},
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

func zoneByID(d Diagram, id string) (ZoneBox, bool) {
	for _, z := range d.Zones {
		if z.ID == id {
			return z, true
		}
	}
	return ZoneBox{}, false
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

// --- stations and state ----------------------------------------------------

func TestBuildDeclaredContainerHostWithNoContainers(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	d := Build(testSpec(), state.MergeAt(inv, polls, at, nil), at)

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
	d := Build(testSpec(), state.MergeAt(inv, nil, at, nil), at)

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
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	d := Build(testSpec(), state.MergeAt(inv, map[string]state.HostPoll{}, at, nil), at)

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

// --- derived edges and spec resolution -------------------------------------

func TestBuildDerivedEdges(t *testing.T) {
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
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
		Columns: []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		Nodes:   []NodeSpec{{Host: "gone", Zone: "fleet"}},
	}
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
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
		Columns: []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		Nodes:   []NodeSpec{{ID: "switch", Zone: "fleet"}},
	}
	d := Build(spec, state.MergeAt(testInventory(), nil, at, nil), at)
	if len(d.Nodes) != 1 || d.Nodes[0].Label != "switch" {
		t.Fatalf("nodes = %+v", d.Nodes)
	}
}

func TestBuildDegenerateLayoutStaysSane(t *testing.T) {
	spec := testSpec()
	spec.Width = 0
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	// No width means the default one is split across the columns. Gutters
	// that need room for lanes take it from column slack first; the diagram
	// grows past the default only when slack runs out.
	if d.Width < DefaultWidth {
		t.Errorf("width = %d, want at least %d", d.Width, DefaultWidth)
	}
	for i, w := range columnWidths(spec.Columns, DefaultWidth) {
		if d.Columns[i].W > w || d.Columns[i].W < MinWidth {
			t.Errorf("column %s = %d wide, want between %d and the default split %d", d.Columns[i].ID, d.Columns[i].W, MinWidth, w)
		}
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

	// A column with no zones contributes nothing to the layout.
	spec.Columns = append([]Column{{ID: "empty"}}, spec.Columns...)
	got := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	if len(got.Zones) != len(d.Zones) {
		t.Errorf("empty column changed the region count: %d vs %d", len(got.Zones), len(d.Zones))
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

// --- columns ---------------------------------------------------------------

// Columns share the width by flex and keep their own heights: a tall rack
// never pads the route column beside it.
func TestColumnsShareWidthNotHeight(t *testing.T) {
	spec := &Spec{
		Width: 1500,
		Columns: []Column{
			{ID: "routes", Flex: 1, Zones: []Zone{{ID: "pub", Label: "Public", Flex: 1}}},
			{ID: "rack", Flex: 2, Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}},
		},
		DefaultZone: "fleet",
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	if len(d.Columns) != 2 {
		t.Fatalf("columns = %+v", d.Columns)
	}
	left, right := d.Columns[0], d.Columns[1]
	if left.W < MinWidth || right.W < MinWidth {
		t.Fatalf("column widths = %d,%d", left.W, right.W)
	}
	if right.W <= left.W {
		t.Errorf("flex 2 column %d wide, flex 1 column %d wide: proportions lost", right.W, left.W)
	}
	if left.X != 0 || right.X <= left.X+left.W {
		t.Errorf("columns overlap or leave no gap: %+v", d.Columns)
	}
	if right.X+right.W > d.Width {
		t.Errorf("columns run past the diagram: %d > %d", right.X+right.W, d.Width)
	}
	// Both columns end at the same top and share the diagram's height.
	if left.Y != right.Y {
		t.Errorf("column tops differ: %d vs %d", left.Y, right.Y)
	}
}

// A zone flexing takes the column's leftover; a zone without flex keeps its
// natural height even when a sibling grows.
func TestZoneFlexSharesColumnLeftoverOnly(t *testing.T) {
	spec := &Spec{
		Width:  900,
		Height: 1200,
		Columns: []Column{{ID: "rack", Zones: []Zone{
			{ID: "fixed", Label: "Fixed", Flex: 0},
			{ID: "grow", Label: "Grow", Flex: 1},
		}}},
		DefaultZone: "grow",
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	fixed, ok := zoneByID(d, "fixed")
	if !ok {
		t.Fatal("fixed zone missing")
	}
	grow, ok := zoneByID(d, "grow")
	if !ok {
		t.Fatal("grow zone missing")
	}
	if fixed.H != minZoneH {
		t.Errorf("unflexed empty zone = %d high, want natural %d", fixed.H, minZoneH)
	}
	if grow.H <= fixed.H {
		t.Errorf("flexing zone %d high, unflexed %d: leftover went nowhere", grow.H, fixed.H)
	}
	if d.Height < spec.Height {
		t.Errorf("height %d below the spec's %d", d.Height, spec.Height)
	}
}

// A column declares its own height from its contents when the spec sets none,
// and the diagram is as tall as the tallest column.
func TestDiagramHeightIsTheTallestColumn(t *testing.T) {
	short := &Spec{
		Width:       1200,
		Columns:     []Column{{ID: "a", Zones: []Zone{{ID: "one", Flex: 1}}}},
		DefaultZone: "one",
	}
	tall := &Spec{
		Width: 1200,
		Columns: []Column{{ID: "b", Zones: []Zone{
			{ID: "one", Flex: 1},
			{ID: "two", Flex: 1},
			{ID: "three", Flex: 1},
		}}},
		DefaultZone: "one",
	}
	m := state.MergeAt(testInventory(), allPolls(), at, nil)
	ds, dt := Build(short, m, at), Build(tall, m, at)
	if dt.Height <= ds.Height {
		t.Errorf("three regions %d high, one region %d high", dt.Height, ds.Height)
	}
	if ds.Height < minZoneH {
		t.Errorf("single-region diagram %d high", ds.Height)
	}
}

// --- row planning ----------------------------------------------------------

// A stack region reads top to bottom in spec order, one station per row: the
// rack order is the file's order, never sorted behind the author's back.
func TestStackLayoutKeepsSpecOrder(t *testing.T) {
	order := []string{"modem", "h005", "sg3210x", "sg1428pe", "h001"}
	spec := &Spec{
		Width: 900,
		Columns: []Column{{ID: "rack", Zones: []Zone{{
			ID: "rack", Label: "Rack", Layout: LayoutStack, Fill: "column", Flex: 1,
		}}}},
		DefaultZone: "rack",
	}
	for _, id := range order {
		spec.Nodes = append(spec.Nodes, NodeSpec{ID: id, Zone: "rack"})
	}
	d := Build(spec, state.MergeAt(testInventory(), nil, at, nil), at)
	nodes := nodesByID(d)
	prev := -1
	for _, id := range order {
		n, ok := nodes[id]
		if !ok {
			t.Fatalf("%s not placed", id)
		}
		if n.Y <= prev {
			t.Errorf("%s at y=%d does not follow the spec order (previous row bottom %d)", id, n.Y, prev)
		}
		prev = n.Y
	}
}

// Column fill reads down a column before moving right, so a rack listed in
// physical order stays in physical order across several columns.
func TestColumnFillReadsDownThenAcross(t *testing.T) {
	spec := &Spec{
		Width: 1200,
		Columns: []Column{{ID: "c", Zones: []Zone{{
			ID: "rack", Layout: LayoutStack, Fill: "column", Cols: 2, Flex: 1,
		}}}},
	}
	for i := range 6 {
		spec.Nodes = append(spec.Nodes, NodeSpec{ID: fmt.Sprintf("n%d", i), Zone: "rack"})
	}
	// No DefaultZone and an empty inventory: only these six stations are laid
	// out, so the fill order is the thing under test and nothing else.
	d := Build(spec, state.MergeAt(&inventory.Inventory{}, nil, at, nil), at)
	nodes := nodesByID(d)
	// Six stations, two across: "column" fill reads down the first column,
	// then the next, so rack order survives the wrap.
	if nodes["n1"].X != nodes["n0"].X || nodes["n1"].Y <= nodes["n0"].Y {
		t.Errorf("n1 is not below n0")
	}
	if nodes["n2"].X != nodes["n0"].X || nodes["n2"].Y <= nodes["n1"].Y {
		t.Errorf("n2 is not below n1")
	}
	if nodes["n3"].X <= nodes["n0"].X || nodes["n3"].Y != nodes["n0"].Y {
		t.Errorf("n3 did not start the second column at the top")
	}
}

// Stations wrap by the region's width instead of overflowing it.
func TestStationsWrapToTheRegionWidth(t *testing.T) {
	spec := &Spec{
		Width: MinWidth,
		Columns: []Column{{ID: "c", Zones: []Zone{{
			ID: "fleet", Flex: 1,
		}}}},
		DefaultZone: "fleet",
	}
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	z, ok := zoneByID(d, "fleet")
	if !ok {
		t.Fatal("fleet zone missing")
	}
	inner := z.W - 2*zonePad
	for _, n := range d.Nodes {
		if n.W <= 0 || n.W > inner {
			t.Errorf("node %s width %d outside 1..%d", n.ID, n.W, inner)
		}
		if n.X < z.X+zonePad-1 || n.X+n.W > z.X+z.W-zonePad+1 {
			t.Errorf("node %s spans %d..%d, region inner %d..%d",
				n.ID, n.X, n.X+n.W, z.X+zonePad, z.X+z.W-zonePad)
		}
	}
}

// Nodes never escape their own region, and a multi-row region grows instead of
// letting a later row spill past its bottom edge.
func TestBuildNodesFitTheirZone(t *testing.T) {
	spec := &Spec{
		Width:       MinWidth,
		Columns:     []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		DefaultZone: "fleet",
	}
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	if len(d.Nodes) != 3 {
		t.Fatalf("expected the three hosts placed, got %+v", d.Nodes)
	}
	z := d.Zones[0]
	for _, n := range d.Nodes {
		if n.H <= 0 {
			t.Errorf("node %s height %d", n.ID, n.H)
		}
		if n.DotX >= n.W {
			t.Errorf("node %s status dot at %d, width %d", n.ID, n.DotX, n.W)
		}
		if n.Y+n.H > z.Y+z.H {
			t.Errorf("node %s bottom %d past zone bottom %d", n.ID, n.Y+n.H, z.Y+z.H)
		}
	}
}

// --- route clouds ----------------------------------------------------------

// routeInventory has:
//
//	h004  public via edge ("git"), public via router ("www"), local ("vault")
//	h001  a second public name ("location") and a tailnet-only name ("notes")
//	h003  one public name that aliases an existing FQDN ("git")
//
// The zone declares every one of those plus "parked", which no route serves.
func routeInventory() *inventory.Inventory {
	return &inventory.Inventory{
		Services: map[string]inventory.Service{
			"gitea": {Name: "gitea", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 3000, FQDN: strp("git.example"), Exposure: "public", Via: []string{"edge"}},
			}},
			"router-ui": {Name: "router-ui", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 8443, FQDN: strp("www.example"), Exposure: "public", Via: []string{"router"}},
			}},
			"vault": {Name: "vault", Host: "h004", Routes: map[string]inventory.Route{
				"web": {Port: 8200, Exposure: "local"},
			}},
			"litellm": {Name: "litellm", Host: "h001", Routes: map[string]inventory.Route{
				"web": {Port: 4000, FQDN: strp("location.example"), Exposure: "public", Via: []string{"edge"}},
			}},
			"trilium": {Name: "trilium", Host: "h001", Routes: map[string]inventory.Route{
				"web": {Port: 8080, FQDN: strp("notes.example"), Exposure: "tailnet"},
			}},
			// Same FQDN as gitea, served from a second host: one name, one
			// marker, and the first owner in host order wins.
			"mirror": {Name: "mirror", Host: "h003", Routes: map[string]inventory.Route{
				"web": {Port: 80, FQDN: strp("git.example"), Exposure: "public", Via: []string{"edge"}},
			}},
		},
		Hosts: map[string]inventory.Host{
			"h001": {OverlayIP: strp("100.64.0.13")},
			"h003": {OverlayIP: strp("100.64.0.4")},
			"h004": {OverlayIP: strp("100.64.0.17")},
		},
	}
}

// routeSpec is the two-cloud atlas: public names and overlay names in one
// column, the rack in the other, the edge hub outside.
func routeSpec() *Spec {
	return &Spec{
		Width: 1500,
		Columns: []Column{
			{ID: "outside", Label: "Outside", Flex: 1, Zones: []Zone{
				{ID: "cloud", Label: "Oracle Cloud", Kind: "cloud", Flex: 1},
				{ID: "public", Label: "Public DNS", Layout: LayoutRoutes, Group: GroupPublic, Flex: 1},
				{ID: "overlay", Label: "Overlay names", Layout: LayoutRoutes, Group: GroupOverlay, Flex: 1},
			}},
			{ID: "inside", Label: "Home", Flex: 2, Zones: []Zone{
				{ID: "fleet", Label: "Rack", Kind: "rack", Flex: 1},
			}},
		},
		Nodes: []NodeSpec{{ID: "o002", Label: "Edge", Kind: "cloud", Zone: "cloud"}},
		DNS: &DNS{Zone: "example", Records: []DNSRecord{
			{Name: "git", Type: "CNAME", Value: "o002.example"},
			{Name: "www", Type: "CNAME", Value: "home.example"},
			{Name: "location", Type: "CNAME", Value: "o002.example"},
			{Name: "notes", Type: "CNAME", Value: "o002.example"},
			{Name: "parked", Type: "CNAME", Value: "o002.example"},
		}},
		DefaultZone: "fleet",
		Hubs:        Hubs{Edge: "o002"},
	}
}

func TestRouteCloudsClassifyByExposureAndOrigin(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	if len(d.RouteWeb) == 0 {
		t.Fatal("no public markers")
	}
	byLabel := map[string]RouteMarker{}
	for _, m := range d.RouteWeb {
		byLabel[m.Label] = m
	}
	// A public route is public only where it enters from the internet: the
	// marker binds the FQDN's short name, not the service name.
	git, ok := byLabel["git"]
	if !ok {
		t.Fatalf("no git marker in %+v", byLabel)
	}
	if git.Service != "gitea" || git.RouteKey != "git.example" {
		t.Errorf("git marker = %+v", git)
	}
	if git.FQDN != "git.example" {
		t.Errorf("marker label %q is not the short FQDN of %q", git.Label, git.FQDN)
	}
	if _, ok := byLabel["location"]; !ok {
		t.Errorf("route served by a second host has no marker: %+v", byLabel)
	}
	// A DNS-only name is drawn, faint, with no owner at all.
	parked, ok := byLabel["parked"]
	if !ok {
		t.Fatalf("a name the zone declares must appear: %+v", byLabel)
	}
	if parked.Declared || parked.Host != "" || parked.NodeID != "" {
		t.Errorf("DNS-only marker invented an owner: %+v", parked)
	}

	// h001's tailnet-only name belongs to the overlay cloud, first; h004's
	// local-only route belongs to neither.
	if len(d.OverlayWeb) != 1 || d.OverlayWeb[0].FQDN != "notes.example" {
		t.Fatalf("overlay = %+v", d.OverlayWeb)
	}
	if d.OverlayWeb[0].Label != "notes" {
		t.Errorf("overlay label = %q", d.OverlayWeb[0].Label)
	}
	for _, m := range d.RouteWeb {
		if m.FQDN == "" {
			t.Errorf("marker without a name: %+v", m)
		}
		if strings.HasPrefix(m.FQDN, "vault") {
			t.Errorf("a local-only route must not be drawn: %+v", m)
		}
	}
	// Declared names sort before the zone's leftovers.
	if !d.RouteWeb[0].Declared {
		t.Errorf("first public marker is not a declared name: %+v", d.RouteWeb[0])
	}
}

// One public FQDN is one marker, however many routes or aliases serve it.
func TestOneMarkerPerFQDN(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	count := map[string]int{}
	for _, m := range d.RouteWeb {
		count[m.FQDN]++
	}
	for fqdn, n := range count {
		if n > 1 {
			t.Errorf("%s drawn %d times", fqdn, n)
		}
	}
	if got := count["git.example"]; got != 1 {
		t.Errorf("git.example drawn %d times, want 1", got)
	}
	// Exactly the zone's five names: four owned, one DNS-only.
	if len(d.RouteWeb) != 5 {
		t.Errorf("public markers = %d, want the zone's 5 names", len(d.RouteWeb))
	}
}

// An overlay region with nothing to draw states why: the placement registry
// returned no bindings, so no name has an owner. Silence there reads as a
// broken render rather than as the registry's answer.
func TestEmptyRegistryOverlayZoneSaysWhy(t *testing.T) {
	// An empty non-nil binding map is the registry's "nothing is placed".
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, map[string]string{}), at)
	if len(d.OverlayWeb) != 0 {
		t.Fatalf("overlay markers = %d, want none without a placement", len(d.OverlayWeb))
	}
	if d.OverlayBrace != nil {
		t.Error("an empty overlay cloud still got a brace")
	}
	z, ok := zoneByID(d, "overlay")
	if !ok {
		t.Fatal("no overlay region")
	}
	if len(z.Note) == 0 {
		t.Fatal("empty overlay region says nothing")
	}
	note := strings.Join(z.Note, " ")
	if !strings.Contains(note, "0 of 6") {
		t.Errorf("note = %q, want the unplaced count of all 6 services", note)
	}
	// Every line has to fit inside the region, or the caption runs under the
	// brace and off the column.
	for _, line := range z.Note {
		// A line may only run over if it is one unbreakable word: wrapping
		// never cuts a word, so that is the one honest exception.
		if len(strings.Fields(line)) > 1 {
			if got, want := float64(len([]rune(line)))*noteCharW, float64(z.W-2*zonePad); got > want {
				t.Errorf("note line %q is %.0f wide, region allows %.0f", line, got, want)
			}
		}
	}
	if z.NoteY <= z.Y+zoneHead || z.NoteY >= z.Y+z.H {
		t.Errorf("note baseline %d outside the region body %d..%d", z.NoteY, z.Y+zoneHead, z.Y+z.H)
	}
	// The public cloud is still drawn from the zone catalogue alone, with no
	// owner claimed by anything.
	if len(d.RouteWeb) == 0 {
		t.Fatal("no public markers at all")
	}
	for _, m := range d.RouteWeb {
		if m.Declared {
			t.Errorf("%s is declared, but no service is placed: %+v", m.FQDN, m)
		}
	}
}

// A region that did draw its names stays silent: the caption is for an empty
// region, not a permanent subtitle.
func TestPlacedOverlayZoneHasNoNote(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	if len(d.OverlayWeb) == 0 {
		t.Fatal("no overlay markers with the declarative bindings")
	}
	for _, z := range d.Zones {
		if len(z.Note) != 0 {
			t.Errorf("region %q prints %q despite drawing its contents", z.ID, z.Note)
		}
	}
}

// Moving a public route's owner moves its marker and its binding: the model
// never pins a name to whichever host happened to be first.
func TestOwningHostChangeRebindsMarker(t *testing.T) {
	before := routeInventory()
	dBefore := Build(routeSpec(), state.MergeAt(before, nil, at, nil), at)

	after := routeInventory()
	moved := after.Services["gitea"]
	delete(after.Services, "gitea")
	moved.Host = "h001"
	after.Services["gitea"] = moved
	dAfter := Build(routeSpec(), state.MergeAt(after, nil, at, nil), at)

	pick := func(d Diagram, svc string) (RouteMarker, bool) {
		for _, m := range d.RouteWeb {
			if m.Service == svc {
				return m, true
			}
		}
		return RouteMarker{}, false
	}
	was, ok := pick(dBefore, "gitea")
	if !ok {
		t.Fatal("gitea marker missing before the move")
	}
	now, ok := pick(dAfter, "gitea")
	if !ok {
		t.Fatal("gitea marker missing after the move")
	}
	if was.Host != "h004" || was.NodeID != "h004" {
		t.Errorf("initial binding = %+v", was)
	}
	if now.Host != "h001" || now.NodeID != "h001" {
		t.Errorf("marker did not rebind: %+v", now)
	}
	// The catalog record follows the route that serves it.
	var rec *DNSRecord
	for i := range dAfter.PublicZone.Records {
		if dAfter.PublicZone.Records[i].Name == "git" {
			rec = &dAfter.PublicZone.Records[i]
		}
	}
	if rec == nil || rec.Host != "h001" || !rec.Declared {
		t.Errorf("catalogue record = %+v", rec)
	}
}

// The public brace is a real curly brace with a separate collector lead into
// the edge hub; the overlay is one bundled trunk with one branch per host.
func TestBraceAndCollectorPaths(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	if d.RouteBrace == nil {
		t.Fatal("no public brace")
	}
	if !strings.HasPrefix(d.RouteBrace.D, "M") {
		t.Fatalf("brace path = %q", d.RouteBrace.D)
	}
	// A brace curves at both ends and bulges at its point; an elbow does not.
	if !strings.Contains(d.RouteBrace.D, "Q") {
		t.Errorf("public brace is not a curve: %q", d.RouteBrace.D)
	}
	if d.RouteBrace.LeadD == "" {
		t.Error("public brace has no collector lead")
	}
	if d.RouteBrace.Hub != "o002" {
		t.Errorf("public brace leads to %q", d.RouteBrace.Hub)
	}
	if d.RouteBrace.TipX <= d.RouteBrace.SpineX {
		t.Errorf("public brace does not bulge away from its markers: spine %d tip %d",
			d.RouteBrace.SpineX, d.RouteBrace.TipX)
	}

	if d.OverlayBrace == nil {
		t.Fatal("no overlay brace")
	}
	if !strings.Contains(d.OverlayBrace.D, "Q") {
		t.Errorf("overlay brace is not a curve: %q", d.OverlayBrace.D)
	}
	var overlayBranches []RouteLink
	for _, l := range d.RouteLinks {
		if l.Host == "" || l.ToID == "" {
			t.Errorf("route link without endpoints: %+v", l)
		}
		if l.Group == GroupOverlay {
			overlayBranches = append(overlayBranches, l)
			// Every overlay branch leaves the same bus, so the bundle is
			// one trunk rather than a lead per chip.
			if l.FromX != d.OverlayBrace.TipX+trunkLen {
				t.Errorf("overlay branch leaves x=%d, not the shared bus", l.FromX)
			}
		}
	}
	if n := len(overlayBranches); n != len(distinctOverlayHosts(d.OverlayWeb)) {
		t.Errorf("%d overlay branches for %d hosts", n, len(distinctOverlayHosts(d.OverlayWeb)))
	}
	// Public reach is always drawn: every host serving a public name has a
	// branch, whether or not anything is selected.
	publicHosts := map[string]bool{}
	for _, m := range d.RouteWeb {
		if m.Host != "" && m.Host != d.Hubs.Edge {
			publicHosts[m.Host] = true
		}
	}
	gotPublic := map[string]bool{}
	for _, l := range d.RouteLinks {
		if l.Group == GroupPublic {
			gotPublic[l.Host] = true
		}
	}
	if len(gotPublic) != len(publicHosts) {
		t.Errorf("public branches %v, want one per owning host %v", gotPublic, publicHosts)
	}
	// The lead is part of the cloud document too: a client that redraws from
	// RouteMeta must get the trunk the SVG already draws, ending at the edge
	// hub's perimeter rather than nowhere.
	var groupsDoc routeDoc
	if err := json.Unmarshal([]byte(d.RouteMeta), &groupsDoc); err != nil {
		t.Fatalf("RouteMeta: %v", err)
	}
	hub, ok := nodesByID(d)["o002"]
	if !ok {
		t.Fatal("edge hub is not on the diagram")
	}
	leadEndsAt := func(path string, x, y int) bool {
		var px, py float64
		i := strings.LastIndex(path, "L")
		if i < 0 {
			return false
		}
		_, err := fmt.Sscanf(path[i:], "L%f %f", &px, &py)
		return err == nil && px == float64(x) && py == float64(y)
	}
	for _, g := range groupsDoc.Groups {
		if g.Lead == "" {
			t.Errorf("group %q lost its collector lead", g.ID)
			continue
		}
		var x, y float64
		_, err := fmt.Sscanf(g.Lead, "M%f %f", &x, &y)
		if err != nil || x != float64(g.Collector.X) || y != float64(g.Collector.Y) {
			t.Errorf("group %q lead %q does not start at its collector %v", g.ID, g.Lead, g.Collector)
		}
	}
	if pub, ok := func() (routeGroup, bool) {
		for _, g := range groupsDoc.Groups {
			if g.ID == GroupPublic {
				return g, true
			}
		}
		return routeGroup{}, false
	}(); !ok {
		t.Error("no public group in the route document")
	} else if !leadEndsAt(pub.Lead, hub.CenterX()-hub.R, hub.CenterY()) {
		t.Errorf("public lead %q does not end at the hub perimeter (%d,%d)", pub.Lead, hub.CenterX()-hub.R, hub.CenterY())
	}
}

func distinctOverlayHosts(ms []RouteMarker) map[string]bool {
	out := map[string]bool{}
	for _, m := range ms {
		if m.Host != "" {
			out[m.Host] = true
		}
	}
	return out
}

// The route document is valid JSON carrying both groups, their markers, the
// braces and the catalogue — the client joins nothing else.
func TestRouteMetaIsCompleteJSON(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	var doc struct {
		Groups []struct {
			ID        string `json:"id"`
			Brace     string `json:"brace"`
			Lead      string `json:"lead"`
			Collector struct {
				X int `json:"x"`
				Y int `json:"y"`
			} `json:"collector"`
			Routes []RouteMarker `json:"routes"`
		} `json:"groups"`
		DNS struct {
			Zone    string      `json:"zone"`
			Records []DNSRecord `json:"records"`
		} `json:"dns"`
	}
	if err := json.Unmarshal([]byte(d.RouteMeta), &doc); err != nil {
		t.Fatalf("RouteMeta: %v\n%s", err, d.RouteMeta)
	}
	if len(doc.Groups) != 2 {
		t.Fatalf("groups = %+v", doc.Groups)
	}
	seen := map[string]bool{}
	for _, g := range doc.Groups {
		seen[g.ID] = true
		if g.Brace == "" {
			t.Errorf("group %s has no brace", g.ID)
		}
		if len(g.Routes) == 0 {
			t.Errorf("group %s has no markers", g.ID)
		}
	}
	if !seen[GroupPublic] || !seen[GroupOverlay] {
		t.Errorf("groups = %v", seen)
	}
	if doc.DNS.Zone != "example" || len(doc.DNS.Records) != 5 {
		t.Errorf("catalogue = %+v", doc.DNS)
	}
	// Markers carry their own absolute rectangle: the static SVG needs no JS.
	for _, m := range d.RouteWeb {
		if m.W <= 0 || m.H <= 0 || m.TX <= m.X || m.TY <= m.Y {
			t.Errorf("marker %q has no laid-out chip: %+v", m.FQDN, m)
		}
	}
}

// A DNS-only name never animates and never claims an owner, and the catalogue
// marks exactly the names a route actually serves.
func TestDNSOnlyRecordIsFaintAndUnowned(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)
	declared := map[string]bool{}
	for _, r := range d.PublicZone.Records {
		declared[r.Name] = r.Declared
		if r.Declared && r.Host == "" {
			t.Errorf("declared record %q has no owner", r.Name)
		}
	}
	if declared["parked"] {
		t.Error("a CNAME nobody serves must stay undeclared")
	}
	if !declared["git"] || !declared["location"] || !declared["www"] {
		t.Errorf("declared map = %v", declared)
	}
	// "notes" is a tailnet name: the zone has it, but no public route serves
	// it, so the catalogue must not call it declared.
	if declared["notes"] {
		t.Errorf("tailnet-only name marked declared: %v", declared)
	}
	if !d.PublicZone.Available || d.PublicZone.Zone != "example" {
		t.Errorf("catalogue = %+v", d.PublicZone)
	}
}

// --- routes per host -------------------------------------------------------

// A host serving several names carries every one of them, each with its own
// exposure and entry point; the station still shows counts, not names.
func TestServiceExposureAndRouteOrigin(t *testing.T) {
	d := Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at)

	svcs := map[string]ServiceInfo{}
	for _, s := range infoByID(t, d)["h004"].Services {
		svcs[s.Name] = s
	}
	if len(svcs) != 3 {
		t.Fatalf("services = %+v", svcs)
	}
	if gitea := svcs["gitea"]; !gitea.Public || gitea.ViaRouter {
		t.Errorf("edge-terminated public route = %+v", gitea)
	}
	if router := svcs["router-ui"]; router.Public || !router.ViaRouter {
		t.Errorf("router-terminated public route = %+v", router)
	}
	if vault := svcs["vault"]; vault.Public || vault.ViaRouter || vault.Exposure != "local" {
		t.Errorf("host-only route = %+v", vault)
	}

	// Every declared route of the host is in the drilldown, unaggregated.
	ni := infoByID(t, d)["h004"]
	if len(ni.Routes) != 3 {
		t.Fatalf("routes = %+v", ni.Routes)
	}
	byKey := map[string]RouteInfo{}
	for _, r := range ni.Routes {
		byKey[r.RouteKey] = r
	}
	if r := byKey["git.example"]; !r.Public || r.DNS != "git" {
		t.Errorf("git route = %+v", r)
	}
	if r := byKey["www.example"]; !r.ViaRouter {
		t.Errorf("www route = %+v", r)
	}
	if r := byKey["8200"]; r.Public || r.ViaRouter {
		t.Errorf("local route = %+v", r)
	}
}

// Route keys are the traffic event's route key exactly, so a marker binds to
// the events it names.
func TestRouteKeyMatchesTrafficDerivation(t *testing.T) {
	cases := []struct {
		name string
		rt   inventory.Route
		want string
	}{
		{"named", inventory.Route{Name: strp("game"), Port: 25565, Proto: "tcp"}, "game"},
		{"fqdn", inventory.Route{FQDN: strp("git.example"), Port: 443}, "git.example"},
		{"url", inventory.Route{URL: strp("http://x.example"), Port: 80}, "http://x.example"},
		{"proto/port", inventory.Route{Port: 25565, Proto: "tcp"}, "tcp/25565"},
	}
	for _, c := range cases {
		if got := routeKey(c.rt, 0); got != c.want {
			t.Errorf("%s: routeKey = %q, want %q", c.name, got, c.want)
		}
	}
	if got := routeKey(inventory.Route{Port: 1}, 4); got != "route-4" {
		t.Errorf("fallback key = %q", got)
	}
	// Name wins over FQDN: a route's name is what traffic events carry.
	if got := routeKey(inventory.Route{Name: strp("web"), FQDN: strp("git.example")}, 0); got != "web" {
		t.Errorf("name did not win: %q", got)
	}
}

// --- mounts ----------------------------------------------------------------

// One ring per reported primary mount, never one per pool: two bcachefs mounts
// of the same pool are two draws of the same filesystem and get two rings.
func TestOneRingPerPrimaryMount(t *testing.T) {
	fs := []state.FilesystemMount{
		{Mount: "/", FSType: "ext4", TotalBytes: 100, UsedBytes: 40},
		{
			Mount: "/mnt/pool", FSType: "bcachefs", TotalBytes: 900, UsedBytes: 600,
			Submounts: []string{"/mnt/pool/photos", "/mnt/pool/media"},
			Bcachefs:  &state.BcachefsInfo{UUID: "pool-a"},
		},
		{
			Mount: "/mnt/pool/photos", FSType: "bcachefs", TotalBytes: 900, UsedBytes: 600,
			Bcachefs: &state.BcachefsInfo{UUID: "pool-a"},
		},
		{
			Mount: "/mnt/pool/media", FSType: "bcachefs", TotalBytes: 900, UsedBytes: 600,
			Bcachefs: &state.BcachefsInfo{UUID: "pool-a"},
		},
		{Mount: "/mnt/bulk", FSType: "bcachefs", TotalBytes: 500, UsedBytes: 100,
			Bcachefs: &state.BcachefsInfo{UUID: "pool-a"}},
	}
	// Role + overlay is what makes a host pollable: without a poll there is no
	// agent state, so nothing to ring.
	hosts := map[string]inventory.Host{
		"h004": {Role: "server", OverlayIP: strp("100.64.0.17")},
	}
	d := Build(&Spec{
		Width:       900,
		Columns:     []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Flex: 1}}}},
		DefaultZone: "fleet",
		Nodes:       []NodeSpec{{Host: "h004", Zone: "fleet"}},
	}, state.MergeAt(&inventory.Inventory{Hosts: hosts}, map[string]state.HostPoll{"h004": {
		Host: "h004", OK: true, PolledAt: at,
		Status: &state.HostStatus{Host: "h004", Filesystems: fs},
	}}, at, nil), at)

	n := nodesByID(d)["h004"]
	// "/", "/mnt/bulk" and "/mnt/pool" are primaries; the two submounts are
	// aliases of the pool and are listed, never given rings of their own.
	if len(n.Rings) != 3 {
		t.Fatalf("rings = %+v, want one per primary mount", n.Rings)
	}
	ni := infoByID(t, d)["h004"]
	if len(ni.Mounts) != 3 {
		t.Fatalf("mounts = %+v", ni.Mounts)
	}
	seen := map[string]bool{}
	for i, m := range ni.Mounts {
		if seen[m.Mount] {
			t.Errorf("mount %q drawn twice", m.Mount)
		}
		seen[m.Mount] = true
		if m.SimulatedFraction <= 0 || m.SimulatedFraction > 1 {
			t.Errorf("%s fraction = %v", m.Mount, m.SimulatedFraction)
		}
		// Every mount gets its own ring and its own shade, not a 4-colour
		// palette cycling behind the reader's back.
		if n.Rings[i].Shade != i {
			t.Errorf("%s shade = %d, want %d", m.Mount, n.Rings[i].Shade, i)
		}
		if m.Color == "" || n.Rings[i].Color != m.Color {
			t.Errorf("%s colour = %q / %q", m.Mount, m.Color, n.Rings[i].Color)
		}
		if m.Radius > stationW/2 {
			t.Errorf("%s radius %d wider than half the station", m.Mount, m.Radius)
		}
	}
	// The pool carries its two aliases as facts on its record; "/" has none.
	byMount := map[string]MountInfo{}
	for _, m := range ni.Mounts {
		byMount[m.Mount] = m
	}
	if got := byMount["/mnt/pool"].Submounts; len(got) != 2 {
		t.Errorf("pool lost its submount aliases: %+v", got)
	}
	if got := byMount["/"].Submounts; len(got) != 0 {
		t.Errorf("root grew submounts: %+v", got)
	}
	// Distinct colours, not four shades for ten filesystems.
	colors := map[string]bool{}
	for _, m := range ni.Mounts {
		colors[m.Color] = true
	}
	if len(colors) != len(ni.Mounts) {
		t.Errorf("%d distinct colours for %d mounts", len(colors), len(ni.Mounts))
	}
}

// No synthetic mounts: a host that reports nothing gets no ring, and an empty
// mount name is not invented into one.
func TestNoSyntheticMounts(t *testing.T) {
	infos, rings := mountRings(nil, "h001", at)
	if len(infos) != 0 || len(rings) != 0 {
		t.Errorf("no filesystems produced %+v / %+v", infos, rings)
	}
	infos, rings = mountRings([]state.FilesystemMount{{Mount: "", FSType: "ext4"}}, "h001", at)
	if len(infos) != 0 || len(rings) != 0 {
		t.Errorf("a nameless mount produced %+v / %+v", infos, rings)
	}
}

// Ten mounts still fit the station: ring radii stay inside its width and the
// head and every text baseline stay inside the box.
func TestManyRingsFitTheStation(t *testing.T) {
	fs := make([]state.FilesystemMount, 10)
	for i := range fs {
		fs[i] = state.FilesystemMount{Mount: fmt.Sprintf("/mnt/vol%d", i)}
	}
	_, rings := mountRings(fs, "h004", at)
	n := &Node{Rings: rings, Label: "h004"}
	finishNode(n)
	if n.W != stationW {
		t.Errorf("station grew sideways to %d", n.W)
	}
	for _, r := range rings {
		if r.R > stationW/2-ringStroke {
			t.Errorf("ring %d wider than the station", r.R)
		}
		if n.HeadY-r.R < 0 {
			t.Errorf("ring %d crosses the top edge (head %d)", r.R, n.HeadY)
		}
	}
	if n.LabelY <= n.HeadY+rings[len(rings)-1].R {
		t.Errorf("label at %d overlaps the outermost ring (head %d, r %d)",
			n.LabelY, n.HeadY, rings[len(rings)-1].R)
	}
	if n.TagsY+4 > n.H {
		t.Errorf("tags baseline %d outside the %d-high station", n.TagsY, n.H)
	}
}

// The arc is a measurement of one ring: it starts at 12 o'clock on that ring's
// own circle, centred on the final head, and sweeps clockwise for its fraction.
func TestRingArcsShareTheHeadCentre(t *testing.T) {
	fs := []state.FilesystemMount{{Mount: "/"}, {Mount: "/mnt/a"}, {Mount: "/mnt/b"}}
	infos, rings := mountRings(fs, "h004", at)
	n := &Node{Rings: rings, Label: "h004"}
	finishNode(n)
	for i, r := range rings {
		if r.D == "" {
			t.Fatalf("ring %d has no arc", i)
		}
		var x0, y0 float64
		if _, err := fmt.Sscanf(r.D, "M%f %f", &x0, &y0); err != nil {
			t.Fatalf("ring arc %q: %v", r.D, err)
		}
		if math.Abs(x0-float64(n.HeadX)) > 0.6 {
			t.Errorf("ring %d arc starts at x=%.1f, head is at %d", i, x0, n.HeadX)
		}
		if math.Abs(y0-(float64(n.HeadY)-float64(r.R))) > 0.6 {
			t.Errorf("ring %d arc starts at y=%.1f, ring top is %d", i, y0, n.HeadY-r.R)
		}
		if infos[i].Radius != r.R || infos[i].Shade != r.Shade {
			t.Errorf("ring %d disagrees with its MountInfo: %+v / %+v", i, r, infos[i])
		}
	}
}

// A deterministic simulated fraction: the same instant redraws the same ring,
// a different hour redraws a different one, and it is never a real reading.
func TestSimulatedFractionIsDeterministic(t *testing.T) {
	a := simFraction(at, "h004", "/")
	if a != simFraction(at, "h004", "/") {
		t.Error("same instant, different fraction")
	}
	if a == simFraction(at.Add(time.Hour), "h004", "/") {
		t.Error("a different hour drew the same fraction")
	}
	if a < 0.08 || a >= 0.98 {
		t.Errorf("fraction %v outside its declared band", a)
	}
}

// Ring colours are blue and only blue: a ring that drifted into the violet
// band would be read as the overlay cloud, and two mounts sharing a colour on
// one host makes the rings useless.
func TestRingColoursStayBlueAndDistinct(t *testing.T) {
	hue := func(c string) float64 {
		var h, s, l float64
		if _, err := fmt.Sscanf(c, "hsl(%f %f%% %f%%)", &h, &s, &l); err != nil {
			t.Fatalf("colour %q is not hsl: %v", c, err)
		}
		return h
	}
	for _, n := range []int{1, 2, 3, 10} {
		seen := map[string]bool{}
		for i := 0; i < n; i++ {
			c := ringColor(i, n)
			seen[c] = true
			if h := hue(c); h < 195 || h > 215 {
				t.Errorf("%d mounts, ring %d = %q: hue %.0f is not blue", n, i, c, h)
			}
		}
		if len(seen) != n {
			t.Errorf("%d mounts drew %d colours: %v", n, len(seen), seen)
		}
	}
	if got, want := ringColor(0, 2), "hsl(205 44% 45.0%)"; got != want {
		t.Errorf("first of two = %q, want %q", got, want)
	}
	if got, want := ringColor(1, 2), "hsl(205 58% 70.0%)"; got != want {
		t.Errorf("second of two = %q, want %q", got, want)
	}
	if got, want := ringColor(0, 1), "hsl(205 50% 55.0%)"; got != want {
		t.Errorf("lone mount = %q, want %q", got, want)
	}
}

// The hash key is unambiguous: a host and mount pair that only differs by
// where the separator falls must not collide.
func TestSimulatedFractionSeparatesFields(t *testing.T) {
	if simFraction(at, "a", "b/c") == simFraction(at, "a/b", "c") {
		t.Error("separator did not separate the fields")
	}
}

// --- validation ------------------------------------------------------------

func TestValidate(t *testing.T) {
	inv := testInventory()
	valid := func() *Spec { return testSpec() }
	// tenColumns builds ten equal columns, which cannot each get MinWidth out
	// of a MinWidth-wide diagram.
	tenColumns := func(s *Spec) {
		cols := make([]Column, 10)
		for i := range cols {
			cols[i] = Column{ID: string(rune('a' + i)), Flex: 1, Zones: []Zone{{ID: string(rune('a' + i))}}}
		}
		s.Width = MinWidth / 4
		s.Columns = cols
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
		{"negative height", func(s *Spec) { s.Height = -1 }, "negative"},
		{"valid at the default width", func(s *Spec) { s.Width = DefaultWidth }, ""},
		{"ten columns at the minimum width", tenColumns, fmt.Sprintf("minimum %d", MinWidth)},
		{"hard flex starves a column", func(s *Spec) {
			s.Columns[0].Flex = 50
			s.Columns[1].Flex = 1
		}, `column "inside"`},
		{"no columns", func(s *Spec) { s.Columns = nil }, "no zones"},
		{"column without zones", func(s *Spec) { s.Columns[0].Zones = nil }, "no zones"},
		{"negative column flex", func(s *Spec) { s.Columns[0].Flex = -1 }, "negative flex"},
		{"empty zone id", func(s *Spec) { s.Columns[0].Zones[0].ID = "" }, "empty id"},
		{"duplicate zone", func(s *Spec) { s.Columns[1].Zones[0].ID = "net" }, "duplicate zone"},
		{"negative zone flex", func(s *Spec) { s.Columns[0].Zones[0].Flex = -1 }, "negative flex"},
		{"negative cols", func(s *Spec) { s.Columns[0].Zones[0].Cols = -1 }, "negative cols"},
		{"unknown layout", func(s *Spec) { s.Columns[0].Zones[0].Layout = "spiral" }, "unknown layout"},
		{"unknown fill", func(s *Spec) { s.Columns[0].Zones[0].Fill = "diagonal" }, "unknown fill"},
		{"routes zone without group", func(s *Spec) {
			s.Columns[0].Zones[0].Layout = LayoutRoutes
		}, "names no group"},
		{"group outside a routes zone", func(s *Spec) {
			s.Columns[0].Zones[0].Group = GroupPublic
		}, "does not lay out routes"},
		{"unknown group", func(s *Spec) {
			s.Columns[0].Zones[0].Layout = LayoutRoutes
			s.Columns[0].Zones[0].Group = "internet"
		}, "unknown group"},
		{"two zones of one group", func(s *Spec) {
			s.Columns[0].Zones = append(s.Columns[0].Zones,
				Zone{ID: "pub2", Layout: LayoutRoutes, Group: GroupPublic})
			s.Columns[0].Zones[0].Layout = LayoutRoutes
			s.Columns[0].Zones[0].Group = GroupPublic
		}, "both lay out"},
		{"unknown default zone", func(s *Spec) { s.DefaultZone = "nowhere" }, "defaultZone"},
		{"default zone lays out routes", func(s *Spec) {
			s.Columns[0].Zones[0].Layout = LayoutRoutes
			s.Columns[0].Zones[0].Group = GroupPublic
			s.DefaultZone = "net"
		}, "lays out routes"},
		{"node without id or host", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{Zone: "fleet"}) }, "neither id nor host"},
		{"duplicate node", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{ID: "edge", Zone: "net"}) }, "duplicate node"},
		{"unknown zone", func(s *Spec) { s.Nodes = append(s.Nodes, NodeSpec{ID: "x", Zone: "nowhere"}) }, "unknown zone"},
		{"node in a routes zone", func(s *Spec) {
			s.Columns[0].Zones[0].Layout = LayoutRoutes
			s.Columns[0].Zones[0].Group = GroupPublic
			s.Nodes = append(s.Nodes, NodeSpec{ID: "x", Zone: "net"})
		}, "routes zone"},
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
		{"dns records without a zone", func(s *Spec) {
			s.DNS = &DNS{Records: []DNSRecord{{Name: "git", Type: "A", Value: "1.2.3.4"}}}
		}, "no zone"},
		{"dns record without a name", func(s *Spec) {
			s.DNS = &DNS{Zone: "example", Records: []DNSRecord{{Type: "A", Value: "1.2.3.4"}}}
		}, "no name"},
		{"dns record without a value", func(s *Spec) {
			s.DNS = &DNS{Zone: "example", Records: []DNSRecord{{Name: "git", Type: "A"}}}
		}, "no value"},
		{"dns record of an unknown type", func(s *Spec) {
			s.DNS = &DNS{Zone: "example", Records: []DNSRecord{{Name: "git", Type: "PTR", Value: "x"}}}
		}, "unknown type"},
		{"dns name declared twice", func(s *Spec) {
			s.DNS = &DNS{Zone: "example", Records: []DNSRecord{
				{Name: "git", Type: "A", Value: "1.2.3.4"},
				{Name: "git", Type: "A", Value: "5.6.7.8"},
			}}
		}, "twice"},
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

// Every column Validate accepts is wide enough that layout's own split agrees,
// so a spec that starts must draw in bounds. A column may give up slack to the
// gutters, never below the minimum and never so far a station leaves its region.
func TestValidateColumnWidthsMatchLayout(t *testing.T) {
	spec := testSpec()
	spec.Width = DefaultWidth
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	widths := columnWidths(spec.Columns, spec.Width)
	if len(d.Columns) != len(widths) {
		t.Fatalf("columns = %d, widths = %d", len(d.Columns), len(widths))
	}
	for i, c := range d.Columns {
		if c.W > widths[i] || c.W < MinWidth {
			t.Errorf("column %s drawn %d wide, validated %d (minimum %d)", c.ID, c.W, widths[i], MinWidth)
		}
	}
	zoneOf := map[string]ZoneBox{}
	for _, z := range d.Zones {
		zoneOf[z.ID] = z
	}
	// The laid-out Node carries no zone; the spec does. A node's ID defaults to
	// its host, and a host the spec never names lands in DefaultZone.
	specZone := map[string]string{}
	for _, ns := range spec.Nodes {
		id := ns.ID
		if id == "" {
			id = ns.Host
		}
		specZone[id] = ns.Zone
	}
	for _, n := range d.Nodes {
		zid, ok := specZone[n.ID]
		if !ok || zid == "" {
			zid = spec.DefaultZone
		}
		z, ok := zoneOf[zid]
		if !ok {
			continue
		}
		if n.X < z.X || n.X+n.W > z.X+z.W {
			t.Errorf("station %s spans x %d..%d, outside region %s %d..%d", n.ID, n.X, n.X+n.W, z.ID, z.X, z.X+z.W)
		}
	}
}

func TestValidateHiddenHostIsNotDrawn(t *testing.T) {
	spec := testSpec()
	spec.Hide = []string{"h003"}
	if err := spec.Validate(testInventory()); err != nil {
		t.Fatalf("validate: %v", err)
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	if _, ok := nodesByID(d)["h003"]; ok {
		t.Fatal("hidden host must not be auto-placed")
	}
}

// A host the spec never mentions still appears, in the default region.
func TestDefaultZoneAutoPlacesUnknownHost(t *testing.T) {
	spec := &Spec{
		Width:       1200,
		Columns:     []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Flex: 1}}}},
		DefaultZone: "fleet",
		Nodes:       []NodeSpec{{Host: "h001", Zone: "fleet"}},
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	for _, h := range []string{"h001", "h003", "gp3"} {
		if _, ok := nodesByID(d)[h]; !ok {
			t.Errorf("%s was not auto-placed", h)
		}
	}
}

// --- parking: behaviour that must not regress ------------------------------

// The station is fixed size and its head, icon, dot and counter baselines all
// stay inside the box, whatever the label length.
func TestStationGeometryStaysInsideTheBox(t *testing.T) {
	spec := &Spec{
		Width:       DefaultWidth,
		Columns:     []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		DefaultZone: "fleet",
		Nodes: []NodeSpec{{
			Host: "h001", Label: "A very long station label that would overflow", Zone: "fleet",
			Badges: []string{"tailnet", "VLAN 20"},
		}},
	}
	d := Build(spec, state.MergeAt(testInventory(), map[string]state.HostPoll{}, at, nil), at)

	n := nodesByID(d)["h001"]
	if n.W != stationW {
		t.Fatalf("station width = %d, want %d", n.W, stationW)
	}
	inside := func(name string, x, y int) {
		if x < 0 || x > n.W || y < 0 || y > n.H {
			t.Errorf("%s (%d,%d) is outside the %dx%d station", name, x, y, n.W, n.H)
		}
	}
	inside("head", n.HeadX, n.HeadY)
	inside("icon", n.IconX, n.IconY)
	if n.IconX+10 != n.HeadX || n.IconY+10 != n.HeadY {
		t.Errorf("icon centre = (%d,%d), station head = (%d,%d)", n.IconX+10, n.IconY+10, n.HeadX, n.HeadY)
	}
	inside("dot", n.DotX, n.HeadY)
	inside("tailnet", n.TsX, n.TsY)
	inside("count", n.CountX, n.CountY)
	inside("warn", n.CountX, n.WarnY)
	inside("label", n.HeadX, n.LabelY)
	inside("tags", n.HeadX, n.TagsY)
	if n.Tags != "tailnet · VLAN 20" {
		t.Errorf("station tags = %q", n.Tags)
	}
	ni := infoByID(t, d)["h001"]
	if ni.X != float64(n.CenterX()) || ni.Y != float64(n.CenterY()) {
		t.Errorf("NodeInfo anchor = (%v,%v), station centre = (%d,%d)", ni.X, ni.Y, n.CenterX(), n.CenterY())
	}
	if strings.Join(ni.Badges, ",") != "tailnet,VLAN 20" {
		t.Errorf("NodeInfo.Badges = %v", ni.Badges)
	}
}

// A station's name is 21px type, so its baseline has to clear whatever is
// drawn around the head: the outermost space ring when the host reports
// mounts, the head circle when it does not. Clearing only the ring radius
// put a ringless station's name through its own circle.
func TestStationLabelClearsTheHead(t *testing.T) {
	spec := &Spec{
		Width:       DefaultWidth,
		Columns:     []Column{{ID: "c", Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
		DefaultZone: "fleet",
		Nodes: []NodeSpec{
			{Host: "h001", Zone: "fleet"},
			{ID: "apc1", Zone: "fleet"},
		},
	}
	inv := testInventory()
	inv.Hosts["h001"] = inventory.Host{Role: "server", OverlayIP: strp("100.64.0.13")}
	polls := map[string]state.HostPoll{"h001": testPoll("h001", at)}
	d := Build(spec, state.MergeAt(inv, polls, at, nil), at)

	for _, id := range []string{"h001", "apc1"} {
		n := nodesByID(d)[id]
		// The widest thing around the head: the outer ring, else the circle.
		outer := n.R
		for _, r := range n.Rings {
			outer = max(outer, r.R)
		}
		if n.LabelY <= n.HeadY+outer {
			t.Errorf("%s: label baseline %d does not clear the head at y=%d r=%d (outer %d)",
				id, n.LabelY, n.HeadY, n.R, outer)
		}
		if n.H < n.LabelY {
			t.Errorf("%s: hit rect %d is above the label baseline %d", id, n.H, n.LabelY)
		}
	}
}

// The station counts services, not containers: a station with two of three
// services down shows 3/2 without listing a single name.
func TestStationServiceCountsAndFailure(t *testing.T) {
	inv := routeInventory()
	poll := state.HostPoll{
		Host: "h004", OK: true, PolledAt: at,
		Status: &state.HostStatus{
			Host: "h004",
			Services: map[string]state.ServiceStatus{
				"gitea":     {Active: "active", Enabled: true},
				"router-ui": {Active: "failed", Enabled: true},
				"vault":     {Active: "inactive", Enabled: false},
			},
		},
	}
	d := Build(routeSpec(), state.MergeAt(inv, map[string]state.HostPoll{"h004": poll}, at, nil), at)

	n := nodesByID(d)["h004"]
	if n.SvcCount != 3 || n.SvcFailed != 2 {
		t.Fatalf("station counts = %d services, %d failing", n.SvcCount, n.SvcFailed)
	}
	if n.Warn != 0 {
		t.Errorf("stopped services are not disk warnings: %d", n.Warn)
	}
	if ni := infoByID(t, d)["h004"]; ni.SvcFailed != 2 {
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

// A segment draws a bar spanning its region and takes a row of its own: a
// neutral fabric is never squeezed into a station cell.
func TestSegmentSpansItsRegion(t *testing.T) {
	spec := &Spec{
		Width: 1200,
		Columns: []Column{{ID: "c", Zones: []Zone{{
			ID: "lan", Flex: 1,
		}}}},
		DefaultZone: "lan",
		Nodes: []NodeSpec{
			{ID: "fabric", Label: "LAN fabric", Segment: true, Zone: "lan"},
			{Host: "h001", Zone: "lan"},
		},
	}
	d := Build(spec, state.MergeAt(testInventory(), allPolls(), at, nil), at)
	z, ok := zoneByID(d, "lan")
	if !ok {
		t.Fatal("lan zone missing")
	}
	seg, ok := nodesByID(d)["fabric"]
	if !ok {
		t.Fatal("segment not placed")
	}
	if seg.W != z.W-2*zonePad {
		t.Errorf("segment width %d, region inner %d", seg.W, z.W-2*zonePad)
	}
	if seg.H != segH {
		t.Errorf("segment height = %d, want %d", seg.H, segH)
	}
	if seg.SegX2 != seg.W || seg.SegY2 != seg.H {
		t.Errorf("segment bar = %+v", seg)
	}
	host := nodesByID(d)["h001"]
	if host.Y <= seg.Y {
		t.Errorf("station at y=%d did not take the row below the segment at %d", host.Y, seg.Y)
	}
}

// The chain a reader is meant to trace — router, switch, LAN segment server —
// must exist in the drawn graph, not just in prose. Every LAN attachment
// therefore has to reach the fabric on both ends: a switch with no fabric
// link would leave the servers hanging off nothing.
func TestLanFabricConnectsSwitchesAndHosts(t *testing.T) {
	spec := &Spec{
		Width: 1200,
		Columns: []Column{{ID: "c", Zones: []Zone{
			{ID: "rack", Flex: 1},
			{ID: "lan", Flex: 1},
		}}},
		DefaultZone: "lan",
		Nodes: []NodeSpec{
			{Host: "h005", Zone: "rack"},
			{ID: "sg3210x", Zone: "rack"},
			{ID: "sg1428pe", Zone: "rack"},
			{ID: "fabric", Label: "LAN fabric", Segment: true, Zone: "lan"},
			{Host: "h001", Zone: "lan"},
		},
		Links: []LinkSpec{
			{From: "h005", To: "sg3210x", Kind: "trunk"},
			{From: "sg3210x", To: "sg1428pe", Kind: "ethernet"},
			{From: "sg3210x", To: "fabric", Kind: LinkLan},
			{From: "sg1428pe", To: "fabric", Kind: LinkLan},
			{From: "fabric", To: "h001", Kind: LinkLan},
		},
	}
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{},
		Hosts: map[string]inventory.Host{
			"h005": {OverlayIP: strp("100.64.0.3"), LanIP: strp("10.12.14.1")},
			"h001": {OverlayIP: strp("100.64.0.13"), LanIP: strp("10.12.14.5")},
		},
	}
	d := Build(spec, state.MergeAt(inv, nil, at, nil), at)

	// The graph is undirected for reachability: a dashed attachment claims a
	// shared segment, not a direction.
	adj := map[string][]string{}
	lan := 0
	for _, e := range d.Edges {
		adj[e.From] = append(adj[e.From], e.To)
		adj[e.To] = append(adj[e.To], e.From)
		if e.Kind == LinkLan {
			lan++
		}
	}
	if lan != 3 {
		t.Errorf("%d LAN edges, want one per attachment (2 switches + 1 host)", lan)
	}

	// h005 reaches h001 only through a switch and the fabric.
	seen := map[string]bool{"h005": true}
	queue := []string{"h005"}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, next := range adj[cur] {
			if !seen[next] {
				seen[next] = true
				queue = append(queue, next)
			}
		}
	}
	if !seen["h001"] {
		t.Errorf("no drawn path h005 -> h001; reached %v", seen)
	}
	if !seen["fabric"] {
		t.Error("the fabric segment is drawn but unreachable from the router")
	}

	// A switch that only had host-facing LAN edges would strand the servers;
	// both switches must sit on the segment themselves.
	for _, sw := range []string{"sg3210x", "sg1428pe"} {
		if !seen[sw] {
			t.Errorf("switch %q is not attached to the fabric", sw)
		}
	}
}

// axisSeg is one axis-aligned piece of a drawn path: x fixed for a vertical
// run (lo..hi in y), y fixed for a horizontal one.
type axisSeg struct {
	vertical bool
	at       float64
	lo, hi   float64
}

// axisSegs splits a path built from M/L/H/V/Q into its axis-aligned pieces.
// A quadratic corner counts as its two legs, start to control and control to
// end, which is exactly the lanes its stroke occupies.
func axisSegs(t *testing.T, d string) []axisSeg {
	t.Helper()
	var out []axisSeg
	add := func(a, b [2]float64) {
		switch {
		case a == b:
		case math.Abs(a[0]-b[0]) < 1e-9:
			out = append(out, axisSeg{true, a[0], min(a[1], b[1]), max(a[1], b[1])})
		case math.Abs(a[1]-b[1]) < 1e-9:
			out = append(out, axisSeg{false, a[1], min(a[0], b[0]), max(a[0], b[0])})
		}
	}
	fields := strings.Fields(strings.NewReplacer("M", " M ", "L", " L ", "H", " H ", "V", " V ", "Q", " Q ").Replace(d))
	var pen [2]float64
	num := func(i int) float64 {
		var f float64
		if _, err := fmt.Sscan(fields[i], &f); err != nil {
			t.Fatalf("path %q: bad number %q", d, fields[i])
		}
		return f
	}
	for i := 0; i < len(fields); {
		switch fields[i] {
		case "M":
			pen = [2]float64{num(i + 1), num(i + 2)}
			i += 3
		case "L":
			p := [2]float64{num(i + 1), num(i + 2)}
			add(pen, p)
			pen, i = p, i+3
		case "H":
			p := [2]float64{num(i + 1), pen[1]}
			add(pen, p)
			pen, i = p, i+2
		case "V":
			p := [2]float64{pen[0], num(i + 1)}
			add(pen, p)
			pen, i = p, i+2
		case "Q":
			c, p := [2]float64{num(i + 1), num(i + 2)}, [2]float64{num(i + 3), num(i + 4)}
			add(pen, c)
			add(c, p)
			pen, i = p, i+5
		default:
			t.Fatalf("path %q: unexpected %q", d, fields[i])
		}
	}
	return out
}

// denseSpec funnels many connections into one column: every rack station is
// reached from outside, from the house and from inside the rack itself, and
// rack rows hold two stations so some legs have to pass a neighbour.
func denseSpec() *Spec {
	s := &Spec{
		Width: 1500,
		Columns: []Column{
			{ID: "outside", Label: "Outside", Flex: 1, Zones: []Zone{{ID: "net", Label: "Internet", Kind: "internet", Flex: 1}}},
			{ID: "rackband", Label: "Rack", Flex: 1.4, Zones: []Zone{{ID: "rack", Label: "Rack", Kind: "rack", Layout: LayoutFlow, Cols: 2, Flex: 1}}},
			{ID: "house", Label: "Home", Flex: 1.2, Zones: []Zone{{ID: "lan", Label: "LAN", Kind: "lan", Layout: LayoutFlow, Cols: 2, Flex: 1}}},
		},
	}
	node := func(id, zone string) {
		s.Nodes = append(s.Nodes, NodeSpec{ID: id, Label: id, Kind: "server", Zone: zone})
	}
	link := func(from, to string) { s.Links = append(s.Links, LinkSpec{From: from, To: to, Kind: "lan"}) }
	node("isp", "net")
	node("cloud", "net")
	for i := 1; i <= 8; i++ {
		node(fmt.Sprintf("r%d", i), "rack")
	}
	for i := 1; i <= 4; i++ {
		node(fmt.Sprintf("h%d", i), "lan")
	}
	for i := 1; i <= 8; i++ {
		link("isp", fmt.Sprintf("r%d", i))
	}
	for i := 2; i <= 6; i++ {
		link("r1", fmt.Sprintf("r%d", i))
	}
	for i := 1; i <= 4; i++ {
		link(fmt.Sprintf("h%d", i), "r1")
		link("cloud", fmt.Sprintf("h%d", i))
	}
	link("r3", "h2")
	link("r8", "cloud")
	return s
}

// laneFixtures is every diagram the lane tests hold to: the agent fan of the
// basic spec, both route clouds, and the dense rack.
func laneFixtures() map[string]Diagram {
	return map[string]Diagram{
		"basic":  Build(testSpec(), state.MergeAt(testInventory(), allPolls(), at, nil), at),
		"routes": Build(routeSpec(), state.MergeAt(routeInventory(), nil, at, nil), at),
		"dense":  Build(denseSpec(), state.MergeAt(&inventory.Inventory{}, nil, at, nil), at),
	}
}

// TestLanesDoNotCollide: no two connections draw a stroke along the same
// line. Every edge and every cloud branch is split into axis-aligned pieces,
// and two pieces of different paths on one x (or y) must not overlap.
func TestLanesDoNotCollide(t *testing.T) {
	const eps = 0.5
	for name, d := range laneFixtures() {
		type owned struct {
			who string
			seg axisSeg
		}
		var all []owned
		for _, e := range d.Edges {
			for _, s := range axisSegs(t, e.D) {
				all = append(all, owned{"edge " + e.From + "->" + e.To + " " + e.Kind, s})
			}
		}
		for _, l := range d.RouteLinks {
			for _, s := range axisSegs(t, l.D) {
				all = append(all, owned{l.Group + " branch ->" + l.ToID, s})
			}
		}
		if name == "dense" {
			into := 0
			for _, e := range d.Edges {
				if strings.HasPrefix(e.To, "r") {
					into++
				}
			}
			if into < 6 {
				t.Fatalf("dense fixture has %d edges into the rack column", into)
			}
		}
		for i := range all {
			for j := i + 1; j < len(all); j++ {
				a, b := all[i], all[j]
				if a.who == b.who || a.seg.vertical != b.seg.vertical || math.Abs(a.seg.at-b.seg.at) > eps {
					continue
				}
				if over := min(a.seg.hi, b.seg.hi) - max(a.seg.lo, b.seg.lo); over > eps {
					axis := "y"
					if a.seg.vertical {
						axis = "x"
					}
					t.Errorf("%s: %s and %s share %s=%.1f over %.1f..%.1f", name, a.who, b.who,
						axis, a.seg.at, max(a.seg.lo, b.seg.lo), min(a.seg.hi, b.seg.hi))
				}
			}
		}
	}
}

// TestLaneAnchorsAreDistinct: every connection meeting a station has its own
// attach point on it.
func TestLaneAnchorsAreDistinct(t *testing.T) {
	for name, d := range laneFixtures() {
		type point struct {
			station string
			x, y    float64
		}
		var seen []point
		var whose []string
		claim := func(station, who string, x, y float64) {
			for i, p := range seen {
				if p.station == station && math.Abs(p.x-x) < 0.5 && math.Abs(p.y-y) < 0.5 {
					t.Errorf("%s: %s and %s both meet %s at (%.1f,%.1f)", name, whose[i], who, station, x, y)
				}
			}
			seen = append(seen, point{station, x, y})
			whose = append(whose, who)
		}
		for _, e := range d.Edges {
			segs := strings.Fields(strings.NewReplacer("M", " ", "L", " ", "Q", " ").Replace(e.D))
			if len(segs) < 4 {
				t.Fatalf("%s: edge %s->%s has path %q", name, e.From, e.To, e.D)
			}
			var x0, y0, x1, y1 float64
			fmt.Sscan(segs[0], &x0)
			fmt.Sscan(segs[1], &y0)
			fmt.Sscan(segs[len(segs)-2], &x1)
			fmt.Sscan(segs[len(segs)-1], &y1)
			who := e.From + "->" + e.To + " " + e.Kind
			claim(e.From, who, x0, y0)
			claim(e.To, who, x1, y1)
		}
	}
}
