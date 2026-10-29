package topology

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

// Diagram is a fully laid-out topology: absolute SVG coordinates, ready for
// a template to draw without arithmetic.
type Diagram struct {
	Width, Height int
	Zones         []ZoneBox
	Edges         []Edge
	Nodes         []Node
	// Meta is the JSON node-detail map (id -> NodeInfo) for the info panel.
	Meta string
}

// ZoneBox is a laid-out zone.
type ZoneBox struct {
	ID, Label, Kind string
	X, Y, W, H      int
}

// Node is a laid-out box. Child coordinates are relative to (X, Y).
type Node struct {
	ID, Label, Kind, Host string
	// Icon is the glyph symbol: Kind when known, else "device".
	Icon string
	// State: online, down, sleeping, no-endpoint (hosts) or static.
	State      string
	X, Y, W, H int
	// DotX is the status dot's x; TsX the tailnet marker's (Tailnet only).
	DotX, TsX int
	Lines     []TextLine
	Tailnet   bool
	// ContainerHost: the inventory declares containers on this host. True
	// even with zero containers, so the box still reads "container host".
	ContainerHost bool
	ChipsLabel    *TextLine
	Chips         []Chip
	Title         string
	// live: the box is confirmed present right now (static gear always, a host
	// only while the merge reports it online and reachable). Edges animate
	// only between live boxes.
	live bool
}

// TextLine is one line of text inside a node.
type TextLine struct {
	Text  string
	Y     int
	Class string
}

// Chip is one container/service inside a container host's box. Name may be
// truncated to fit; Full is the untruncated name.
type Chip struct {
	Name, Full, State, Exposure string
	X, Y, W                     int
}

// Edge is one drawn connection. (LX, LY) is the label center, (LRX, LRY)
// its background's corner.
type Edge struct {
	From, To, Kind, Layer, Label string
	// Live: both ends are present right now, so flow animation runs.
	Live             bool
	D                string
	LX, LY, LRX, LRY int
	LW               int
}

// NodeInfo is the info-panel payload for one node.
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
	Lines     []string      `json:"lines,omitempty"`
	Services  []ServiceInfo `json:"services,omitempty"`
	Links     []LinkInfo    `json:"links,omitempty"`
	// ContainerHost: containers are declared on this host, even if there are
	// none right now. Lets the panel say "Containers (0)" instead of hiding
	// the section. Deliberately no omitempty: false is meaningful.
	ContainerHost bool `json:"containerHost"`
}

// ServiceInfo is one container in the info panel.
type ServiceInfo struct {
	Name        string   `json:"name"`
	State       string   `json:"state"`
	Exposure    string   `json:"exposure,omitempty"`
	Description string   `json:"description,omitempty"`
	URLs        []string `json:"urls,omitempty"`
}

// LinkInfo is one connection in the info panel, from this node's side.
type LinkInfo struct {
	Kind      string `json:"kind"`
	Layer     string `json:"layer"`
	Peer      string `json:"peer"`
	PeerLabel string `json:"peerLabel"`
	Label     string `json:"label,omitempty"`
	Out       bool   `json:"out"`
}

// Geometry (SVG units). Text widths are estimates for system-ui.
const (
	zonePad    = 18
	zoneHead   = 34
	nodeGap    = 18
	zoneGap    = 26
	rowGap     = 46
	minZoneH   = 110
	nodeW      = 220
	wideNodeW  = 470
	wideChips  = 6
	headH      = 40
	lineH      = 16
	bottomPad  = 10
	chipH      = 18
	chipGap    = 4
	minChipW   = 100
	chipsHead  = 18
	labelCharW = 8.2
	smallCharW = 6.3
)

var exposureRank = map[string]int{"local": 1, "tailnet": 2, "lan": 3, "public": 4}

// icons are the glyph symbols the SVG template defines.
var icons = map[string]bool{
	"internet": true, "cloud": true, "dns": true, "user": true, "modem": true,
	"router": true, "switch": true, "ap": true, "server": true, "nas": true,
	"workstation": true, "laptop": true, "phone": true, "appliance": true,
	"kvm": true, "ups": true, "mesh": true, "device": true,
}

var roleKinds = map[string]string{
	"server":      "server",
	"laptop":      "laptop",
	"workstation": "workstation",
	"appliance":   "appliance",
}

// Build lays out spec against the current merged state. The spec must have
// passed Validate against the inventory the state was merged from;
// references that still don't resolve (inventory changed underneath) are
// skipped rather than drawn wrong.
func Build(spec *Spec, m state.Merged, now time.Time) Diagram {
	width := spec.diagramWidth()
	hosts := map[string]state.HostView{}
	for _, h := range m.Hosts {
		hosts[h.Host] = h
	}
	svcByHost := map[string][]state.ServiceView{}
	for _, s := range m.Services {
		svcByHost[s.DeclaredHost] = append(svcByHost[s.DeclaredHost], s)
	}
	for _, list := range svcByHost {
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	}

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

	d := Diagram{Width: width}
	info := map[string]*NodeInfo{}
	byZone := map[string][]*Node{}
	nodes := map[string]*Node{}
	for _, ns := range specs {
		n, ni := buildNode(ns, hosts, svcByHost, now)
		if n == nil {
			continue
		}
		nodes[n.ID] = n
		info[n.ID] = ni
		byZone[ns.Zone] = append(byZone[ns.Zone], n)
	}

	y := 0
	for _, row := range spec.Rows {
		if len(row.Zones) == 0 {
			continue
		}
		x := 0
		rowH := minZoneH
		start := len(d.Zones)
		widths := zoneWidths(row, width)
		for i, z := range row.Zones {
			w := widths[i]
			h := flowZone(byZone[z.ID], x, y, w)
			rowH = max(rowH, h)
			d.Zones = append(d.Zones, ZoneBox{ID: z.ID, Label: z.Label, Kind: z.Kind, X: x, Y: y, W: w})
			x += w + zoneGap
		}
		for i := start; i < len(d.Zones); i++ {
			d.Zones[i].H = rowH
		}
		y += rowH + rowGap
	}
	d.Height = max(y-rowGap, minZoneH)

	// Node draw order: spec order, so later boxes overlap earlier ones.
	for _, ns := range specs {
		if n := nodes[ns.nodeID()]; n != nil {
			d.Nodes = append(d.Nodes, *n)
		}
	}

	var edges []Edge
	add := func(from, to, kind, label string) {
		a, b := nodes[from], nodes[to]
		if a == nil || b == nil || from == to {
			return
		}
		edges = append(edges, Edge{
			From: from, To: to, Kind: kind, Layer: LayerOf(kind), Label: label,
			Live: a.live && b.live,
		})
	}
	for _, l := range spec.Links {
		add(l.From, l.To, l.Kind, l.Label)
	}
	// Host name -> node id (a spec node may give a host a different id).
	hostNode := map[string]string{}
	for _, n := range nodes {
		if n.Host != "" {
			hostNode[n.Host] = n.ID
		}
	}
	hostNames := make([]string, 0, len(hostNode))
	for h := range hostNode {
		hostNames = append(hostNames, h)
	}
	sort.Strings(hostNames)
	for _, h := range hostNames {
		edgeRoutes, routerRoutes := 0, 0
		for _, s := range svcByHost[h] {
			for _, r := range s.Routes {
				for _, v := range r.Via {
					switch v {
					case "edge":
						edgeRoutes++
					case "router":
						routerRoutes++
					}
				}
			}
		}
		if spec.Hubs.Edge != "" && edgeRoutes > 0 {
			add(spec.Hubs.Edge, hostNode[h], "public", plural(edgeRoutes, "public route"))
		}
		if spec.Hubs.Router != "" && routerRoutes > 0 {
			add(spec.Hubs.Router, hostNode[h], "public", plural(routerRoutes, "port forward"))
		}
	}
	for _, h := range hostNames {
		if spec.Hubs.Tailnet != "" && hosts[h].OverlayIP != "" {
			add(spec.Hubs.Tailnet, hostNode[h], "tailnet", "")
		}
	}
	for _, h := range hostNames {
		if spec.Hubs.Dashboard != "" && hosts[h].HasEndpoint {
			add(spec.Hubs.Dashboard, hostNode[h], "agent", "")
		}
	}
	routeEdges(edges, nodes)
	d.Edges = edges

	for _, e := range edges {
		a, b := nodes[e.From], nodes[e.To]
		info[e.From].Links = append(info[e.From].Links, LinkInfo{Kind: e.Kind, Layer: e.Layer, Peer: e.To, PeerLabel: b.Label, Label: e.Label, Out: true})
		info[e.To].Links = append(info[e.To].Links, LinkInfo{Kind: e.Kind, Layer: e.Layer, Peer: e.From, PeerLabel: a.Label, Label: e.Label})
	}
	meta, _ := json.Marshal(info)
	d.Meta = string(meta)
	return d
}

func flex(z Zone) float64 {
	if z.Flex <= 0 {
		return 1
	}
	return z.Flex
}

// diagramWidth is the width Build lays out at: the spec's, or DefaultWidth.
func (s *Spec) diagramWidth() int {
	if s.Width <= 0 {
		return DefaultWidth
	}
	return s.Width
}

// zoneWidths splits a row's width across its zones in proportion to flex,
// rounding each zone and giving the last one whatever is left. Validate uses
// the very same arithmetic so a spec it accepts always lays out in bounds.
func zoneWidths(row Row, width int) []int {
	widths := make([]int, len(row.Zones))
	total := 0.0
	for _, z := range row.Zones {
		total += flex(z)
	}
	avail := float64(width - zoneGap*(len(row.Zones)-1))
	x := 0
	for i, z := range row.Zones {
		w := int(math.Round(avail * flex(z) / total))
		if i == len(row.Zones)-1 {
			w = width - x
		}
		widths[i] = w
		x += w + zoneGap
	}
	return widths
}

// up reports whether the host is confirmed present: the merge already folds
// the poll into StateBadge and Reachable, so the diagram never re-judges how
// old a poll may be (the poll interval is configurable).
func up(hv state.HostView) bool {
	return hv.StateBadge == "online" && hv.Reachable
}

func plural(n int, what string) string {
	if n == 1 {
		return "1 " + what
	}
	return fmt.Sprintf("%d %ss", n, what)
}

// buildNode fills a node's content; width and height are provisional until
// flowZone fits it to its zone.
func buildNode(ns NodeSpec, hosts map[string]state.HostView, svcByHost map[string][]state.ServiceView, now time.Time) (*Node, *NodeInfo) {
	n := &Node{ID: ns.nodeID(), Label: ns.Label, Kind: ns.Kind, Host: ns.Host, State: "static", W: nodeW, live: true}
	ni := &NodeInfo{Href: ns.Href, Lines: append([]string(nil), ns.Lines...)}
	var hv state.HostView
	if ns.Host != "" {
		var ok bool
		if hv, ok = hosts[ns.Host]; !ok {
			return nil, nil
		}
		n.State = hv.StateBadge
		if n.Kind == "" {
			n.Kind = roleKinds[hv.Role]
		}
		n.Tailnet = hv.OverlayIP != ""
		n.ContainerHost, ni.ContainerHost = hv.ContainerHost, hv.ContainerHost
		n.live = up(hv)
		ni.Host, ni.Role, ni.OverlayIP, ni.LanIP = ns.Host, hv.Role, hv.OverlayIP, hv.LanIP
		if ni.Href == "" && hv.HasEndpoint {
			ni.Href = "/hosts/" + ns.Host
		}
		ni.StateText = stateText(hv, now)
	}
	// A spec node without a label falls back to its host, then its id: no box
	// ever draws an empty heading.
	if n.Label == "" {
		n.Label = ns.Host
	}
	if n.Label == "" {
		n.Label = n.ID
	}
	if n.Kind == "" {
		n.Kind = "device"
	}
	n.Icon = n.Kind
	if !icons[n.Icon] {
		n.Icon = "device"
	}
	ni.Label, ni.Kind, ni.State = n.Label, n.Kind, n.State
	n.Title = n.Label
	if ni.StateText != "" {
		n.Title += " — " + ni.StateText
	}

	for _, l := range ns.Lines {
		n.Lines = append(n.Lines, TextLine{Text: l})
	}
	if ns.Host != "" {
		var ips []string
		for _, ip := range []string{hv.OverlayIP, hv.LanIP} {
			if ip != "" {
				ips = append(ips, ip)
			}
		}
		if len(ips) > 0 {
			n.Lines = append(n.Lines, TextLine{Text: strings.Join(ips, " · "), Class: "mono"})
		}
		if m := metrics(hv); m != "" {
			n.Lines = append(n.Lines, TextLine{Text: m, Class: "metrics"})
			// The panel gets the whole line: the box truncates to its width,
			// the panel has room to show every number.
			ni.Lines = append(ni.Lines, m)
		}
	}
	var services []state.ServiceView
	if ns.Host != "" { // svcByHost[""] holds unplaced services (host = null)
		services = svcByHost[ns.Host]
	}
	for _, s := range services {
		exp, rank := "", 0
		var urls []string
		for _, r := range s.Routes {
			if exposureRank[r.Exposure] > rank {
				exp, rank = r.Exposure, exposureRank[r.Exposure]
			}
			if u := r.URLStr(); u != "" {
				urls = append(urls, u)
			}
		}
		sort.Strings(urls)
		n.Chips = append(n.Chips, Chip{Name: s.Name, Full: s.Name, State: s.Active, Exposure: exp})
		ni.Services = append(ni.Services, ServiceInfo{Name: s.Name, State: s.Active, Exposure: exp, Description: s.Description, URLs: urls})
	}
	if len(n.Chips) > wideChips {
		n.W = wideNodeW
	}
	return n, ni
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

// seenSuffix says when the host was last heard from. The merge precomputes the
// age; a HostView from elsewhere still carries LastSeen, so fall back to it
// rather than dropping the timestamp.
func seenSuffix(hv state.HostView, now time.Time) string {
	age := hv.LastSeenAge
	if age == "" && !hv.LastSeen.IsZero() && !now.IsZero() {
		age = state.FormatAge(now.Sub(hv.LastSeen))
	}
	if age == "" {
		return ""
	}
	return " · last seen " + age + " ago"
}

// metrics renders the CPU/memory/uptime line for a host the merge reports up.
// Numbers from a host that is not reachable would read as live readings.
func metrics(hv state.HostView) string {
	if !up(hv) || hv.Status == nil || hv.Status.System == nil {
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

func flowZone(nodes []*Node, x, y, w int) int {
	// Validate guarantees every zone is wide enough for its padding and one
	// node, so the inner area is positive without a clamp here.
	inner := w - 2*zonePad
	for _, n := range nodes {
		n.W = min(n.W, inner)
		finishNode(n)
	}
	cy := y + zoneHead
	for i := 0; i < len(nodes); {
		j, used := i, 0
		for j < len(nodes) && (j == i || used+nodeGap+nodes[j].W <= inner) {
			if j > i {
				used += nodeGap
			}
			used += nodes[j].W
			j++
		}
		cx := x + zonePad + (inner-used)/2
		rowH := 0
		for _, n := range nodes[i:j] {
			n.X, n.Y = cx, cy
			cx += n.W + nodeGap
			rowH = max(rowH, n.H)
		}
		cy += rowH + nodeGap
		i = j
	}
	if len(nodes) == 0 {
		return minZoneH
	}
	return cy - nodeGap + zonePad - y
}

// finishNode truncates text to the final width and computes the height.
func finishNode(n *Node) {
	// Leave room for the 22px icon and the status/tailnet markers on the
	// right before the heading.
	n.Label = truncate(n.Label, max(2, int(float64(n.W-72)/labelCharW)))
	cy := headH
	for i := range n.Lines {
		n.Lines[i].Text = truncate(n.Lines[i].Text, int(float64(n.W-24)/smallCharW))
		n.Lines[i].Y = cy + 12
		cy += lineH
	}
	// A declared container host always says so, even with nothing on it: the
	// zero count is the information, not a reason to hide the label.
	if n.ContainerHost || len(n.Chips) > 0 {
		cy += 4
		label := plural(len(n.Chips), "container")
		if n.ContainerHost {
			label = "container host · " + label
		}
		n.ChipsLabel = &TextLine{Text: truncate(label, max(2, int(float64(n.W-24)/smallCharW))), Y: cy + 11}
		cy += chipsHead
	}
	if len(n.Chips) > 0 {
		inner := n.W - 24
		cols := max(1, (inner+chipGap)/(minChipW+chipGap))
		cw := (inner - chipGap*(cols-1)) / cols
		for i := range n.Chips {
			c := &n.Chips[i]
			c.X = 12 + (i%cols)*(cw+chipGap)
			c.Y = cy + (i/cols)*(chipH+chipGap)
			c.W = cw
			c.Name = truncate(c.Name, int(float64(cw-20)/smallCharW))
		}
		rows := (len(n.Chips) + cols - 1) / cols
		cy += rows*(chipH+chipGap) - chipGap
	}
	n.H = cy + bottomPad
	n.DotX, n.TsX = n.W-16, n.W-36
}

func truncate(s string, n int) string {
	r := []rune(s)
	if n < 2 || len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

type side int

const (
	top side = iota
	bottom
	left
	right
)

type anchor struct {
	edge  int
	from  bool
	side  side
	other float64 // peer coordinate along the side, for ordering
}

// routeEdges picks a side of each endpoint, spreads endpoints sharing a
// side in the order of their peers (so fans don't cross at the node), and
// writes a cubic path plus its label position.
func routeEdges(edges []Edge, nodes map[string]*Node) {
	type key struct {
		node string
		side side
	}
	groups := map[key][]anchor{}
	sides := make([][2]side, len(edges))
	for i, e := range edges {
		a, b := nodes[e.From], nodes[e.To]
		sa, sb := pickSides(a, b)
		sides[i] = [2]side{sa, sb}
		acx, acy := center(a)
		bcx, bcy := center(b)
		pa, pb := bcx, acx
		if sa == left || sa == right {
			pa = bcy
		}
		if sb == left || sb == right {
			pb = acy
		}
		groups[key{e.From, sa}] = append(groups[key{e.From, sa}], anchor{edge: i, from: true, side: sa, other: pa})
		groups[key{e.To, sb}] = append(groups[key{e.To, sb}], anchor{edge: i, side: sb, other: pb})
	}
	pts := make([][2][2]float64, len(edges))
	for k, list := range groups {
		sort.SliceStable(list, func(i, j int) bool { return list[i].other < list[j].other })
		n := nodes[k.node]
		for i, an := range list {
			// Spread across the middle 70% of the side.
			t := 0.5
			if len(list) > 1 {
				t = 0.15 + 0.7*float64(i)/float64(len(list)-1)
			}
			var p [2]float64
			fx, fy, fw, fh := float64(n.X), float64(n.Y), float64(n.W), float64(n.H)
			switch k.side {
			case top:
				p = [2]float64{fx + fw*t, fy}
			case bottom:
				p = [2]float64{fx + fw*t, fy + fh}
			case left:
				p = [2]float64{fx, fy + fh*t}
			case right:
				p = [2]float64{fx + fw, fy + fh*t}
			}
			idx := 1
			if an.from {
				idx = 0
			}
			pts[an.edge][idx] = p
		}
	}
	for i := range edges {
		p1, p2 := pts[i][0], pts[i][1]
		c1 := control(p1, sides[i][0], p2)
		c2 := control(p2, sides[i][1], p1)
		edges[i].D = fmt.Sprintf("M%.0f %.0f C%.0f %.0f %.0f %.0f %.0f %.0f", p1[0], p1[1], c1[0], c1[1], c2[0], c2[1], p2[0], p2[1])
		// Bezier midpoint (t = 0.5).
		mx := (p1[0] + 3*c1[0] + 3*c2[0] + p2[0]) / 8
		my := (p1[1] + 3*c1[1] + 3*c2[1] + p2[1]) / 8
		edges[i].LX, edges[i].LY = int(mx), int(my)
		edges[i].LW = int(float64(len([]rune(edges[i].Label)))*smallCharW) + 12
		edges[i].LRX, edges[i].LRY = edges[i].LX-edges[i].LW/2, edges[i].LY-9
	}
}

func center(n *Node) (float64, float64) {
	return float64(n.X) + float64(n.W)/2, float64(n.Y) + float64(n.H)/2
}

// pickSides connects vertically separated boxes top/bottom, otherwise by
// their facing left/right sides.
func pickSides(a, b *Node) (side, side) {
	switch {
	case b.Y >= a.Y+a.H:
		return bottom, top
	case a.Y >= b.Y+b.H:
		return top, bottom
	case b.X >= a.X+a.W/2:
		return right, left
	default:
		return left, right
	}
}

func control(p [2]float64, s side, other [2]float64) [2]float64 {
	k := math.Max(36, math.Max(math.Abs(other[0]-p[0]), math.Abs(other[1]-p[1]))*0.4)
	switch s {
	case top:
		return [2]float64{p[0], p[1] - k}
	case bottom:
		return [2]float64{p[0], p[1] + k}
	case left:
		return [2]float64{p[0] - k, p[1]}
	default:
		return [2]float64{p[0] + k, p[1]}
	}
}
