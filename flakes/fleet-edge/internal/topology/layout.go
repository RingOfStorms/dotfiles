package topology

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

// Diagram is a fully laid-out topology: absolute SVG coordinates, ready for
// a template to draw without arithmetic.
type Diagram struct {
	Width, Height int
	// AsOf is the snapshot the layout was built for. /topology.svg is also
	// served for recorded frames, so the client measures ages from this
	// instead of the wall clock — and the simulated fill of every space ring
	// derives from it, so replaying an instant redraws the same rings.
	AsOf    time.Time
	Columns []ColumnBox
	Zones   []ZoneBox
	Edges   []Edge
	Nodes   []Node
	// Hubs name the nodes derived paths attach to. topology.js builds its
	// journeys from them: a public journey is simulated client -> edge -> host
	// -> service.
	Hubs Hubs
	// Meta is the JSON node-detail map (id -> NodeInfo) behind the sidebar
	// drilldown: every technical fact lives there, not on the diagram.
	Meta string
	// RouteMeta is the JSON route document (both clouds with their laid-out
	// markers, the collector braces, and the public-zone catalogue) behind
	// #topo-routes.
	RouteMeta string
	// RouteWeb and OverlayWeb are the two derived clouds: public names, and
	// overlay (tailnet) names. Coordinates are absolute.
	RouteWeb   []RouteMarker
	OverlayWeb []RouteMarker
	// RouteBrace groups the public cloud and leads it into the edge hub;
	// OverlayBrace groups the overlay cloud and feeds the collector branches.
	RouteBrace   *RouteBrace
	OverlayBrace *RouteBrace
	// RouteLinks are the overlay branches, one per owning host.
	RouteLinks []RouteLink
	// PublicZone is the public DNS zone's catalogue: every record the spec
	// declares, and which of them a declared route actually serves.
	PublicZone PublicZone
}

// ColumnBox is a laid-out column: a caption over its stack of regions.
type ColumnBox struct {
	ID, Label  string
	X, Y, W, H int
}

// ZoneBox is a laid-out region. Box marks the solid card (one physical
// enclosure); everything else is open ground with a label.
type ZoneBox struct {
	ID, Label, Kind string
	X, Y, W, H      int
	Box             bool
	// Zone is the declaration, so a route region still knows its group and
	// column cap.
	Zone Zone
}

// Node is a laid-out station: one circular head with the icon, the name, the
// plain role under it and, when it has any, the membership tags.
//
// HeadX/HeadY/R and the text baselines are box-local, so the template needs a
// single translate; CenterX/CenterY give the absolute point links attach to.
// A segment draws a bar instead: SegX1..SegX2 spans it and links attach there.
type Node struct {
	ID, Label, Kind, Host, Icon, Role, State string
	X, Y, W, H                               int
	HeadX, HeadY, R                          int
	LabelY, RoleY                            int
	Tags                                     string
	TagsY                                    int
	// IconX/IconY, DotX, TsX/TsY and the counter baselines derive from the
	// head; the template only reads them.
	IconX, IconY, DotX, TsX, TsY int
	CountX, CountY, WarnY        int
	// Segment draws a bar instead of a head: a neutral fabric, not a device.
	Segment      bool
	SegX1, SegX2 int
	SegY1, SegY2 int
	// SvcCount is every declared service here, SvcFailed those not running.
	// Warn counts disk health problems; BannedCount is enforced protection,
	// not a fault. None of them is security theatre: each is a count from the
	// declaration or the last poll, printed on the station.
	SvcCount, SvcFailed, Warn int
	BannedCount               int
	// CPUPercent/MemPercent are the host's actual utilisation from its latest
	// successful poll, and CPUAvailable/MemAvailable say whether there is one.
	// An offline host has no current numbers, so its station draws no gauges
	// at all rather than a comforting zero.
	CPUPercent, MemPercent     float64
	CPUAvailable, MemAvailable bool
	// GaugeX/GaugeY/GaugeW, the two bar rows and their filled widths are
	// box-local, so the template draws the readout without arithmetic.
	GaugeX, GaugeY, GaugeW int
	CPUBarY, MemBarY       int
	CPUFill, MemFill       int
	// Tailnet marks overlay membership; ContainerHost says the inventory
	// declares containers here even when there are none yet.
	Tailnet       bool
	ContainerHost bool
	Title         string
	// Rings are the simulated space rings, precomputed so the standalone SVG
	// draws them without JS.
	Rings []RingArc
	// live: confirmed present right now. Static gear always is.
	live bool
}

// CenterX, CenterY are the absolute head centre.
func (n Node) CenterX() int { return n.X + n.HeadX }
func (n Node) CenterY() int { return n.Y + n.HeadY }

// RingArc is one simulated disk-usage ring around a station head, box-local.
// D is the filled part and is drawn after the head centre is final, so the arc
// is concentric with the ring its own track circle draws.
type RingArc struct {
	R     int `json:"r"`
	Shade int `json:"shade"`
	// Color is this ring's own stroke, so a host with more filesystems than
	// named shades still gets a distinct ring for each.
	Color string  `json:"color,omitempty"`
	Pct   float64 `json:"pct"`
	D     string  `json:"d"`
	Mount string  `json:"mount"`
}

// Edge is one drawn connection. D is an orthogonal stub-elbow-stub path;
// LX/LY is the label's centre, LRX/LRY its background's corner, LW its width.
type Edge struct {
	From, To, Kind, Layer, Label string
	Live                         bool
	D                            string
	LX, LY, LW                   int
	LRX, LRY                     int
}

// NodeInfo is the sidebar drilldown payload for one node. The overview stays
// plain; the raw host status is carried here so the detail panel can show
// every technical fact without the map repeating it.
//
// Ages are never precomputed into a single "stale" verdict: the client has the
// snapshot time, each section's own timestamp and each section's cadence, so a
// 15-minute SMART refresh is not called stale by a 1-minute fail2ban
// expectation (or the reverse).
type NodeInfo struct {
	Label     string        `json:"label"`
	Kind      string        `json:"kind"`
	Host      string        `json:"host,omitempty"`
	Role      string        `json:"role,omitempty"`
	State     string        `json:"state"`
	StateText string        `json:"stateText,omitempty"`
	OverlayIP string        `json:"overlayIp,omitempty"`
	LanIP     string        `json:"lanIp,omitempty"`
	Href      string        `json:"href,omitempty"`
	Badges    []string      `json:"badges,omitempty"`
	Lines     []string      `json:"lines,omitempty"`
	Services  []ServiceInfo `json:"services,omitempty"`
	// Routes is every declared route of this host, unaggregated: a host can
	// serve several names, each with its own exposure and entry point.
	Routes []RouteInfo `json:"routes,omitempty"`
	// Mounts is one entry per reported primary mount: the simulated space
	// rings and their captions.
	Mounts []MountInfo `json:"mounts,omitempty"`
	Links  []LinkInfo  `json:"links,omitempty"`
	// X, Y is the station head in SVG units: traces anchor here instead of
	// measuring the DOM.
	X float64 `json:"x"`
	Y float64 `json:"y"`
	// Live is the merge's reachability verdict, Reachable the raw echo from
	// the last poll. lastSeen is empty when the host was never polled.
	Live        bool      `json:"live"`
	Reachable   bool      `json:"reachable"`
	LastSeen    time.Time `json:"lastSeen,omitempty"`
	LastSeenAge string    `json:"lastSeenAge,omitempty"`
	PolledAt    time.Time `json:"polledAt,omitempty"`
	StatusTime  string    `json:"statusTime,omitempty"`
	// Counts, separated on purpose: an absent host and a stopped service are
	// faults; disk advisories are warnings; bans are enforced protection.
	SvcFailed    int                     `json:"svcFailed"`
	DiskWarnings int                     `json:"diskWarnings"`
	BannedCount  int                     `json:"bannedCount,omitempty"`
	SmartTotal   int                     `json:"smartTotal"`
	SmartOK      int                     `json:"smartOk"`
	SmartFailed  int                     `json:"smartFailed"`
	System       *state.SystemMetrics    `json:"system,omitempty"`
	Smart        []state.SmartDrive      `json:"smart,omitempty"`
	Filesystems  []state.FilesystemMount `json:"filesystems,omitempty"`
	Fail2ban     *state.Fail2banSummary  `json:"fail2ban,omitempty"`
	// ContainerHost: containers are declared here even when there are none
	// right now. Deliberately no omitempty: false is meaningful.
	ContainerHost bool `json:"containerHost"`
}

// ServiceInfo is one declared service of a host.
type ServiceInfo struct {
	Name        string   `json:"name"`
	State       string   `json:"state"`
	Exposure    string   `json:"exposure,omitempty"`
	Description string   `json:"description,omitempty"`
	URLs        []string `json:"urls,omitempty"`
	Proto       string   `json:"proto,omitempty"`
	Port        int      `json:"port,omitempty"`
	// Public: a genuinely public route (exposure public) reaching the service
	// through the edge hub (Via contains "edge"). ViaRouter marks a public
	// route terminating on the router instead — a different hub, so a journey
	// must not pretend it goes through the edge.
	Public    bool `json:"public"`
	ViaRouter bool `json:"viaRouter"`
}

// RouteInfo is one declared route of a host. Service+RouteKey are exactly the
// service/route on a traffic event, so a marker or a journey binds to the
// events of the route it names.
type RouteInfo struct {
	ID        string   `json:"id"`
	Label     string   `json:"label"`
	FQDN      string   `json:"fqdn,omitempty"`
	URL       string   `json:"url,omitempty"`
	Host      string   `json:"host,omitempty"`
	NodeID    string   `json:"nodeId,omitempty"`
	Service   string   `json:"service"`
	RouteKey  string   `json:"routeKey"`
	Exposure  string   `json:"exposure,omitempty"`
	Via       []string `json:"via,omitempty"`
	Proto     string   `json:"proto,omitempty"`
	Port      int      `json:"port,omitempty"`
	Public    bool     `json:"public"`
	ViaRouter bool     `json:"viaRouter"`
	// DNS is the public-zone record name (relative) serving this route, ""
	// when the zone has no record for it.
	DNS string `json:"dns,omitempty"`
}

// MountInfo is one reported mount's static space ring.
type MountInfo struct {
	ID        string   `json:"id"`
	Mount     string   `json:"mount"`
	Submounts []string `json:"submounts,omitempty"`
	// ActualUsed/ActualTotal are the recorded bytes, never simulated.
	ActualUsed  uint64 `json:"actualUsed"`
	ActualTotal uint64 `json:"actualTotal"`
	// SimulatedFraction is the deterministic simulated fill (0..1) the ring
	// draws. The numbers above stay the measured facts.
	SimulatedFraction float64 `json:"simulatedFraction"`
	Radius            int     `json:"radius"`
	StrokeWidth       int     `json:"strokeWidth"`
	Shade             int     `json:"shade"`
	// Color is the ring's own stroke, distinct per mount; Shade stays for the
	// stylesheet's fallback classes.
	Color string `json:"color,omitempty"`
}

// LinkInfo is one connection in the sidebar, from this node's side.
type LinkInfo struct {
	Kind      string `json:"kind"`
	Layer     string `json:"layer"`
	Peer      string `json:"peer"`
	PeerLabel string `json:"peerLabel"`
	Label     string `json:"label,omitempty"`
	Out       bool   `json:"out"`
}

// RouteMarker is one chip in a derived route cloud. Coordinates are absolute,
// so the static SVG needs no layout script.
type RouteMarker struct {
	ID    string `json:"id"`
	Group string `json:"group"`
	// Label is the name inside the zone ("git", "*.share") when the zone
	// declares one, else the host part of the FQDN — never the service or
	// route name when it differs from the name people type.
	Label    string   `json:"label"`
	FQDN     string   `json:"fqdn"`
	Host     string   `json:"host,omitempty"`
	NodeID   string   `json:"node,omitempty"`
	Service  string   `json:"service,omitempty"`
	RouteKey string   `json:"route,omitempty"`
	Exposure string   `json:"exposure,omitempty"`
	Via      []string `json:"via,omitempty"`
	Proto    string   `json:"proto,omitempty"`
	Port     int      `json:"port,omitempty"`
	// DNSName is the public-zone record name serving this name ("" when the
	// zone has no record for it).
	DNSName string `json:"dnsName,omitempty"`
	// Declared is false for a name the zone declares with no declared route
	// behind it: drawn faint, never animated, never given a host.
	Declared bool `json:"declared"`
	X        int  `json:"x"`
	Y        int  `json:"y"`
	W        int  `json:"w"`
	H        int  `json:"h"`
	TX       int  `json:"tx"`
	TY       int  `json:"ty"`
}

// RouteBrace groups one route cloud and leads it to where it enters.
//
// D is a genuine curly brace: markers sit against its spine, its point bulges
// away from them. LeadD is the collector's own path from that point to Hub, a
// separate field so the two can be styled differently.
type RouteBrace struct {
	Group  string `json:"group"`
	D      string `json:"d"`
	LeadD  string `json:"leadD,omitempty"`
	Top    int    `json:"top"`
	Bottom int    `json:"bottom"`
	Mid    int    `json:"mid"`
	SpineX int    `json:"spineX"`
	TipX   int    `json:"tipX"`
	Hub    string `json:"hub,omitempty"`
	HubX   int    `json:"hubX,omitempty"`
	HubY   int    `json:"hubY,omitempty"`
}

// RouteLink is one branch of the overlay collector, from the shared trunk to
// the host serving those names. One branch per host: a marker never gets a
// lead of its own.
type RouteLink struct {
	Group string `json:"group"`
	Host  string `json:"host"`
	ToID  string `json:"toId"`
	FromX int    `json:"fromX"`
	FromY int    `json:"fromY"`
	ToX   int    `json:"toX"`
	ToY   int    `json:"toY"`
	D     string `json:"d"`
}

// Point is an absolute SVG coordinate in the route document.
type Point struct {
	X int `json:"x"`
	Y int `json:"y"`
}

// PublicZone is the catalogue of the public DNS zone.
type PublicZone struct {
	Zone      string      `json:"zone"`
	Available bool        `json:"available"`
	Records   []DNSRecord `json:"records"`
	External  []string    `json:"external,omitempty"`
}

// routeGroup is one laid-out cloud, as the route document carries it.
type routeGroup struct {
	ID        string        `json:"id"`
	Label     string        `json:"label"`
	Color     string        `json:"color"`
	X         int           `json:"x"`
	Y         int           `json:"y"`
	W         int           `json:"w"`
	H         int           `json:"h"`
	Collector Point         `json:"collector"`
	Brace     string        `json:"brace,omitempty"`
	Lead      string        `json:"lead,omitempty"`
	Routes    []RouteMarker `json:"routes"`
}

// routeDoc is Diagram.RouteMeta: both clouds plus the catalogue in one
// document, so the client never joins two sources.
type routeDoc struct {
	Groups []routeGroup `json:"groups"`
	DNS    PublicZone   `json:"dns"`
	Links  []RouteLink  `json:"links,omitempty"`
}

// Geometry (SVG units). Text widths are estimates for system-ui.
const (
	margin      = 18  // diagram edge
	colHead     = 36  // column caption band
	colGap      = 28  // between columns
	zonePad     = 22  // inside a region
	zoneHead    = 40  // region label band
	zoneGapY    = 24  // between regions of one column
	minZoneH    = 168 // an empty region still reads as a region
	stationW    = 180
	stationR    = 18
	stationGX   = 26
	stationGY   = 24
	labelGap    = 24 // 21px name: baseline of the 16px caption under it
	gaugePitch  = 22 // cpu caption to mem caption: a 16px box is ~18 tall
	tagsClear   = 14 // mem caption to the count band
	countInset  = 10 // count text left edge inside the station
	countLine   = 15 // one 12px count row
	segH        = 44 // a fabric bar
	chipH       = 22 // one route marker
	chipGap     = 8
	chipMinW    = 150 // chips per row at the default width
	braceW      = 16  // how far the brace's point bulges from its spine
	braceGutter = braceW + 14
	ringR0      = 24
	ringStep    = 3
	ringStroke  = 3
	labelCharW  = 11.6
	smallCharW  = 6.6
)

var exposureRank = map[string]int{"local": 1, "tailnet": 2, "lan": 3, "public": 4}

// icons are the glyph symbols the SVG template defines. Any other kind falls
// back to "device" rather than drawing an empty head.
var icons = map[string]bool{
	"internet": true, "cloud": true, "dns": true, "user": true, "modem": true,
	"router": true, "switch": true, "ap": true, "server": true, "nas": true,
	"workstation": true, "laptop": true, "phone": true, "appliance": true,
	"kvm": true, "ups": true, "mesh": true, "device": true, "computer": true,
}

var roleKinds = map[string]string{
	"server":      "server",
	"laptop":      "laptop",
	"workstation": "workstation",
	"appliance":   "appliance",
}

// Build lays out spec against the merged state, as of the snapshot. The spec
// must have passed Validate against the inventory the state was merged from; a
// reference that still doesn't resolve (inventory changed underneath) is
// skipped rather than drawn wrong.
func Build(spec *Spec, m state.Merged, now time.Time) Diagram {
	if spec == nil {
		spec = Default()
	}
	width := spec.diagramWidth()
	hosts := map[string]state.HostView{}
	for _, h := range m.Hosts {
		hosts[h.Host] = h
	}
	svcByHost := map[string][]state.ServiceView{}
	for _, s := range m.Services {
		svcByHost[s.BoundHost] = append(svcByHost[s.BoundHost], s)
	}
	for _, list := range svcByHost {
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	}

	// Auto-place every inventory host the spec doesn't mention, so a new host
	// shows up without a spec edit.
	specs := append([]NodeSpec(nil), spec.Nodes...)
	placed := map[string]bool{}
	for _, n := range specs {
		if n.Host != "" {
			placed[n.Host] = true
		}
	}
	if spec.DefaultZone != "" {
		hidden := map[string]bool{}
		for _, h := range spec.Hide {
			hidden[h] = true
		}
		var auto []string
		for name := range hosts {
			if !placed[name] && !hidden[name] {
				auto = append(auto, name)
			}
		}
		sort.Strings(auto)
		for _, name := range auto {
			specs = append(specs, NodeSpec{Host: name, Zone: spec.DefaultZone})
		}
	}

	d := Diagram{Width: width, AsOf: now, Hubs: spec.Hubs}
	info := map[string]*NodeInfo{}
	nodes := map[string]*Node{}
	byZone := map[string][]*Node{}
	order := make([]string, 0, len(specs))
	for _, ns := range specs {
		n, ni := buildNode(ns, hosts, svcByHost, now)
		if n == nil {
			continue
		}
		nodes[n.ID] = n
		info[n.ID] = ni
		byZone[ns.Zone] = append(byZone[ns.Zone], n)
		order = append(order, n.ID)
	}

	// Derived edges first: they decide what a station can attach to.
	var edges []Edge
	add := func(from, to, kind, label string) {
		a, b := nodes[from], nodes[to]
		if a == nil || b == nil || from == to {
			return
		}
		for _, e := range edges {
			if e.From == from && e.To == to && e.Kind == kind {
				return
			}
		}
		edges = append(edges, Edge{
			From: from, To: to, Kind: kind, Layer: LayerOf(kind), Label: label,
			Live: a.live && b.live,
		})
	}
	for _, l := range spec.Links {
		add(l.From, l.To, l.Kind, l.Label)
	}

	rs := buildRoutes(spec, svcByHost, info, nodes)

	// Agent polling is a real, recorded relationship (fleet-edge asks each
	// agent every 30s). Tailnet membership is a station tag and per-route
	// leads, never a permanent rail.
	hostNode := map[string]string{}
	var hostNames []string
	for id, n := range nodes {
		if n.Host != "" {
			hostNode[n.Host] = id
			hostNames = append(hostNames, n.Host)
		}
	}
	sort.Strings(hostNames)
	for _, h := range hostNames {
		if spec.Hubs.Dashboard != "" && hosts[h].HasEndpoint {
			add(spec.Hubs.Dashboard, hostNode[h], "agent", "")
		}
	}
	// A public name enters through the edge; the host serving it branches off
	// the public collector (RouteLinks), so the fork is drawn for the whole
	// catalogue rather than as a layer-gated rail per owner.

	// Column layout: each column's regions stack, sharing that column's own
	// leftover height. Columns are independent, so a tall rack never pads the
	// route columns.
	widths := columnWidths(spec.Columns, width)
	type colPlan struct {
		col   Column
		x, w  int
		zones []*zonePlan
		nat   int
	}
	plans := make([]colPlan, 0, len(spec.Columns))
	target := spec.Height
	x := 0
	for i, c := range spec.Columns {
		cp := colPlan{col: c, x: x, w: widths[i]}
		for _, z := range c.Zones {
			zp := planZone(z, byZone[z.ID], len(rs.in(z)), cp.w)
			cp.zones = append(cp.zones, zp)
			cp.nat += zp.natural
		}
		if len(cp.zones) > 1 {
			cp.nat += zoneGapY * (len(cp.zones) - 1)
		}
		top := margin
		if c.Label != "" {
			top += colHead
		}
		cp.nat += top + margin
		target = max(target, cp.nat)
		plans = append(plans, cp)
		x += widths[i] + colGap
	}
	target = max(target, minZoneH)
	d.Height = target

	for _, cp := range plans {
		top := margin
		if cp.col.Label != "" {
			top += colHead
		}
		d.Columns = append(d.Columns, ColumnBox{
			ID: cp.col.ID, Label: cp.col.Label,
			X: cp.x, Y: margin, W: cp.w, H: target - margin,
		})
		// Leftover height goes only to the regions that asked to share it.
		natural := 0
		flexSum := 0.0
		for _, zp := range cp.zones {
			natural += zp.natural
			if zp.zone.Flex > 0 {
				flexSum += zp.zone.Flex
			}
		}
		natural += zoneGapY * max(0, len(cp.zones)-1)
		extra := float64(target - margin - top - natural)
		y := top
		for _, zp := range cp.zones {
			zp.h = zp.natural
			if flexSum > 0 && zp.zone.Flex > 0 {
				zp.h += int(math.Round(max(0, extra) * zp.zone.Flex / flexSum))
			}
			zp.x, zp.y, zp.w = cp.x, y, cp.w
			d.Zones = append(d.Zones, ZoneBox{
				ID: zp.zone.ID, Label: zp.zone.Label, Kind: zp.zone.Kind,
				X: zp.x, Y: zp.y, W: zp.w, H: zp.h, Box: zp.zone.Box, Zone: zp.zone,
			})
			if zp.zone.layout() != LayoutRoutes {
				placeZone(zp)
			}
			y += zp.h + zoneGapY
		}
	}

	// Station draw order is spec order, so later stations sit on top.
	for _, id := range order {
		d.Nodes = append(d.Nodes, *nodes[id])
	}

	routeStations(edges, nodes, &d)
	d.Edges = edges

	for _, e := range edges {
		a, b := nodes[e.From], nodes[e.To]
		info[e.From].Links = append(info[e.From].Links, LinkInfo{
			Kind: e.Kind, Layer: e.Layer, Peer: e.To, PeerLabel: b.Label, Label: e.Label, Out: true,
		})
		info[e.To].Links = append(info[e.To].Links, LinkInfo{
			Kind: e.Kind, Layer: e.Layer, Peer: e.From, PeerLabel: a.Label, Label: e.Label,
		})
	}
	for id, n := range nodes {
		info[id].X, info[id].Y = float64(n.CenterX()), float64(n.CenterY())
	}

	d.PublicZone = rs.cat
	d.RouteWeb, d.OverlayWeb = rs.place(&d, nodes)
	// The public cloud groups into the edge hub; the overlay cloud groups into
	// one bundled trunk that branches once per owning host.
	if z, ok := rs.zoneOf(&d, GroupOverlay); ok {
		d.OverlayBrace = rs.brace(&d, z, GroupOverlay, nodes)
	}
	if z, ok := rs.zoneOf(&d, GroupPublic); ok {
		d.RouteBrace = rs.brace(&d, z, GroupPublic, nodes)
	}
	d.RouteLinks = append(rs.overlayBranches(&d, nodes), rs.publicBranches(&d, nodes)...)

	nodesMeta, _ := json.Marshal(info)
	d.Meta = string(nodesMeta)
	doc, _ := json.Marshal(routeDoc{Groups: rs.groups(&d), DNS: d.PublicZone, Links: d.RouteLinks})
	d.RouteMeta = string(doc)
	return d
}

// diagramWidth is the width Build lays out at: the spec's, or DefaultWidth.
func (s *Spec) diagramWidth() int {
	if s.Width <= 0 {
		return DefaultWidth
	}
	return s.Width
}

func columnFlex(c Column) float64 {
	if c.Flex <= 0 {
		return 1
	}
	return c.Flex
}

// columnWidths splits the diagram width across its columns in proportion to
// flex, giving the last column whatever is left. Validate uses this very same
// arithmetic, so a spec it accepts always lays out in bounds.
func columnWidths(cols []Column, width int) []int {
	n := len(cols)
	if n == 0 {
		return nil
	}
	widths := make([]int, n)
	total := 0.0
	for _, c := range cols {
		total += columnFlex(c)
	}
	avail := float64(width - colGap*(n-1))
	x := 0
	for i, c := range cols {
		w := int(math.Round(avail * columnFlex(c) / total))
		if i == n-1 {
			w = width - x
		}
		widths[i] = w
		x += w + colGap
	}
	return widths
}

// zonePlan is one region's placement: its stations, its natural height and
// where it ended up.
type zonePlan struct {
	zone    Zone
	nodes   []*Node
	rows    [][]*Node
	rowH    []int
	natural int
	x, y, w int
	h       int
}

// planZone measures a region from its contents. The height is what the
// contents need; Build then hands it a share of the column's leftover.
func planZone(z Zone, items []*Node, chipCount, width int) *zonePlan {
	zp := &zonePlan{zone: z, nodes: items}
	if z.layout() == LayoutRoutes {
		if chipCount == 0 {
			zp.natural = minZoneH
			return zp
		}
		cols := chipCols(z, width)
		rows := (chipCount + cols - 1) / cols
		zp.natural = max(zoneHead+rows*(chipH+chipGap)-chipGap+zonePad, minZoneH)
		return zp
	}
	if len(items) == 0 {
		zp.natural = minZoneH
		return zp
	}
	zp.rows, zp.rowH = planRows(z, items, width)
	h := zoneHead + zonePad
	for _, rh := range zp.rowH {
		h += rh + stationGY
	}
	if len(zp.rowH) > 0 {
		h -= stationGY
	}
	zp.natural = max(h, minZoneH)
	return zp
}

// planRows groups stations into rows that fit the region's inner width. A
// segment always takes a row of its own: a fabric spans the region instead of
// sitting in a cell.
func planRows(z Zone, items []*Node, width int) ([][]*Node, []int) {
	perRow := z.Cols
	if z.layout() == LayoutStack && perRow <= 0 {
		// A stack is a list, not a grid: without an explicit column count it is
		// one item per row, in declaration order, which is what makes rack
		// order readable top to bottom. An explicit Cols still reads down the
		// first column before starting the next.
		perRow = 1
	} else if perRow <= 0 {
		perRow = max(1, (width-2*zonePad+stationGX)/(stationW+stationGX))
	}
	var rows [][]*Node
	var hs []int
	addRow := func(row []*Node) {
		h := 0
		for _, n := range row {
			h = max(h, n.H)
		}
		rows = append(rows, row)
		hs = append(hs, h)
	}
	var pending []*Node
	flush := func() {
		if len(pending) > 0 {
			addRow(pending)
			pending = nil
		}
	}
	for _, n := range items {
		if n.Segment {
			flush()
			addRow([]*Node{n})
			continue
		}
		pending = append(pending, n)
		if len(pending) == perRow {
			flush()
		}
	}
	flush()
	if z.fill() != "column" || len(rows) == 0 {
		return rows, hs
	}
	// Column fill reads down the first column, then the next — the order a
	// rack is listed in.
	grid := make([][]*Node, len(rows))
	gridH := make([]int, len(rows))
	for i, n := range items {
		r := i % len(rows)
		grid[r] = append(grid[r], n)
		gridH[r] = max(gridH[r], n.H)
	}
	return grid, gridH
}

// placeZone fixes every station's absolute box inside its region.
func placeZone(zp *zonePlan) {
	inner := zp.w - 2*zonePad
	cy := zp.y + zoneHead
	for i, row := range zp.rows {
		h := zp.rowH[i]
		var rowW int
		for _, n := range row {
			if n.Segment {
				// A segment spans its region, not one station: the bar follows
				// the box it was widened to.
				n.W = inner
				n.SegX1, n.SegX2 = 0, n.W
				n.SegY1, n.SegY2 = 0, n.H
			}
			rowW += n.W + stationGX
		}
		if len(row) > 0 {
			rowW -= stationGX
		}
		cx := zp.x + zonePad + max(0, (inner-rowW)/2)
		for _, n := range row {
			n.X, n.Y = cx, cy+(h-n.H)/2
			cx += n.W + stationGX
		}
		cy += h + stationGY
	}
}

// chipCols is how many route chips fit side by side in a region of this
// width. Both measuring and drawing use it, so a region is never short of
// rows for the chips it holds.
func chipCols(z Zone, width int) int {
	if z.Cols > 0 {
		return z.Cols
	}
	if width <= 0 {
		return 2
	}
	return max(1, (width-2*zonePad-braceGutter)/chipMinW)
}

// --- route cloud -----------------------------------------------------------

// routeSet is the derived public/overlay cloud plus the catalogue behind it.
type routeSet struct {
	public  []RouteMarker
	overlay []RouteMarker
	cat     PublicZone
	hub     string // node the public brace leads into
}

// in returns the markers belonging in a region.
func (r *routeSet) in(z Zone) []RouteMarker {
	switch z.Group {
	case GroupPublic:
		return r.public
	case GroupOverlay:
		return r.overlay
	}
	return nil
}

// buildRoutes derives both clouds from the declared routes and the spec's DNS
// zone. One marker per name: aliases and several routes behind one FQDN share
// a marker, and a name the zone declares without a route stays faint.
func buildRoutes(spec *Spec, svcByHost map[string][]state.ServiceView, info map[string]*NodeInfo, nodes map[string]*Node) *routeSet {
	rs := &routeSet{hub: spec.Hubs.Edge}
	zone := ""
	if spec.DNS != nil {
		zone = spec.DNS.Zone
		rs.cat = PublicZone{Zone: zone, Available: zone != "", Records: append([]DNSRecord(nil), spec.DNS.Records...), External: append([]string(nil), spec.DNS.External...)}
	}
	claimed := map[string]*DNSRecord{}
	for i := range rs.cat.Records {
		rec := &rs.cat.Records[i]
		// Ownership is never inherited from the spec: it is proven below by a
		// declared route, and left unset otherwise.
		rec.Declared, rec.Host, rec.Service, rec.RouteKey = false, "", "", ""
		key := strings.ToLower(strings.TrimSuffix(rec.FQDN(zone), "."))
		if _, ok := claimed[key]; !ok {
			claimed[key] = rec
		}
	}

	// Which service owns a shared FQDN must not depend on host order: two
	// hosts can serve the same name (a mirror), and host order would silently
	// hand the name to whichever host sorts first. Services are walked in
	// name order instead, so the same service keeps the name when it moves.
	type serviceRef struct {
		host string
		svc  state.ServiceView
	}
	var refs []serviceRef
	for h, list := range svcByHost {
		if h == "" {
			continue
		}
		for _, s := range list {
			refs = append(refs, serviceRef{host: h, svc: s})
		}
	}
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].svc.Name != refs[j].svc.Name {
			return refs[i].svc.Name < refs[j].svc.Name
		}
		return refs[i].host < refs[j].host
	})

	public := map[string]RouteMarker{}
	var publicOrder []string
	overlay := map[string]RouteMarker{}
	var overlayOrder []string
	nodeOf := map[string]string{}
	for id, n := range nodes {
		if n.Host != "" {
			nodeOf[n.Host] = id
		}
	}

	for _, ref := range refs {
		h, s := ref.host, ref.svc
		for i, rt := range s.Routes {
			fqdn := strings.TrimSuffix(rt.FQDNStr(), ".")
			if fqdn == "" {
				continue
			}
			key := strings.ToLower(fqdn)
			switch rt.Exposure {
			case "public":
				if _, ok := public[key]; ok {
					continue
				}
				m := RouteMarker{
					ID: GroupPublic + "/" + fqdn, Group: GroupPublic,
					Label: shortName(fqdn, zone), FQDN: fqdn,
					Host: h, NodeID: nodeOf[h], Service: s.Name, RouteKey: routeKey(rt, i),
					Exposure: rt.Exposure, Via: append([]string(nil), rt.Via...),
					Proto: rt.Proto, Port: rt.Port, Declared: true,
				}
				if rec, ok := claimed[key]; ok {
					m.DNSName = rec.Name
					rec.Declared, rec.Host, rec.Service, rec.RouteKey = true, h, s.Name, m.RouteKey
				}
				public[key] = m
				publicOrder = append(publicOrder, key)
			case "tailnet":
				if _, ok := overlay[key]; ok {
					continue
				}
				overlay[key] = RouteMarker{
					ID: GroupOverlay + "/" + fqdn, Group: GroupOverlay,
					Label: shortName(fqdn, zone), FQDN: fqdn,
					Host: h, NodeID: nodeOf[h], Service: s.Name, RouteKey: routeKey(rt, i),
					Exposure: rt.Exposure, Via: append([]string(nil), rt.Via...),
					Proto: rt.Proto, Port: rt.Port, Declared: true,
				}
				overlayOrder = append(overlayOrder, key)
			}
		}
	}

	// Names the zone declares that no route serves: real DNS, drawn faint, with
	// no host. Nothing is inferred through a CNAME chain.
	for i := range rs.cat.Records {
		rec := &rs.cat.Records[i]
		fqdn := rec.FQDN(zone)
		key := strings.ToLower(fqdn)
		if rec.Declared {
			continue
		}
		if _, ok := public[key]; ok {
			continue
		}
		public[key] = RouteMarker{
			ID: GroupPublic + "/" + fqdn, Group: GroupPublic,
			Label: shortName(fqdn, zone), FQDN: fqdn, DNSName: rec.Name,
		}
		publicOrder = append(publicOrder, key)
	}

	for _, k := range publicOrder {
		rs.public = append(rs.public, public[k])
	}
	for _, k := range overlayOrder {
		rs.overlay = append(rs.overlay, overlay[k])
	}
	// Declared names first, then the zone's remaining names, then alphabetical.
	sort.SliceStable(rs.public, func(i, j int) bool {
		if rs.public[i].Declared != rs.public[j].Declared {
			return rs.public[i].Declared
		}
		return rs.public[i].Label < rs.public[j].Label
	})
	sort.SliceStable(rs.overlay, func(i, j int) bool { return rs.overlay[i].Label < rs.overlay[j].Label })

	// Per-host routes carry the DNS name serving them, for the sidebar.
	for _, ni := range info {
		for i := range ni.Routes {
			key := strings.ToLower(strings.TrimSuffix(ni.Routes[i].FQDN, "."))
			if rec, ok := claimed[key]; ok {
				ni.Routes[i].DNS = rec.Name
			}
		}
	}
	return rs
}

// shortName is the name inside the zone ("git" for git.joshuabell.xyz), which
// is what the zone calls the record — never the service or route name when it
// differs.
func shortName(fqdn, zone string) string {
	f := strings.TrimSuffix(fqdn, ".")
	if zone != "" {
		if rest, ok := strings.CutSuffix(f, "."+zone); ok {
			return rest
		}
	}
	if i := strings.IndexByte(f, '.'); i > 0 {
		return f[:i]
	}
	return f
}

// zoneOf finds the drawn region holding a cloud.
func (r *routeSet) zoneOf(d *Diagram, group string) (ZoneBox, bool) {
	for _, z := range d.Zones {
		if z.Zone.Group == group {
			return z, true
		}
	}
	return ZoneBox{}, false
}

// place commits every marker's final chip rectangle inside its region and
// returns the two clouds.
func (r *routeSet) place(d *Diagram, nodes map[string]*Node) ([]RouteMarker, []RouteMarker) {
	lay := func(group string, markers []RouteMarker) []RouteMarker {
		z, ok := r.zoneOf(d, group)
		if !ok {
			return nil
		}
		return layChips(z, markers)
	}
	return lay(GroupPublic, r.public), lay(GroupOverlay, r.overlay)
}

// layChips lays one cloud out against its region's left edge. The right of the
// region is left to the brace, so a chip never sits under it.
func layChips(z ZoneBox, markers []RouteMarker) []RouteMarker {
	n := len(markers)
	if n == 0 {
		return nil
	}
	inner := z.W - 2*zonePad - braceGutter
	cols := min(chipCols(z.Zone, z.W), n)
	cellW := float64(inner) / float64(cols)
	rows := (n + cols - 1) / cols
	out := make([]RouteMarker, n)
	cy := z.Y + zoneHead
	for row := range rows {
		for c := range cols {
			i := row*cols + c
			if i >= n {
				break
			}
			m := markers[i]
			m.X = z.X + zonePad + int(math.Round(float64(c)*cellW))
			m.Y = cy
			m.W = int(math.Round(cellW)) - chipGap
			m.H = chipH
			m.TX = m.X + 9
			m.TY = m.Y + 15
			m.Label = truncate(m.Label, max(2, int(float64(m.W-14)/smallCharW)))
			out[i] = m
		}
		cy += chipH + chipGap
	}
	return out
}

// brace groups a cloud's committed markers and leads the collector away from
// them: the public cloud into the edge hub, the overlay cloud into the trunk
// its branches hang from.
func (r *routeSet) brace(d *Diagram, z ZoneBox, group string, nodes map[string]*Node) *RouteBrace {
	markers := d.RouteWeb
	if group == GroupOverlay {
		markers = d.OverlayWeb
	}
	if len(markers) == 0 {
		return nil
	}
	top, bottom := markers[0].Y, markers[0].Y+markers[0].H
	for _, m := range markers[1:] {
		top = min(top, m.Y)
		bottom = max(bottom, m.Y+m.H)
	}
	spine := z.X + z.W - zonePad - braceW
	b := &RouteBrace{
		Group: group, Top: top, Bottom: bottom, Mid: (top + bottom) / 2,
		SpineX: spine, TipX: spine + braceW,
		D: bracePath(spine, top, bottom),
	}
	if group != GroupPublic {
		// The trunk continues past the brace to a shared bus the branches
		// leave from; one stub, not one lead per name.
		b.LeadD = fmt.Sprintf("M%d %d H%d", b.TipX, b.Mid, b.TipX+trunkLen)
		return b
	}
	n := nodes[r.hub]
	if n == nil {
		return b
	}
	b.Hub, b.HubX, b.HubY = r.hub, n.CenterX(), n.CenterY()
	b.LeadD = elbowPath(float64(b.TipX), float64(b.Mid),
		float64(n.CenterX()-n.R), float64(n.CenterY()))
	return b
}

// trunkLen is how far the overlay's shared collector runs before branching.
const trunkLen = 22

// overlayBranches is one branch per owning host: the shared trunk splits once
// per destination instead of drawing a lead from every chip.
func (r *routeSet) overlayBranches(d *Diagram, nodes map[string]*Node) []RouteLink {
	b := r.overlayBrace(d)
	if b == nil {
		return nil
	}
	busX := b.TipX + trunkLen
	seen := map[string]bool{}
	var links []RouteLink
	for _, m := range r.overlay {
		if m.NodeID == "" || seen[m.NodeID] {
			continue
		}
		n := nodes[m.NodeID]
		if n == nil {
			continue
		}
		seen[m.NodeID] = true
		toX := n.CenterX() - n.R
		gutter := columnGutter(d, n)
		rail := float64(d.Columns[0].Y - 12)
		points := [5][2]float64{{float64(busX), float64(b.Mid)}, {float64(busX), rail}, {gutter, rail}, {gutter, float64(n.CenterY())}, {float64(toX), float64(n.CenterY())}}
		links = append(links, RouteLink{
			Group: GroupOverlay, Host: m.Host, ToID: m.NodeID,
			FromX: busX, FromY: b.Mid, ToX: toX, ToY: n.CenterY(),
			D: roundedPath(points[:]),
		})
	}
	return links
}

// publicBranches is the public cloud's fork: one branch per host that serves a
// public name, drawn from the edge hub out to that host. They are part of the
// always-on picture, not a toggleable layer: the whole catalogue's reach is
// visible at once, and selecting a route only emphasises its own branch.
func (r *routeSet) publicBranches(d *Diagram, nodes map[string]*Node) []RouteLink {
	hub := nodes[r.hub]
	if hub == nil {
		return nil
	}
	seen := map[string]bool{}
	var links []RouteLink
	for _, m := range r.public {
		if m.NodeID == "" || seen[m.NodeID] {
			continue
		}
		n := nodes[m.NodeID]
		if n == nil || n == hub {
			continue
		}
		seen[m.NodeID] = true
		// From the hub's right edge to the host's left edge: a branch leaves
		// the edge outward, so it never cuts back through the hub itself.
		links = append(links, RouteLink{
			Group: GroupPublic, Host: m.Host, ToID: m.NodeID,
			FromX: hub.CenterX() + hub.R, FromY: hub.CenterY(),
			ToX: n.CenterX() - n.R, ToY: n.CenterY(),
			D: publicStationPath(d, hub, n),
		})
	}
	return links
}

// overlayBrace is the committed overlay brace, which exists only after the
// overlay region was drawn.
func (r *routeSet) overlayBrace(d *Diagram) *RouteBrace {
	if d.OverlayBrace != nil {
		return d.OverlayBrace
	}
	return nil
}

// groups is the route document's group list: both clouds with their geometry.
func (r *routeSet) groups(d *Diagram) []routeGroup {
	var out []routeGroup
	add := func(group, label, color string, markers []RouteMarker, b *RouteBrace) {
		z, ok := r.zoneOf(d, group)
		if !ok || len(markers) == 0 {
			return
		}
		g := routeGroup{
			ID: group, Label: label, Color: color,
			X: z.X, Y: z.Y, W: z.W, H: z.H, Routes: markers,
		}
		if b != nil {
			// The lead is part of the cloud, not a decoration: the public
			// trunk runs from the brace to the edge hub, the overlay stub to
			// its shared bus. A client that redraws from this document must
			// get the same trunk the diagram itself draws.
			g.Brace, g.Lead = b.D, b.LeadD
			g.Collector = Point{X: b.TipX, Y: b.Mid}
		}
		out = append(out, g)
	}
	add(GroupPublic, "Public DNS", "amber", d.RouteWeb, d.RouteBrace)
	add(GroupOverlay, "Overlay names", "purple", d.OverlayWeb, d.OverlayBrace)
	return out
}

// bracePath is a genuine curly brace spanning top..bottom: spines on the
// markers' side, a point bulging away from them at the vertical middle. The
// lead is a separate path, so the two can be styled apart.
func bracePath(spineX, top, bottom int) string {
	x := float64(spineX)
	tip := x + braceW
	y0, y1 := float64(top), float64(bottom)
	mid := (y0 + y1) / 2
	const hook = 6 // how far the ends curl back toward the markers
	return fmt.Sprintf(
		"M%.0f %.0f Q%.0f %.0f %.0f %.0f L%.0f %.0f Q%.0f %.0f %.0f %.0f Q%.0f %.0f %.0f %.0f L%.0f %.0f Q%.0f %.0f %.0f %.0f",
		x-hook, y0,
		x, y0, x, y0+hook,
		x, mid-braceW,
		x, mid-4, tip, mid,
		x, mid+4, x, mid+braceW,
		x, y1-hook,
		x, y1, x-hook, y1,
	)
}

// roundedPath retains the endpoints and straight runs of a polyline while
// replacing each turn with a tangent quadratic Bézier. Short runs limit the
// radius so neighbouring corners cannot overlap.
func roundedPath(points [][2]float64) string {
	var clean [8][2]float64
	n := 0
	for _, p := range points {
		if n > 0 && clean[n-1] == p {
			continue
		}
		if n > 1 {
			a, b := clean[n-2], clean[n-1]
			if (b[0]-a[0])*(p[1]-b[1]) == (b[1]-a[1])*(p[0]-b[0]) && (b[0]-a[0])*(p[0]-b[0])+(b[1]-a[1])*(p[1]-b[1]) > 0 {
				n--
			}
		}
		clean[n] = p
		n++
	}
	if n == 0 {
		return ""
	}
	var d strings.Builder
	fmt.Fprintf(&d, "M%.1f %.1f", clean[0][0], clean[0][1])
	for i := 1; i < n-1; i++ {
		a, b, c := clean[i-1], clean[i], clean[i+1]
		before, after := math.Hypot(b[0]-a[0], b[1]-a[1]), math.Hypot(c[0]-b[0], c[1]-b[1])
		r := min(14.0, before/2, after/2)
		enter := [2]float64{b[0] + (a[0]-b[0])*r/before, b[1] + (a[1]-b[1])*r/before}
		leave := [2]float64{b[0] + (c[0]-b[0])*r/after, b[1] + (c[1]-b[1])*r/after}
		fmt.Fprintf(&d, " L%.1f %.1f Q%.1f %.1f %.1f %.1f", enter[0], enter[1], b[0], b[1], leave[0], leave[1])
	}
	if n > 1 {
		fmt.Fprintf(&d, " L%.1f %.1f", clean[n-1][0], clean[n-1][1])
	}
	return d.String()
}

// elbowPath takes the collector outward to a gutter before crossing above
// the destination head, rather than cutting left through the name badges.
func elbowPath(x1, y1, x2, y2 float64) string {
	gutter, rail := max(x1, x2)+24, min(y1, y2)-36
	points := [6][2]float64{{x1, y1}, {gutter, y1}, {gutter, rail}, {x2 - 24, rail}, {x2 - 24, y2}, {x2, y2}}
	return roundedPath(points[:])
}

// columnGutter is inside the column margin but outside station footprints.
// A zone can pack several station columns; their shared outer gutter avoids
// running past a neighbouring station's long label or gauge band.
func columnGutter(d *Diagram, n *Node) float64 {
	for _, c := range d.Columns {
		if n.CenterX() >= c.X && n.CenterX() <= c.X+c.W {
			return float64(c.X + 8)
		}
	}
	return float64(n.X - 12)
}

// stationPath leaves through head rims and joins column gutters above the
// regions, keeping vertical runs away from every station's readout band.
func stationPath(d *Diagram, a, b *Node) string {
	p1, p2 := a.anchor(left), b.anchor(left)
	ga, gb := columnGutter(d, a), columnGutter(d, b)
	if ga == gb {
		points := [4][2]float64{p1, {ga, p1[1]}, {gb, p2[1]}, p2}
		return roundedPath(points[:])
	}
	rail := float64(d.Columns[0].Y - 12)
	points := [6][2]float64{p1, {ga, p1[1]}, {ga, rail}, {gb, rail}, {gb, p2[1]}, p2}
	return roundedPath(points[:])
}

func publicStationPath(d *Diagram, hub, n *Node) string {
	p1, p2 := hub.anchor(right), n.anchor(left)
	ga := float64(hub.X + hub.W + 12)
	gb, rail := columnGutter(d, n), float64(d.Columns[0].Y-12)
	points := [6][2]float64{p1, {ga, p1[1]}, {ga, rail}, {gb, rail}, {gb, p2[1]}, p2}
	return roundedPath(points[:])
}

// --- stations --------------------------------------------------------------

// up reports whether the host is confirmed present: the merge already folds
// the poll into StateBadge and Reachable, so the diagram never re-judges how
// old a poll may be (the poll interval is configurable).
func up(hv state.HostView) bool {
	return hv.StateBadge == "online" && hv.Reachable
}

// clamp01 bounds a gauge fraction; a reported 103% is drawn full, never wider
// than its track.
func clamp01(f float64) float64 {
	switch {
	case f < 0 || math.IsNaN(f):
		return 0
	case f > 1:
		return 1
	}
	return f
}

// buildNode fills a station's content and its drilldown payload.
func buildNode(ns NodeSpec, hosts map[string]state.HostView, svcByHost map[string][]state.ServiceView, now time.Time) (*Node, *NodeInfo) {
	n := &Node{
		ID: ns.nodeID(), Label: ns.Label, Kind: ns.Kind, Host: ns.Host,
		Role: ns.Role, State: "static", live: true, Segment: ns.Segment,
	}
	ni := &NodeInfo{Href: ns.Href, Role: ns.Role, Live: true, Reachable: true}
	ni.Lines = append([]string(nil), ns.Lines...)
	ni.Badges = append([]string(nil), ns.Badges...)
	if ns.Host != "" {
		hv, ok := hosts[ns.Host]
		if !ok {
			return nil, nil
		}
		n.State = hv.StateBadge
		n.live = up(hv)
		n.Tailnet = hv.OverlayIP != ""
		n.ContainerHost, ni.ContainerHost = hv.ContainerHost, hv.ContainerHost
		ni.Host, ni.OverlayIP, ni.LanIP = ns.Host, hv.OverlayIP, hv.LanIP
		ni.Live, ni.Reachable = n.live, hv.Reachable
		ni.LastSeen, ni.LastSeenAge, ni.PolledAt = hv.LastSeen, hv.LastSeenAge, hv.PolledAt
		ni.BannedCount = hv.BannedCount
		if n.Role == "" {
			n.Role, ni.Role = hv.Role, hv.Role
		}
		if ni.Href == "" && hv.HasEndpoint {
			ni.Href = "/hosts/" + ns.Host
		}
		ni.StateText = stateText(hv, now)
		if n.Kind == "" {
			n.Kind = roleKinds[hv.Role]
		}
		if hv.Status != nil {
			st := hv.Status
			ni.StatusTime = st.Time
			ni.Filesystems, ni.Fail2ban = st.Filesystems, st.Fail2ban
			ni.Smart = st.Smart
			ni.SmartTotal = len(st.Smart)
			for _, dr := range st.Smart {
				switch {
				case driveUnhealthy(dr):
					ni.SmartFailed++
				case !dr.Standby:
					ni.SmartOK++
				}
			}
			ni.DiskWarnings = diskProblems(st)
			ni.Mounts, n.Rings = mountRings(st.Filesystems, ns.Host, now)
			// Gauges come from the host's current poll. An absent host's last
			// numbers are history: the drilldown still shows them, but the
			// station draws no bar rather than a stale one that looks live.
			if n.live && st.System != nil {
				ni.System = st.System
				if st.System.CPUPercent >= 0 {
					n.CPUAvailable, n.CPUPercent = true, st.System.CPUPercent
				}
				if st.System.MemTotalBytes > 0 {
					n.MemAvailable = true
					n.MemPercent = float64(st.System.MemUsedBytes) / float64(st.System.MemTotalBytes) * 100
				}
			}
		}
		if m := systemLine(hv); m != "" && n.live {
			ni.Lines = append(ni.Lines, m)
		}
		for _, s := range svcByHost[ns.Host] {
			var exp string
			rank := 0
			var urls []string
			public, viaRouter := false, false
			si := ServiceInfo{Name: s.Name, State: s.Active, Description: s.Description}
			for i, r := range s.Routes {
				if exposureRank[r.Exposure] > rank {
					exp, rank = r.Exposure, exposureRank[r.Exposure]
				}
				ri := RouteInfo{
					ID: s.Name + "/" + routeKey(r, i), Label: routeLabel(r),
					FQDN: strings.TrimSuffix(r.FQDNStr(), "."), URL: r.URLStr(),
					Host: ns.Host, NodeID: n.ID, Service: s.Name, RouteKey: routeKey(r, i),
					Exposure: r.Exposure, Via: append([]string(nil), r.Via...),
					Proto: r.Proto, Port: r.Port,
				}
				if r.Exposure == "public" {
					// Only a public route can be public, and where it enters
					// decides the hub: the edge, or the router if it
					// terminates there. Anything else is not a public path.
					switch {
					case contains(r.Via, "edge"):
						public, ri.Public = true, true
					case contains(r.Via, "router"):
						viaRouter, ri.ViaRouter = true, true
					}
				}
				if u := r.URLStr(); u != "" {
					urls = append(urls, u)
				}
				if si.Proto == "" && r.Proto != "" {
					si.Proto, si.Port = r.Proto, r.Port
				}
				ni.Routes = append(ni.Routes, ri)
			}
			sort.Strings(urls)
			si.Exposure, si.URLs, si.Public, si.ViaRouter = exp, urls, public, viaRouter
			if s.Active != "" && s.Active != "active" && s.Active != "unknown" {
				ni.SvcFailed++
			}
			ni.Services = append(ni.Services, si)
			n.SvcCount++
		}
	}
	// No station ever draws an empty heading.
	if n.Label == "" {
		n.Label = ns.Host
	}
	if n.Label == "" {
		n.Label = n.ID
	}
	if n.Kind == "" {
		n.Kind = "device"
	}
	if n.Role == "" {
		n.Role = n.Kind
	}
	n.Icon = n.Kind
	if !icons[n.Icon] {
		n.Icon = "device"
	}
	n.Tags = strings.Join(ns.Badges, " · ")
	ni.Label, ni.Kind, ni.State, ni.Role = n.Label, n.Kind, n.State, n.Role
	n.SvcFailed, n.Warn, n.BannedCount = ni.SvcFailed, ni.DiskWarnings, ni.BannedCount
	n.Title = n.Label + " · " + n.Role
	if ni.StateText != "" && ni.StateText != "online" {
		n.Title += " — " + ni.StateText
	}
	if ns.Segment {
		n.W, n.H = stationW, segH
		n.HeadX, n.HeadY = n.W/2, n.H/2
		n.LabelY, n.RoleY, n.TagsY = n.HeadY+4, n.HeadY+16, n.HeadY+26
		n.SegX1, n.SegX2, n.SegY1, n.SegY2 = 0, n.W, 0, n.H
		n.IconX, n.IconY, n.DotX = n.HeadX, n.HeadY, n.HeadX
		n.TsX, n.TsY, n.CountX, n.CountY, n.WarnY = n.HeadX, n.HeadY, n.HeadX, n.HeadY, n.HeadY
		n.R = 0
		n.Label = truncate(n.Label, max(2, int(float64(n.W-16)/labelCharW)))
		n.Role = truncate(n.Role, max(2, int(float64(n.W-16)/smallCharW)))
		return n, ni
	}
	finishNode(n)
	return n, ni
}

// finishNode fixes a station's box and its box-local geometry: head circle,
// name, role, then one quiet line of membership tags. The box grows to hold
// every space ring: the head sits low enough for the outermost ring's top and
// the text starts below its bottom, so no ring ever crosses a name. The ring
// arcs are drawn here, once the head centre is final — a ring is concentric
// with the head, so an arc computed before this point would be off-centre.
func finishNode(n *Node) {
	n.W = stationW
	ringMax := 0
	if len(n.Rings) > 0 {
		ringMax = n.Rings[len(n.Rings)-1].R
	}
	n.R = stationR
	n.HeadX = stationW / 2
	n.HeadY = max(stationR+6, ringMax+stationR/2)
	cx, cy := float64(n.HeadX), float64(n.HeadY)
	for i := range n.Rings {
		n.Rings[i].D = arcPath(cx, cy, float64(n.Rings[i].R), n.Rings[i].Pct)
	}
	// The name's baseline clears whatever is largest around the head — the
	// outermost space ring when the host has mounts, otherwise the head circle
	// itself — plus the ring's stroke. Clearing only ringMax put a ringless
	// node's 21px name through its own circle and left a ringed one's name on
	// the ring. 19 is the ascent of the 21px name above its baseline.
	n.LabelY = n.HeadY + max(ringMax, n.R) + 4 + 19
	// Role and tags are display:none at rest — the side panel and the title
	// carry them — so neither owns a band. RoleY still points where the role
	// would print, one name-box under the label, for anything that reads it.
	n.RoleY = n.LabelY + labelGap
	// Captions are 16px, so the cpu baseline sits one caption-step under the
	// name and the mem baseline a full box below that; at the old 16-unit
	// pitch the two captions overlapped on every gauged station.
	//
	// Bars exist only when the host's latest poll is current. An absent host
	// draws no bar and prints one "cpu — · mem —" caption at TagsY instead, so
	// the band is reserved either way and counts stay on one baseline across a
	// rack row.
	n.GaugeX, n.GaugeW = 12, stationW-24
	n.GaugeY = n.LabelY + 20
	n.CPUBarY, n.MemBarY = n.GaugeY, n.GaugeY+gaugePitch
	if n.CPUAvailable {
		n.CPUFill = int(math.Round(float64(n.GaugeW) * clamp01(n.CPUPercent/100)))
	}
	if n.MemAvailable {
		n.MemFill = int(math.Round(float64(n.GaugeW) * clamp01(n.MemPercent/100)))
	}
	n.TagsY = n.MemBarY + tagsClear

	// The service and health counts are 12px type, and the space beside the
	// head is only ~62 units wide: a joined "1 to check · 3 banned" (126
	// units) spilled ~55 units into the neighbouring station there. The
	// counts get their own band under the badges instead, anchored to the
	// station's inner edge, where the longest line fits with room to spare.
	countRows := 0
	if n.SvcCount > 0 {
		n.CountX, n.CountY = countInset, n.TagsY+countLine
		countRows++
	}
	if n.Warn > 0 || n.BannedCount > 0 {
		n.CountX = countInset
		n.WarnY = n.TagsY + countLine + countRows*countLine
		countRows++
	}
	n.H = n.TagsY + 8 + countRows*countLine
	// The head's furniture is anchored on the head centre, which is only final
	// here: a 20px icon is placed by its top-left corner, so -10/-10 centres it
	// on the head; the state dot sits on the head's left rim, and the tailnet
	// marker hangs just under it. All three are box-local, so they must be
	// written after HeadX/HeadY and never left at their zero value — a zeroed
	// anchor drew every icon at the station's top-left corner instead of on
	// the circle it describes.
	n.IconX, n.IconY = n.HeadX-10, n.HeadY-10
	n.DotX = n.HeadX - n.R - 4
	n.TsX, n.TsY = n.HeadX-5, n.HeadY+n.R-5
}

// mountRings turns the reported mounts into static rings: one per filesystem
// primary mount, each with its own shade. Nothing is fabricated — a host that
// reported no filesystem gets no ring — and no ring claims to be a measurement.
//
// Radii are capped so the outermost ring still fits the station's width, and
// every ring gets a distinct shade index and its own colour rather than
// cycling a small palette: two filesystems must never look like one.
func mountRings(fs []state.FilesystemMount, host string, now time.Time) ([]MountInfo, []RingArc) {
	if len(fs) == 0 {
		return nil, nil
	}
	// A submount is an alias of the filesystem that carries it, so its space
	// is already drawn: only primaries get rings.
	nested := map[string]bool{}
	for _, f := range fs {
		for _, sub := range f.Submounts {
			nested[sub] = true
		}
	}
	seen := map[string]bool{}
	var primary []state.FilesystemMount
	for _, f := range fs {
		if f.Mount == "" || seen[f.Mount] {
			continue
		}
		seen[f.Mount] = true
		if nested[f.Mount] {
			continue
		}
		primary = append(primary, f)
	}
	sort.Slice(primary, func(i, j int) bool { return primary[i].Mount < primary[j].Mount })

	// Rings are concentric with the head, so the outermost must stay inside the
	// station's width whatever a host reports; crowding the step keeps every
	// ring distinct instead of letting the box grow sideways.
	maxR := stationW/2 - ringStroke - 2
	step := ringStep
	if n := len(primary); n > 1 && ringR0+ringStep*(n-1) > maxR {
		step = max(1, (maxR-ringR0)/(n-1))
	}
	var infos []MountInfo
	var rings []RingArc
	for i, f := range primary {
		frac := simFraction(now, host, f.Mount)
		r := min(ringR0+step*i, maxR)
		color := ringColor(i, len(primary))
		infos = append(infos, MountInfo{
			ID: host + "/" + f.Mount, Mount: f.Mount,
			Submounts:         append([]string(nil), f.Submounts...),
			ActualUsed:        f.UsedBytes,
			ActualTotal:       f.TotalBytes,
			SimulatedFraction: frac,
			Radius:            r,
			StrokeWidth:       ringStroke,
			Shade:             i,
			Color:             color,
		})
		rings = append(rings, RingArc{R: r, Shade: i, Color: color, Pct: frac, Mount: f.Mount})
	}
	return infos, rings
}

// ringColor is the per-index colour of a mount's ring. One hue, always blue:
// a ring must never be read as the purple overlay or the amber public cloud,
// so mounts are told apart by lightness and saturation alone. Two mounts are
// dark blue then light blue; a lone mount sits in the middle.
func ringColor(i, n int) string {
	const hue, lightMid = 205.0, 55.0
	light, sat := lightMid, 50.0
	if n > 1 {
		t := float64(i) / float64(n-1)
		light = 45 + 25*t
		sat = 44 + 14*t
	}
	return fmt.Sprintf("hsl(%.0f %.0f%% %.1f%%)", hue, sat, light)
}

// simFraction is the simulated fill of a mount: deterministic in the snapshot
// hour, the host and the mount, so replaying an instant redraws the same ring
// and the value can never be mistaken for a measurement. The separators keep
// ("a/b", "c") and ("a", "b/c") apart. The key is hashed in one pass over a
// stack buffer, so a ring costs no allocation per redraw.
func simFraction(at time.Time, host, mount string) float64 {
	const offset64, prime64 = 14695981039346656037, 1099511628211
	var buf [128]byte
	b := strconv.AppendInt(buf[:0], at.Truncate(time.Hour).Unix(), 10)
	b = append(b, '|')
	b = append(b, host...)
	b = append(b, '|')
	b = append(b, mount...)
	h := uint64(offset64)
	for _, c := range b {
		h = (h ^ uint64(c)) * prime64
	}
	return 0.08 + float64(h%900)/1000
}

// arcPath is the filled part of a ring: from 12 o'clock clockwise, box-local.
func arcPath(cx, cy, r, frac float64) string {
	if frac <= 0 {
		return ""
	}
	frac = min(frac, 0.999)
	a := frac * 2 * math.Pi
	x2 := cx + r*math.Sin(a)
	y2 := cy - r*math.Cos(a)
	large := 0
	if frac > 0.5 {
		large = 1
	}
	return fmt.Sprintf("M%.1f %.1f A%.1f %.1f 0 %d 1 %.1f %.1f", cx, cy-r, r, r, large, x2, y2)
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// routeKey is the route's stable identity within its service, derived exactly
// as traffic.Event.Route is: a route's own key must name the same route to
// seed, or a marker could highlight another route's traffic.
func routeKey(r inventory.Route, idx int) string {
	if n := r.NameStr(); n != "" {
		return n
	}
	if f := r.FQDNStr(); f != "" {
		return f
	}
	if u := r.URLStr(); u != "" {
		return u
	}
	if r.Proto != "" {
		return r.Proto + "/" + strconv.Itoa(r.Port)
	}
	return "route-" + strconv.Itoa(idx)
}

// routeLabel is the route's own name when it has one, else the name inside the
// zone, else what it listens on.
func routeLabel(r inventory.Route) string {
	if n := r.NameStr(); n != "" {
		return n
	}
	if f := r.FQDNStr(); f != "" {
		if i := strings.IndexByte(f, '.'); i > 0 {
			return f[:i]
		}
		return f
	}
	if u := r.URLStr(); u != "" {
		return u
	}
	if r.Proto != "" {
		return r.Proto + "/" + strconv.Itoa(r.Port)
	}
	return "route"
}

// driveUnhealthy is the shared rule for "this drive needs attention": a
// spun-down drive cannot be interrogated, so it is never a failure there; any
// defect counter, full wear, or a false SMART verdict makes the drive count
// once. The same predicate feeds the station badge and the historical
// driveWarnings series, so the live map and the timeline agree.
func driveUnhealthy(d state.SmartDrive) bool {
	if d.Standby {
		return false
	}
	return !d.Healthy ||
		d.PendingSectors > 0 || d.UncorrectableErrors > 0 || d.MediaErrors > 0 ||
		d.ReallocatedSectors > 0 || d.WearPercentUsed >= 100
}

// diskProblems counts what the station should flag: unhealthy drives and pools
// that are degraded or logging IO errors. A pool is counted once even when
// several submounts report the same array.
func diskProblems(st *state.HostStatus) int {
	n := 0
	for _, d := range st.Smart {
		if driveUnhealthy(d) {
			n++
		}
	}
	seen := map[string]bool{}
	for _, fs := range st.Filesystems {
		b := fs.Bcachefs
		if b == nil || !(b.Degraded || bcachefsIOErrors(b) > 0) {
			continue
		}
		// Pool identity, so submounts of one array are one problem. A status
		// without a UUID falls back to the mount, which is unique per pool.
		key := b.UUID
		if key == "" {
			key = "mount:" + fs.Mount
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		n++
	}
	return n
}

func bcachefsIOErrors(b *state.BcachefsInfo) uint64 {
	var n uint64
	for _, d := range b.Devices {
		n += d.IOErrorsRead + d.IOErrorsWrite + d.IOErrorsCsum
	}
	return n
}

func stateText(hv state.HostView, now time.Time) string {
	seen := seenSuffix(hv, now)
	switch hv.StateBadge {
	case "online":
		if hv.Status != nil && hv.Status.System != nil && hv.Status.System.UptimeSec > 0 {
			return "online · up " + state.FormatAge(time.Duration(hv.Status.System.UptimeSec)*time.Second)
		}
		return "online"
	case "sleeping":
		return "asleep / offline" + seen
	case "down":
		if hv.Error != "" && seen == "" {
			return "down · " + hv.Error
		}
		return "down" + seen
	default:
		return "not polled (no fleet-agent)"
	}
}

// systemLine is the one-line CPU/memory/uptime summary the sidebar shows; the
// station itself stays non-technical.
func systemLine(hv state.HostView) string {
	if hv.Status == nil || hv.Status.System == nil {
		return ""
	}
	sys := hv.Status.System
	parts := []string{fmt.Sprintf("cpu %.0f%%", sys.CPUPercent)}
	if sys.MemTotalBytes > 0 {
		parts = append(parts, fmt.Sprintf("mem %.0f%%", float64(sys.MemUsedBytes)*100/float64(sys.MemTotalBytes)))
	}
	if sys.UptimeSec > 0 {
		parts = append(parts, "up "+state.FormatAge(time.Duration(sys.UptimeSec)*time.Second))
	}
	return strings.Join(parts, " · ")
}

func seenSuffix(hv state.HostView, now time.Time) string {
	if hv.LastSeenAge != "" {
		return " · last seen " + hv.LastSeenAge + " ago"
	}
	if !hv.LastSeen.IsZero() && !now.IsZero() {
		return " · last seen " + state.FormatAge(now.Sub(hv.LastSeen)) + " ago"
	}
	return ""
}

func truncate(s string, n int) string {
	if n < 1 {
		return ""
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

type side int

const (
	left side = iota
	right
	above
	below
)

// routeStations uses the same rounded gutter routing as public branches.
func routeStations(edges []Edge, nodes map[string]*Node, d *Diagram) {
	for i := range edges {
		a, b := nodes[edges[i].From], nodes[edges[i].To]
		mx, my := float64(a.CenterX()+b.CenterX())/2, float64(a.CenterY()+b.CenterY())/2
		edges[i].D = stationPath(d, a, b)
		edges[i].LX, edges[i].LY = int(mx), int(my)
		edges[i].LW = int(float64(len([]rune(edges[i].Label)))*smallCharW) + 12
		edges[i].LRX, edges[i].LRY = edges[i].LX-edges[i].LW/2, edges[i].LY-9
	}
}

// anchor is the point a link leaves this node from, in absolute coordinates.
func (n *Node) anchor(s side) [2]float64 {
	cx, cy := float64(n.CenterX()), float64(n.CenterY())
	if n.Segment {
		switch s {
		case left:
			return [2]float64{float64(n.X + n.SegX1), cy}
		case right:
			return [2]float64{float64(n.X + n.SegX2), cy}
		case above:
			return [2]float64{cx, float64(n.Y + n.SegY1)}
		default:
			return [2]float64{cx, float64(n.Y + n.SegY2)}
		}
	}
	r := float64(n.R)
	switch s {
	case left:
		return [2]float64{cx - r, cy}
	case right:
		return [2]float64{cx + r, cy}
	case above:
		return [2]float64{cx, cy - r}
	default:
		return [2]float64{cx, cy + r}
	}
}

