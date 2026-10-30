package topology

import (
	"encoding/json"
	"fmt"
	"math"
	"slices"
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
	// Note is the caption a derived region prints when it has nothing to
	// draw, so an empty region states why instead of reading as a rendering
	// fault. Lines are wrapped to the region width.
	Note []string
	// NoteX/NoteY are the absolute baseline of the first caption line and
	// NoteDY the offset to each line after it: the template cannot do
	// arithmetic, so the layout hands it numbers.
	NoteX, NoteY, NoteDY int
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
	margin         = 18  // diagram edge
	colHead        = 36  // column caption band
	colGap         = 28  // between columns
	zonePad        = 22  // inside a region
	zoneHead       = 40  // region label band
	zoneLabelX     = 18  // region label inset (the template's dx)
	zoneLabelCharW = 9.6 // 14px region label, 0.1em letter spacing
	zoneGapY       = 24  // between regions of one column
	minZoneH       = 168 // an empty region still reads as a region
	stationW       = 180
	stationR       = 18
	stationGX      = 26
	stationGY      = 24
	labelGap       = 24 // 21px name: baseline of the 16px caption under it
	gaugePitch     = 22 // cpu caption to mem caption: a 16px box is ~18 tall
	tagsClear      = 14 // mem caption to the count band
	countInset     = 10 // count text left edge inside the station
	countLine      = 15 // one 12px count row
	segH           = 44 // a fabric bar
	chipH          = 22 // one route marker
	chipGap        = 8
	chipMinW       = 150 // chips per row at the default width
	braceW         = 16  // how far the brace's point bulges from its spine
	braceGutter    = braceW + 14
	ringR0         = 24
	ringStep       = 3
	ringStroke     = 3
	labelCharW     = 11.6
	smallCharW     = 6.6
	noteCharW      = 7.6 // 15px italic caption, wrapped to the region width
	noteLineGap    = 20  // baseline to baseline of one caption line
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
	plans := make([]colPlan, 0, len(spec.Columns))
	target := spec.Height
	x := 0
	for i, c := range spec.Columns {
		cp := colPlan{col: c, x: x, w: widths[i]}
		for _, z := range c.Zones {
			zp := planZone(z, byZone[z.ID], rs.capacity(z), cp.w)
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

	// Who sits where, for the lane router: a station's column picks the
	// channel it is reached from, its region the slack above its row.
	ix := laneIndex{colOf: map[*Node]int{}, zoneOf: map[*Node]int{}}
	for ci, cp := range plans {
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
			ix.zoneCol = append(ix.zoneCol, ci)
			ix.zoneNodes = append(ix.zoneNodes, zp.nodes)
			for _, n := range zp.nodes {
				ix.colOf[n], ix.zoneOf[n] = ci, len(d.Zones)-1
			}
			if zp.zone.layout() != LayoutRoutes {
				placeZone(zp)
			}
			y += zp.h + zoneGapY
		}
	}

	// Lanes are planned once every station is placed, then the gutters and
	// the rail band are widened to hold them before anything else reads a
	// coordinate.
	ln := planLanes(&d, edges, rs, nodes, ix)
	ln.widen(&d, plans)

	// Station draw order is spec order, so later stations sit on top.
	for _, id := range order {
		d.Nodes = append(d.Nodes, *nodes[id])
	}

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
	// A derived region that drew nothing would read as a rendering fault, so
	// it states why. Zones are addressed by index: zoneOf hands back a copy.
	if len(d.OverlayWeb) == 0 {
		for i := range d.Zones {
			if d.Zones[i].Zone.Group != GroupOverlay {
				continue
			}
			z := &d.Zones[i]
			z.Note = wrapNote(overlayNote(m), z.W-2*zonePad)
			z.NoteX, z.NoteY, z.NoteDY = z.X+zonePad, z.Y+zoneHead+22, noteLineGap
			break
		}
	}
	// The public cloud groups into the edge hub; the overlay cloud groups into
	// one bundled trunk that branches once per owning host.
	if z, ok := rs.zoneOf(&d, GroupOverlay); ok {
		d.OverlayBrace = rs.brace(&d, z, GroupOverlay, nodes)
	}
	if z, ok := rs.zoneOf(&d, GroupPublic); ok {
		d.RouteBrace = rs.brace(&d, z, GroupPublic, nodes)
	}
	routeStations(edges, nodes, ln)
	d.RouteLinks = ln.branches(&d)

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

// colPlan is one column's regions and the width Build measured them at.
type colPlan struct {
	col   Column
	x, w  int
	zones []*zonePlan
	nat   int
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
	// capPublic and capOverlay are how many names each cloud could hold with
	// every declared service placed: what its region is sized for.
	capPublic, capOverlay int
}

// capacity is how many chips a region is sized for.
func (r *routeSet) capacity(z Zone) int {
	switch z.Group {
	case GroupPublic:
		return r.capPublic
	case GroupOverlay:
		return r.capOverlay
	}
	return 0
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

	// A region is sized for every name it could ever hold, placed or not:
	// placement changes at runtime and replay frames are drawn from history,
	// so a cloud gaining a chip must not move every region under it.
	pub, ovl := map[string]bool{}, map[string]bool{}
	for key := range claimed {
		pub[key] = true
	}
	for _, list := range svcByHost {
		for _, s := range list {
			for _, rt := range s.Routes {
				key := strings.ToLower(strings.TrimSuffix(rt.FQDNStr(), "."))
				switch {
				case key == "":
				case rt.Exposure == "public":
					pub[key] = true
				case rt.Exposure == "tailnet":
					ovl[key] = true
				}
			}
		}
	}
	rs.capPublic, rs.capOverlay = max(len(pub), len(rs.public)), max(len(ovl), len(rs.overlay))
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

// overlayNote explains an overlay region that drew no name. The two causes are
// told apart on evidence, never by guessing: nothing placed is a registry
// answer, everything placed is a route answer.
func overlayNote(m state.Merged) string {
	if len(m.Services) > 0 {
		unplaced := 0
		for _, s := range m.Services {
			if s.BoundHost == "" {
				unplaced++
			}
		}
		if unplaced == len(m.Services) {
			return fmt.Sprintf("No service is placed: 0 of %d have a host in the placement registry, so no overlay name has an owner.", len(m.Services))
		}
	}
	return "No placed service declares a tailnet name."
}

// wrapNote breaks a sentence into lines that fit width, at word boundaries
// only: a caption is read, so a word cut in half reads as corruption.
func wrapNote(s string, width int) []string {
	if width <= 0 {
		return []string{s}
	}
	perLine := max(1, int(float64(width)/noteCharW))
	var lines []string
	line := ""
	for _, w := range strings.Fields(s) {
		switch {
		case line == "":
			line = w
		case len([]rune(line))+1+len([]rune(w)) <= perLine:
			line += " " + w
		default:
			lines = append(lines, line)
			line = w
		}
	}
	if line != "" {
		lines = append(lines, line)
	}
	return lines
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
	// The lead's path needs its lane in the gutter, so the lane router
	// writes LeadD once the gutters are sized.
	b.Hub, b.HubX, b.HubY = r.hub, n.CenterX(), n.CenterY()
	return b
}

// trunkLen is how far the overlay's shared collector runs before branching.
const trunkLen = 22

// target is one host a cloud branches to.
type target struct {
	host, id string
	n        *Node
}

// targets is each owning host once, in marker order: a cloud's trunk splits
// once per destination instead of drawing a lead from every chip. skip is the
// hub itself, which a branch never leaves for.
func targets(markers []RouteMarker, nodes map[string]*Node, skip *Node) []target {
	seen := map[string]bool{}
	var out []target
	for _, m := range markers {
		if m.NodeID == "" || seen[m.NodeID] {
			continue
		}
		n := nodes[m.NodeID]
		if n == nil || n == skip {
			continue
		}
		seen[m.NodeID] = true
		out = append(out, target{host: m.Host, id: m.NodeID, n: n})
	}
	return out
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
// replacing each turn with a tangent quadratic Bézier. A corner's radius is
// clamped to half of each leg, so two corners sharing a short leg meet at its
// middle instead of overlapping, and a leg that rounds away to nothing is not
// written at all. A full reversal keeps its vertex: rounding it would draw a
// spike back over the run.
func roundedPath(points [][2]float64) string {
	var clean [12][2]float64
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
	pen := clean[0]
	lineTo := func(p [2]float64) {
		if math.Abs(p[0]-pen[0]) >= 0.05 || math.Abs(p[1]-pen[1]) >= 0.05 {
			fmt.Fprintf(&d, " L%.1f %.1f", p[0], p[1])
		}
		pen = p
	}
	for i := 1; i < n-1; i++ {
		a, b, c := clean[i-1], clean[i], clean[i+1]
		if (b[0]-a[0])*(c[1]-b[1]) == (b[1]-a[1])*(c[0]-b[0]) {
			lineTo(b)
			continue
		}
		before, after := math.Hypot(b[0]-a[0], b[1]-a[1]), math.Hypot(c[0]-b[0], c[1]-b[1])
		r := min(14.0, before/2, after/2)
		lineTo([2]float64{b[0] + (a[0]-b[0])*r/before, b[1] + (a[1]-b[1])*r/before})
		leave := [2]float64{b[0] + (c[0]-b[0])*r/after, b[1] + (c[1]-b[1])*r/after}
		fmt.Fprintf(&d, " Q%.1f %.1f %.1f %.1f", b[0], b[1], leave[0], leave[1])
		pen = leave
	}
	if n > 1 {
		fmt.Fprintf(&d, " L%.1f %.1f", clean[n-1][0], clean[n-1][1])
	}
	return d.String()
}

// --- lanes -----------------------------------------------------------------
//
// Every vertical run between two columns owns an x in that gutter (a
// channel), every crossing above the columns owns a rail, and every
// connection meeting a station owns its own point on the rim. No two
// connections share a stroke, so each one can be followed end to end. Lanes
// are greedy interval colouring: runs sorted by where they start each take
// the lowest lane free over their span.

const (
	lanePitch  = 6  // between two vertical lanes of one channel
	laneClear  = 4  // free run between two intervals that reuse one lane
	railPitch  = 6  // between two rails of the band above the columns
	railTop    = 6  // the topmost rail
	rimPitch   = 4  // between two attach points on one side of a head, at most
	slackPitch = 4  // between two approach legs above a station row, at most
	busPitch   = 8  // between two overlay branches leaving the bus
	labelClear = 30 // a leg above a region's first row stays under its label
	cloudHold  = 3  // lanes a cloud keeps in each gutter it could enter
	cloudRails = 3  // rails a cloud keeps if it could cross a column
)

// approach is how a connection meets a station.
type approach int

const (
	fromLeft  approach = iota // a horizontal leg into the left rim
	fromTop                   // a leg above the row, then a drop onto the head
	fromRight                 // the public fork leaving the edge hub
)

// end is one connection's attachment to a station.
type end struct {
	n      *Node
	side   approach
	pinned bool       // keeps the rim's centre point (the public lead)
	lane   float64    // x the leg comes from; orders legs so they don't cross
	up     bool       // the connection carries on above the leg
	at     [2]float64 // the attach point
	legY   float64    // y of the horizontal leg
}

// leg appends the approach from lane x to the attach point.
func (e *end) leg(p [][2]float64, x float64) [][2]float64 {
	p = append(p, [2]float64{x, e.legY})
	if e.side == fromTop {
		p = append(p, [2]float64{e.at[0], e.legY})
	}
	return append(p, e.at)
}

// unleg is leg reversed: from the attach point out to lane x.
func (e *end) unleg(p [][2]float64, x float64) [][2]float64 {
	p = append(p, e.at)
	if e.side == fromTop {
		p = append(p, [2]float64{e.at[0], e.legY})
	}
	return append(p, [2]float64{x, e.legY})
}

// vrun is one vertical run in a channel. Channel c is the gutter left of
// column c; the last channel is right of every column.
type vrun struct {
	ch     int
	lo, hi float64
	fixed  bool // a lane of its own: a cloud trunk leaving its region
	lane   int
	x      float64
}

// rail is one crossing above the columns, spanning channels lo..hi; a
// column's interior is half way between its two channels.
type rail struct {
	lo, hi float64
	lane   int
	y      float64
}

// route is one connection: station ends, the lanes at each, the rail between.
type route struct {
	a, b     *end
	ra, rb   *vrun
	rail     *rail
	host, to string
	depart   float64 // overlay branches: y the branch leaves the bus at
}

// laneIndex is where Build put every station.
type laneIndex struct {
	colOf     map[*Node]int
	zoneOf    map[*Node]int // index into Diagram.Zones
	zoneCol   []int         // per Diagram.Zones entry
	zoneNodes [][]*Node     // per Diagram.Zones entry
}

type lanes struct {
	laneIndex
	d        *Diagram
	runs     []*vrun
	rails    []*rail
	ends     []*end
	nLanes   []int     // per channel
	chX      []float64 // channel origin
	chW      []int     // channel width
	nRails   int
	capLanes []int // per channel, what the frame holds (see hold)
	capRails int
	edges    []route // parallel to Diagram.Edges
	overlay  []route
	public   []route
	lead     *route
}

// planLanes registers every connection that crosses a gutter, edges and both
// clouds' branches, and colours their runs into lanes. Only y spans and
// channel indices are read, so the result survives widen's shift.
func planLanes(d *Diagram, edges []Edge, rs *routeSet, nodes map[string]*Node, ix laneIndex) *lanes {
	l := &lanes{laneIndex: ix, d: d}
	channels := len(d.Columns) + 1
	for _, e := range edges {
		l.edges = append(l.edges, l.connect(nodes[e.From], nodes[e.To]))
	}
	// The frame is sized from the edges alone, before any cloud is planned.
	l.colour(channels)
	hub := nodes[rs.hub]
	if _, ok := l.colOf[hub]; !ok {
		hub = nil
	}
	pz, oz := zoneIndex(d, GroupPublic), zoneIndex(d, GroupOverlay)
	l.capLanes, l.capRails = l.hold(hub, pz, oz)
	planLead := func() {
		if pz < 0 || len(rs.public) == 0 || hub == nil {
			return
		}
		e := l.attach(hub, fromLeft)
		e.pinned, e.up = true, true
		l.lead = &route{b: e, ra: l.run(l.zoneCol[pz]+1, 0, 0, true)}
	}
	planOverlay := func() {
		if oz < 0 || len(rs.overlay) == 0 {
			return
		}
		ch := l.zoneCol[oz] + 1
		for _, t := range targets(rs.overlay, nodes, nil) {
			if _, ok := l.colOf[t.n]; !ok {
				continue
			}
			tc := l.toward(t.n, ch)
			r := route{b: l.reach(t.n, tc), ra: l.run(ch, 0, 0, true), host: t.host, to: t.id}
			r.rb = r.ra
			if tc != ch {
				_, hi := l.band(r.b)
				r.rb, r.rail, r.b.up = l.run(tc, math.Inf(-1), hi, false), l.span(float64(ch), float64(tc)), true
			}
			l.overlay = append(l.overlay, r)
		}
	}
	// A trunk leaving its region on the left of a gutter takes the gutter's
	// first lanes, higher regions further left, so the departures never
	// cross each other or an edge's lane.
	if pz >= 0 && oz >= 0 && d.Zones[oz].Y < d.Zones[pz].Y {
		planOverlay()
		planLead()
	} else {
		planLead()
		planOverlay()
	}
	// The fork leaves the hub's right rim into the gutter beside its column,
	// so it never cuts back through the hub.
	if hub != nil {
		ch := l.colOf[hub] + 1
		for _, t := range targets(rs.public, nodes, hub) {
			if _, ok := l.colOf[t.n]; !ok {
				continue
			}
			tc := l.toward(t.n, ch)
			r := route{a: l.reach(hub, ch), b: l.reach(t.n, tc), host: t.host, to: t.id}
			l.join(&r, ch, tc)
			l.public = append(l.public, r)
		}
	}
	l.colour(channels)
	return l
}

// hold is what the frame keeps per channel and in the rail band: the lanes
// the edges were just coloured into, plus a share for each cloud worked out
// from the spec alone. Placement changes at runtime and replay frames are
// drawn from history, so which branches exist in this snapshot must never
// rescale or shift the map. Any station with a host could own a route, so a
// cloud keeps one lane per such station it could reach through a gutter, at
// most cloudHold, and cloudRails rails if any of them sits across a column.
// A snapshot that needs more squeezes the pitch instead of growing (settle).
func (l *lanes) hold(hub *Node, pz, oz int) ([]int, int) {
	held, rails := slices.Clone(l.nLanes), l.nRails
	cloud := func(trunk int, skip *Node) {
		reach := make([]int, len(held))
		crosses := false
		for n := range l.colOf {
			if n.Host == "" || n == skip {
				continue
			}
			reach[trunk]++
			if tc := l.toward(n, trunk); tc != trunk {
				reach[tc]++
				crosses = true
			}
		}
		for c, k := range reach {
			held[c] += min(k, cloudHold)
		}
		if crosses {
			rails += cloudRails
		}
	}
	if oz >= 0 {
		cloud(l.zoneCol[oz]+1, nil)
	}
	if hub != nil {
		if pz >= 0 {
			held[l.zoneCol[pz]+1]++ // the public lead
		}
		cloud(l.colOf[hub]+1, hub)
	}
	return held, rails
}

// zoneIndex is the first drawn region holding a cloud, or -1.
func zoneIndex(d *Diagram, group string) int {
	for i, z := range d.Zones {
		if z.Zone.Group == group {
			return i
		}
	}
	return -1
}

// connect plans one edge between the gutters its stations face each other
// through; stations of one column share the gutter on its left.
func (l *lanes) connect(a, b *Node) route {
	ca, cb := l.toward(a, l.colOf[b]), l.toward(b, l.colOf[a])
	r := route{a: l.reach(a, ca), b: l.reach(b, cb)}
	l.join(&r, ca, cb)
	return r
}

// toward is the gutter beside n's column on the side of column col: the
// right one when col lies further right, otherwise the left one. A channel
// index passed as col reads as the column right of that gutter.
func (l *lanes) toward(n *Node, col int) int {
	c := l.colOf[n]
	if c < col {
		return c + 1
	}
	return c
}

// join plans a connection whose ends reach gutters ca and cb: one lane when
// they share a gutter, otherwise a lane at each joined over a rail.
func (l *lanes) join(r *route, ca, cb int) {
	alo, ahi := l.band(r.a)
	blo, bhi := l.band(r.b)
	if ca == cb {
		r.ra = l.run(ca, min(alo, blo), max(ahi, bhi), false)
		r.rb = r.ra
		r.a.up, r.b.up = blo+bhi < alo+ahi, alo+ahi < blo+bhi
		return
	}
	r.ra, r.rb = l.run(ca, math.Inf(-1), ahi, false), l.run(cb, math.Inf(-1), bhi, false)
	r.rail = l.span(float64(ca), float64(cb))
	r.a.up, r.b.up = true, true
}

func (l *lanes) attach(n *Node, side approach) *end {
	e := &end{n: n, side: side}
	l.ends = append(l.ends, e)
	return e
}

// reach attaches n on the side facing gutter ch: the left rim for the gutter
// left of its column, the right rim for the one right of it. When another
// station of the row sits on that side, the leg runs above the row and drops
// onto the head instead of cutting through the neighbour.
func (l *lanes) reach(n *Node, ch int) *end {
	right := ch > l.colOf[n]
	side := fromLeft
	if right {
		side = fromRight
	}
	if zi, ok := l.zoneOf[n]; ok && !n.Segment {
		for _, m := range l.zoneNodes[zi] {
			if m != n && sameRow(m, n) && (m.X > n.X) == right {
				side = fromTop
				break
			}
		}
	}
	return l.attach(n, side)
}

func sameRow(a, b *Node) bool { return a.Y < b.Y+b.H && b.Y < a.Y+a.H }

// band is the y range e's leg can end up at.
func (l *lanes) band(e *end) (lo, hi float64) {
	if e.side == fromTop {
		return l.slack(e.n)
	}
	y, s := e.n.anchor(left)[1], spread(e.n)
	return y - s, y + s
}

// spread is how far from a side's centre an attach point may sit.
func spread(n *Node) float64 {
	if n.Segment {
		return float64(n.SegY2-n.SegY1) * 0.4
	}
	return 0.9 * float64(n.R)
}

// slack is the free band above a station's row: under the previous row (or
// the region's label) and over the row's heads.
func (l *lanes) slack(n *Node) (floor, top float64) {
	zi, ok := l.zoneOf[n]
	if !ok {
		return float64(n.Y - 12), float64(n.Y)
	}
	rowTop := n.Y
	for _, m := range l.zoneNodes[zi] {
		if sameRow(m, n) {
			rowTop = min(rowTop, m.Y)
		}
	}
	fl := l.d.Zones[zi].Y + labelClear
	for _, m := range l.zoneNodes[zi] {
		if m.Y+m.H <= rowTop {
			fl = max(fl, m.Y+m.H+3)
		}
	}
	top = float64(rowTop + 3)
	return min(float64(fl), top), top
}

func (l *lanes) run(ch int, lo, hi float64, fixed bool) *vrun {
	r := &vrun{ch: ch, lo: lo, hi: hi, fixed: fixed}
	l.runs = append(l.runs, r)
	return r
}

func (l *lanes) span(a, b float64) *rail {
	r := &rail{lo: min(a, b), hi: max(a, b)}
	l.rails = append(l.rails, r)
	return r
}

// colour assigns lanes. Fixed runs take a channel's first lanes in planning
// order; the rest are sorted by start, deepest first on a tie, so runs bound
// for the rail stack outward from the deepest and their legs don't cross.
func (l *lanes) colour(channels int) {
	l.nLanes = make([]int, channels)
	fixed := make([]int, channels)
	var free []*vrun
	for _, r := range l.runs {
		if r.fixed {
			r.lane = fixed[r.ch]
			fixed[r.ch]++
		} else {
			free = append(free, r)
		}
	}
	sort.SliceStable(free, func(i, j int) bool {
		if free[i].lo != free[j].lo {
			return free[i].lo < free[j].lo
		}
		return free[i].hi > free[j].hi
	})
	busy := make([][]float64, channels) // per channel, where each lane frees up
	for _, r := range free {
		k := slices.IndexFunc(busy[r.ch], func(until float64) bool { return until+laneClear < r.lo })
		if k < 0 {
			k = len(busy[r.ch])
			busy[r.ch] = append(busy[r.ch], r.hi)
		} else {
			busy[r.ch][k] = r.hi
		}
		r.lane = fixed[r.ch] + k
	}
	for c := range l.nLanes {
		l.nLanes[c] = fixed[c] + len(busy[c])
	}
	sort.SliceStable(l.rails, func(i, j int) bool {
		if l.rails[i].lo != l.rails[j].lo {
			return l.rails[i].lo < l.rails[j].lo
		}
		return l.rails[i].hi > l.rails[j].hi
	})
	var railBusy []float64
	for _, r := range l.rails {
		k := slices.IndexFunc(railBusy, func(until float64) bool { return until < r.lo })
		if k < 0 {
			k = len(railBusy)
			railBusy = append(railBusy, r.hi)
		} else {
			railBusy[k] = r.hi
		}
		r.lane = k
	}
	l.nRails = len(railBusy)
}

// widen sizes every gutter and the rail band from what hold kept, then lays
// the columns out again around them. Growth comes out of column slack first
// (room beyond a column's widest station row and region label), so the frame
// keeps the spec's width while the stations still fit; only what the slack
// cannot cover widens the diagram. Lane planning read y spans and channel
// indices only, and re-placing a region keeps its row order, so the plan
// survives.
func (l *lanes) widen(d *Diagram, plans []colPlan) {
	nc := len(plans)
	l.chW = make([]int, nc+1)
	grow := 0
	for c := range l.chW {
		if k := l.capLanes[c]; k > 0 {
			l.chW[c] = (k + 1) * lanePitch
		}
		if c > 0 && c < nc {
			l.chW[c] = max(l.chW[c], colGap)
			grow += l.chW[c] - colGap
		} else {
			grow += l.chW[c]
		}
	}
	w, slack := make([]int, nc), make([]int, nc)
	for i := range plans {
		w[i] = plans[i].w
		slack[i] = w[i] - plans[i].need()
	}
	for grow > 0 {
		i := 0
		for j := range slack {
			if slack[j] > slack[i] {
				i = j
			}
		}
		if nc == 0 || slack[i] <= 0 {
			break
		}
		take := min(grow, slack[i])
		w[i], slack[i], grow = w[i]-take, slack[i]-take, grow-take
	}
	shiftY := max(0, l.capRails-1) * railPitch
	x, k := l.chW[0], 0
	for i := range plans {
		col := &d.Columns[i]
		col.X, col.W, col.Y = x, w[i], col.Y+shiftY
		for _, zp := range plans[i].zones {
			zp.x, zp.w, zp.y = x, w[i], zp.y+shiftY
			z := &d.Zones[k]
			z.X, z.W, z.Y = zp.x, zp.w, zp.y
			if zp.zone.layout() != LayoutRoutes {
				placeZone(zp)
			}
			k++
		}
		x += w[i] + l.chW[i+1]
	}
	d.Width = max(d.Width, x)
	d.Height += shiftY
	l.chX = make([]float64, nc+1)
	for c := 1; c <= nc; c++ {
		l.chX[c] = float64(d.Columns[c-1].X + d.Columns[c-1].W)
	}
}

// need is the narrowest a column can be with its widest station row and every
// region label still fitting. A column holding a route cloud keeps its width:
// its chips are laid out for it.
func (cp *colPlan) need() int {
	n := 0
	for _, zp := range cp.zones {
		if zp.zone.layout() == LayoutRoutes {
			return cp.w
		}
		n = max(n, int(math.Ceil(float64(len([]rune(zp.zone.Label)))*zoneLabelCharW))+zoneLabelX+zonePad)
		for _, row := range zp.rows {
			rw := -stationGX
			for _, m := range row {
				if m.Segment {
					rw += stationW + stationGX // a fabric spans whatever it is given
				} else {
					rw += m.W + stationGX
				}
			}
			n = max(n, rw+2*zonePad)
		}
	}
	return min(max(n, MinWidth), cp.w)
}

// settle places every lane and rail, then every attach point and leg. A
// channel or band holding more than hold kept squeezes its pitch to fit.
func (l *lanes) settle() {
	for _, r := range l.runs {
		n, w := float64(l.nLanes[r.ch]), float64(l.chW[r.ch])
		pitch := min(lanePitch, w/(n+1))
		r.x = l.chX[r.ch] + (w-(n-1)*pitch)/2 + float64(r.lane)*pitch
	}
	pitch := float64(railPitch)
	if l.nRails > max(l.capRails, 2) {
		pitch = railPitch * float64(max(l.capRails, 2)-1) / float64(l.nRails-1)
	}
	for _, r := range l.rails {
		r.y = railTop + float64(r.lane)*pitch
	}
	l.prepare()
	type rimKey struct {
		n    *Node
		side approach
	}
	type rowKey struct{ zone, top int }
	rims, rows := map[rimKey][]*end{}, map[rowKey][]*end{}
	var rimOrder []rimKey
	var rowOrder []rowKey
	for _, e := range l.ends {
		if e.side == fromTop {
			_, top := l.slack(e.n)
			k := rowKey{l.zoneOf[e.n], int(top)}
			if rows[k] == nil {
				rowOrder = append(rowOrder, k)
			}
			rows[k] = append(rows[k], e)
			continue
		}
		k := rimKey{e.n, e.side}
		if rims[k] == nil {
			rimOrder = append(rimOrder, k)
		}
		rims[k] = append(rims[k], e)
	}
	for _, k := range rimOrder {
		rim(rims[k])
	}
	for _, k := range rowOrder {
		l.legs(rows[k])
	}
	l.unclash()
}

// unclash keeps two legs off one line. Ends reaching a gutter from opposite
// sides, or legs above two rows that happen to sit at one height, overlap
// wherever their lanes interleave: the later leg steps aside half a rim
// pitch at a time, within the room its approach has.
func (l *lanes) unclash() {
	type piece struct {
		e      *end // nil for an overlay departure, which stays put
		owner  *route
		y      float64
		lo, hi float64
	}
	var ps []piece
	add := func(r *route, e *end, lane float64) {
		if e != nil {
			ps = append(ps, piece{e: e, owner: r, y: e.legY, lo: min(e.at[0], lane), hi: max(e.at[0], lane)})
		}
	}
	for _, rs := range [...][]route{l.edges, l.public, l.overlay} {
		for i := range rs {
			r := &rs[i]
			add(r, r.a, r.ra.x)
			add(r, r.b, r.rb.x)
		}
	}
	if l.lead != nil {
		add(l.lead, l.lead.b, l.lead.b.lane)
	}
	if b := l.d.OverlayBrace; b != nil {
		bus := float64(b.TipX + trunkLen)
		for i := range l.overlay {
			r := &l.overlay[i]
			ps = append(ps, piece{owner: r, y: r.depart, lo: bus, hi: r.ra.x})
		}
	}
	clash := func(i int, y float64) bool {
		p := ps[i]
		for j, q := range ps {
			if j == i || q.owner == p.owner {
				continue
			}
			if math.Abs(q.y-y) < 1 && min(p.hi, q.hi)-max(p.lo, q.lo) > 0.5 {
				return true
			}
			// Two attach points on one rim stay apart.
			if p.e.side != fromTop && q.e != nil && q.e.n == p.e.n && q.e.side == p.e.side && math.Abs(q.e.at[1]-y) < 1 {
				return true
			}
		}
		return false
	}
	for i := range ps {
		p := &ps[i]
		if p.e == nil || !clash(i, p.y) {
			continue
		}
		e := p.e
		lo, hi := l.band(e)
		if e.side != fromTop {
			c, s := e.n.anchor(left)[1], spread(e.n)
			lo, hi = c-s, c+s
		}
	step:
		for k := 1; k <= 8; k++ {
			for _, dy := range [2]float64{rimPitch / 2, -rimPitch / 2} {
				y := p.y + float64(k)*dy
				if y < lo || y > hi || clash(i, y) {
					continue
				}
				p.y, e.legY = y, y
				if e.side != fromTop {
					e.at[1] = y
					if !e.n.Segment {
						r, dy := float64(e.n.R), y-float64(e.n.CenterY())
						w := math.Sqrt(r*r - dy*dy)
						if e.side == fromRight {
							e.at[0] = float64(e.n.CenterX()) + w
						} else {
							e.at[0] = float64(e.n.CenterX()) - w
						}
					}
				}
				break step
			}
		}
	}
}

// rim spreads one side's attach points top to bottom. Legs whose connection
// carries on upward sit higher, the lane nearest the station highest;
// downward ones lower, the nearest lane lowest. So no leg crosses another
// connection's run on its way in. A pinned end keeps the centre.
func rim(es []*end) {
	n, side := es[0].n, es[0].side
	var pin *end
	order := make([]*end, 0, len(es))
	for _, e := range es {
		if e.pinned && pin == nil {
			pin = e
		} else {
			order = append(order, e)
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := order[i], order[j]
		if a.up != b.up {
			return a.up
		}
		// On the right the nearest lane is the leftmost: mirror it.
		la, lb := a.lane, b.lane
		if side == fromRight {
			la, lb = -la, -lb
		}
		if a.up {
			return la > lb
		}
		return la < lb
	})
	centre := float64(len(order)-1) / 2
	if pin != nil {
		mid := len(order) / 2
		order = slices.Insert(order, mid, pin)
		centre = float64(mid)
	}
	pitch := float64(rimPitch)
	if reach := max(centre, float64(len(order)-1)-centre); reach > 0 {
		pitch = min(pitch, spread(n)/reach)
	}
	s := left
	if side == fromRight {
		s = right
	}
	base := n.anchor(s)
	for i, e := range order {
		dy := (float64(i) - centre) * pitch
		e.at = [2]float64{base[0], base[1] + dy}
		if !n.Segment {
			r := float64(n.R)
			w := math.Sqrt(r*r - dy*dy)
			if side == fromRight {
				e.at[0] = float64(n.CenterX()) + w
			} else {
				e.at[0] = float64(n.CenterX()) - w
			}
		}
		e.legY = e.at[1]
	}
}

// legs stacks one row's above-the-row legs bottom to top, upward ones first
// with the farthest lane lowest, and drops each onto its head in the same
// order, so a drop never crosses a leg still heading past it. A lane right
// of its head is mirrored, so either side orders the same way.
func (l *lanes) legs(es []*end) {
	far := func(e *end) float64 {
		if e.lane > float64(e.n.CenterX()) {
			return -e.lane
		}
		return e.lane
	}
	sort.SliceStable(es, func(i, j int) bool {
		a, b := es[i], es[j]
		if a.up != b.up {
			return a.up
		}
		if a.up {
			return far(a) < far(b)
		}
		return far(a) > far(b)
	})
	floor, top := l.slack(es[0].n)
	pitch := float64(slackPitch)
	if len(es) > 1 {
		pitch = max(1, min(pitch, (top-floor)/float64(len(es)-1)))
	}
	perHead := map[*Node][]*end{}
	for i, e := range es {
		e.legY = top - float64(i)*pitch
		perHead[e.n] = append(perHead[e.n], e)
	}
	for n, hs := range perHead {
		r := float64(n.R)
		pitch := float64(rimPitch)
		if len(hs) > 1 {
			pitch = min(pitch, 1.8*r/float64(len(hs)-1))
		}
		for i, e := range hs {
			dx := (float64(i) - float64(len(hs)-1)/2) * pitch
			e.at = [2]float64{float64(n.CenterX()) + dx, float64(n.CenterY()) - math.Sqrt(r*r-dx*dx)}
		}
	}
}

// path is an edge's polyline, from its first station to its second.
func (r *route) path() string {
	var buf [12][2]float64
	p := r.a.unleg(buf[:0], r.ra.x)
	if r.rail != nil {
		p = append(p, [2]float64{r.ra.x, r.rail.y}, [2]float64{r.rb.x, r.rail.y})
	}
	return roundedPath(r.b.leg(p, r.rb.x))
}

// prepare fixes what settle orders legs by: each end's lane x, and for the
// overlay the bus departures.
func (l *lanes) prepare() {
	for _, rs := range [2][]route{l.edges, l.public} {
		for i := range rs {
			rs[i].a.lane, rs[i].b.lane = rs[i].ra.x, rs[i].rb.x
		}
	}
	if b := l.d.OverlayBrace; b != nil {
		n := len(l.overlay)
		for k := range l.overlay {
			r := &l.overlay[k]
			r.depart = float64(b.Mid + (2*k-(n-1))*busPitch/2)
			r.b.lane = r.rb.x
			if r.rail == nil {
				lo, hi := l.band(r.b)
				r.b.up = r.depart < (lo+hi)/2
			}
		}
	}
	if l.lead != nil {
		l.lead.b.lane = l.lead.b.n.anchor(left)[0] - 24
	}
}

// branches draws both clouds: the overlay bus and its branches, the public
// fork and its lead. It runs after the braces exist, and after the edges were
// drawn from the same settled attach points.
func (l *lanes) branches(d *Diagram) []RouteLink {
	var links []RouteLink
	if b := d.OverlayBrace; b != nil && len(l.overlay) > 0 {
		busX := b.TipX + trunkLen
		if n := len(l.overlay); n > 1 {
			// The bus is a short bar the branches leave at their own height.
			b.LeadD = fmt.Sprintf("M%d %d H%d V%.0f V%.0f", b.TipX, b.Mid, busX, l.overlay[0].depart, l.overlay[n-1].depart)
		}
		for _, r := range l.overlay {
			var buf [12][2]float64
			p := append(buf[:0], [2]float64{float64(busX), r.depart}, [2]float64{r.ra.x, r.depart})
			if r.rail != nil {
				p = append(p, [2]float64{r.ra.x, r.rail.y}, [2]float64{r.rb.x, r.rail.y})
			}
			links = append(links, RouteLink{
				Group: GroupOverlay, Host: r.host, ToID: r.to,
				FromX: busX, FromY: int(r.depart),
				ToX: int(math.Round(r.b.at[0])), ToY: int(math.Round(r.b.at[1])),
				D: roundedPath(r.b.leg(p, r.rb.x)),
			})
		}
	}
	// The fork leaves the hub's right rim into the gutter beside its column,
	// like any edge from there.
	for _, r := range l.public {
		links = append(links, RouteLink{
			Group: GroupPublic, Host: r.host, ToID: r.to,
			FromX: int(math.Round(r.a.at[0])), FromY: int(math.Round(r.a.at[1])),
			ToX: int(math.Round(r.b.at[0])), ToY: int(math.Round(r.b.at[1])),
			D: r.path(),
		})
	}
	// The public lead takes its own lane out of the region, crosses above the
	// hub and comes down beside it into the centre of its left rim.
	if b, r := d.RouteBrace, l.lead; b != nil && r != nil {
		e := r.b
		tip, mid := float64(b.TipX), float64(b.Mid)
		over, beside := min(mid, e.legY)-36, e.lane
		points := [6][2]float64{{tip, mid}, {r.ra.x, mid}, {r.ra.x, over}, {beside, over}, {beside, e.legY}, e.at}
		b.LeadD = roundedPath(points[:])
	}
	return links
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
	// A host keeps its service row with nothing placed on it: placement
	// changes at runtime, and a station growing a row would move every station
	// under it between two frames.
	countRows := 0
	if n.SvcCount > 0 || n.Host != "" {
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

// routeStations draws every edge from its settled lanes and attach points.
func routeStations(edges []Edge, nodes map[string]*Node, l *lanes) {
	l.settle()
	for i := range edges {
		a, b := nodes[edges[i].From], nodes[edges[i].To]
		mx, my := float64(a.CenterX()+b.CenterX())/2, float64(a.CenterY()+b.CenterY())/2
		edges[i].D = l.edges[i].path()
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
