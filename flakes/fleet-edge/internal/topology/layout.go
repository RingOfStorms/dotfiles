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
	// AsOf is the snapshot time the layout was built for. /topology.svg is
	// also served for recorded frames, so the client measures ages from this
	// instead of from the wall clock.
	AsOf  time.Time
	Zones []ZoneBox
	Edges []Edge
	Nodes []Node
	// Hubs name the nodes derived paths attach to. The template passes them to
	// topology.js, which builds journeys from them: a public journey is
	// simulated client -> edge hub -> host -> service.
	Hubs Hubs
	// Meta is the JSON node-detail map (id -> NodeInfo) behind the sidebar
	// drilldown: every technical fact lives there, not on the diagram.
	Meta string
}

// ZoneBox is a laid-out region: open ground with a label, not a card.
type ZoneBox struct {
	ID, Label, Kind string
	X, Y, W, H      int
}

// Node is a laid-out station: one circular head with the icon, the name, the
// plain role under it and, when it has any, the membership tags.
//
// HeadX/HeadY/R and the text baselines are box-local, so the template only
// needs a single translate; CenterX/CenterY give the absolute point that
// links and journeys attach to.
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
	// SvcCount is every declared service here, SvcFailed those that are not
	// running. Warn counts disk health problems; neither is security.
	SvcCount, SvcFailed, Warn int
	// Tailnet marks overlay membership; ContainerHost says the inventory
	// declares containers here even when there are none yet.
	Tailnet       bool
	ContainerHost bool
	Title         string
	// live: confirmed present right now. Static gear always is; only links
	// between live stations are drawn as live.
	live bool
}

// CenterX, CenterY are the absolute head centre.
func (n Node) CenterX() int { return n.X + n.HeadX }
func (n Node) CenterY() int { return n.Y + n.HeadY }

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
// snapshot time, each section's own timestamp and each section's expected
// cadence, so a 15-minute SMART refresh is not called stale by a 1-minute
// fail2ban expectation (or the reverse).
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
	Links     []LinkInfo    `json:"links,omitempty"`
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
	// ContainerHost: containers are declared on this host even when there are
	// none right now. Deliberately no omitempty: false is meaningful.
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
	// Public: a genuinely public route (exposure public) that reaches the
	// service through the edge hub (Via contains "edge"). ViaRouter marks a
	// public route that terminates on the router instead — a different hub, so
	// a journey must not pretend it goes through the edge.
	Public    bool `json:"public"`
	ViaRouter bool `json:"viaRouter"`
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

// Geometry (SVG units). Text widths are estimates for system-ui.
const (
	zonePad    = 22
	zoneHead   = 40
	zoneGap    = 26
	rowGap     = 40
	minZoneH   = 168
	stationW   = 180
	stationH   = 92
	stationR   = 18
	stationGX  = 26
	stationGY  = 28
	originBand = 74
	labelCharW = 7.4
	smallCharW = 6.0
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

// Build lays out spec against the merged state, as of now. The spec must have
// passed Validate against the inventory the state was merged from; a reference
// that still doesn't resolve (inventory changed underneath) is skipped rather
// than drawn wrong.
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

	d := Diagram{Width: width, AsOf: now, Hubs: spec.Hubs}
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

	y := originBand
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
			rowH = max(rowH, flowZone(byZone[z.ID], x, y, w))
			d.Zones = append(d.Zones, ZoneBox{ID: z.ID, Label: z.Label, Kind: z.Kind, X: x, Y: y, W: w})
			x += w + zoneGap
		}
		for i := start; i < len(d.Zones); i++ {
			d.Zones[i].H = rowH
		}
		y += rowH + rowGap
	}
	d.Height = max(y-rowGap+zonePad, originBand+minZoneH)

	// Station draw order: spec order, so later stations sit on top.
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
	// Agent polling is the only derived edge family: a real, recorded
	// relationship (fleet-edge asks each agent every 30s). Tailnet membership
	// is a station tag and public paths are journeys, never permanent rails.
	hostNode := map[string]string{}
	var hostNames []string
	for _, n := range nodes {
		if n.Host != "" {
			hostNode[n.Host] = n.ID
			hostNames = append(hostNames, n.Host)
		}
	}
	sort.Strings(hostNames)
	for _, h := range hostNames {
		if spec.Hubs.Dashboard != "" && hosts[h].HasEndpoint {
			add(spec.Hubs.Dashboard, hostNode[h], "agent", "")
		}
	}
	routeStations(edges, nodes)
	d.Edges = edges

	for _, e := range edges {
		a, b := nodes[e.From], nodes[e.To]
		info[e.From].Links = append(info[e.From].Links, LinkInfo{Kind: e.Kind, Layer: e.Layer, Peer: e.To, PeerLabel: b.Label, Label: e.Label, Out: true})
		info[e.To].Links = append(info[e.To].Links, LinkInfo{Kind: e.Kind, Layer: e.Layer, Peer: e.From, PeerLabel: a.Label, Label: e.Label})
	}
	for id, n := range nodes {
		info[id].X, info[id].Y = float64(n.CenterX()), float64(n.CenterY())
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
// the very same arithmetic, so a spec it accepts always lays out in bounds.
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

// buildNode fills a station's content and its drilldown payload.
func buildNode(ns NodeSpec, hosts map[string]state.HostView, svcByHost map[string][]state.ServiceView, now time.Time) (*Node, *NodeInfo) {
	n := &Node{ID: ns.nodeID(), Label: ns.Label, Kind: ns.Kind, Host: ns.Host, Role: ns.Role, State: "static", live: true}
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
				if driveUnhealthy(dr) {
					ni.SmartFailed++
				} else if !dr.Standby {
					ni.SmartOK++
				}
			}
			ni.DiskWarnings = diskProblems(st)
			// Gauges from an absent host are history: the sidebar labels them
			// last known instead of drawing a live dial.
			if n.live {
				ni.System = st.System
			}
		}
		if m := systemLine(hv); m != "" && n.live {
			ni.Lines = append(ni.Lines, m)
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
	n.Title = n.Label
	if n.Role != "" {
		n.Title += " · " + n.Role
	}
	if ni.StateText != "" && ni.StateText != "online" {
		n.Title += " — " + ni.StateText
	}

	if ns.Host != "" { // svcByHost[""] holds services not placed on a host
		for _, s := range svcByHost[ns.Host] {
			exp, rank := "", 0
			var urls []string
			public, viaRouter := false, false
			si := ServiceInfo{Name: s.Name, State: s.Active, Description: s.Description}
			for _, r := range s.Routes {
				if exposureRank[r.Exposure] > rank {
					exp, rank = r.Exposure, exposureRank[r.Exposure]
				}
				if r.Exposure == "public" {
					// Only a public route can be public, and where it enters
					// decides the hub: edge hub, or the router if it terminates
					// there. Anything else is not a public path at all.
					switch {
					case contains(r.Via, "edge"):
						public = true
					case contains(r.Via, "router"):
						viaRouter = true
					}
				}
				if u := r.URLStr(); u != "" {
					urls = append(urls, u)
				}
				if si.Proto == "" && r.Proto != "" {
					si.Proto, si.Port = r.Proto, r.Port
				}
			}
			sort.Strings(urls)
			si.Exposure, si.URLs, si.Public, si.ViaRouter = exp, urls, public, viaRouter
			if s.Active != "active" && s.Active != "" && s.Active != "unknown" {
				ni.SvcFailed++
			}
			ni.Services = append(ni.Services, si)
			n.SvcCount++
		}
	}
	n.SvcFailed = ni.SvcFailed
	n.Warn = ni.DiskWarnings
	return n, ni
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
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

// diskProblems counts what the station should flag: unhealthy drives and
// pools that are degraded or logging IO errors. A pool is counted once even
// when several submounts report the same array.
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

// flowZone places fixed-size stations in rows inside a zone and returns the
// zone height the region needs. Fixed stations keep the map legible instead
// of growing a box per service.
func flowZone(nodes []*Node, x, y, w int) int {
	inner := w - 2*zonePad
	cols := max(1, (inner+stationGX)/(stationW+stationGX))
	cy := y + zoneHead
	for i := 0; i < len(nodes); i += cols {
		row := nodes[i:min(i+cols, len(nodes))]
		used := len(row)*stationW + (len(row)-1)*stationGX
		cx := x + zonePad + max(0, (inner-used)/2)
		for _, n := range row {
			finishNode(n, cx, cy)
			cx += stationW + stationGX
		}
		cy += stationH + stationGY
	}
	if len(nodes) == 0 {
		return minZoneH
	}
	return cy - stationGY + zonePad - y
}

// finishNode fixes a station's box and its box-local geometry: head circle,
// name, role, then one quiet line of membership tags.
func finishNode(n *Node, x, y int) {
	n.X, n.Y, n.W, n.H = x, y, stationW, stationH
	n.HeadX, n.HeadY, n.R = stationW/2, stationR+6, stationR
	n.LabelY, n.RoleY = n.HeadY+n.R+16, n.HeadY+n.R+29
	n.TagsY = n.RoleY + 13
	n.Label = truncate(n.Label, max(2, int(float64(n.W-16)/labelCharW)))
	n.Role = truncate(n.Role, max(2, int(float64(n.W-16)/smallCharW)))
	n.Tags = truncate(n.Tags, max(2, int(float64(n.W-16)/smallCharW)))
	n.IconX, n.IconY = n.HeadX-10, n.HeadY-10
	n.DotX = n.HeadX - n.R - 4
	n.TsX, n.TsY = n.HeadX-5, n.HeadY+n.R-5
	n.CountX, n.CountY, n.WarnY = n.HeadX+n.R+7, n.HeadY-4, n.HeadY+11
}

func truncate(s string, n int) string {
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

// routeStations draws orthogonal M/L paths between station heads: a stub out
// of each circle, one elbow, and a label at the bend. No curves and no fans:
// a link is a fact, not decoration.
func routeStations(edges []Edge, nodes map[string]*Node) {
	for i := range edges {
		a, b := nodes[edges[i].From], nodes[edges[i].To]
		ax, ay := float64(a.CenterX()), float64(a.CenterY())
		bx, by := float64(b.CenterX()), float64(b.CenterY())
		sa, sb := pickSides(a, b)
		p1 := stub(ax, ay, sa)
		p2 := stub(bx, by, sb)
		var d string
		var mid [2]float64
		if sa == left || sa == right {
			mx := (p1[0] + p2[0]) / 2
			d = fmt.Sprintf("M%.0f %.0f L%.0f %.0f L%.0f %.0f L%.0f %.0f", p1[0], p1[1], mx, p1[1], mx, p2[1], p2[0], p2[1])
			mid = [2]float64{mx, (p1[1] + p2[1]) / 2}
		} else {
			my := (p1[1] + p2[1]) / 2
			d = fmt.Sprintf("M%.0f %.0f L%.0f %.0f L%.0f %.0f L%.0f %.0f", p1[0], p1[1], p1[0], my, p2[0], my, p2[0], p2[1])
			mid = [2]float64{(p1[0] + p2[0]) / 2, my}
		}
		edges[i].D = d
		edges[i].LX, edges[i].LY = int(mid[0]), int(mid[1])
		edges[i].LW = int(float64(len([]rune(edges[i].Label)))*smallCharW) + 12
		edges[i].LRX, edges[i].LRY = edges[i].LX-edges[i].LW/2, edges[i].LY-9
	}
}

// pickSides connects vertically separated stations through head top/bottom,
// otherwise through their facing sides.
func pickSides(a, b *Node) (side, side) {
	switch {
	case b.CenterY() > a.CenterY()+2*stationR:
		return below, above
	case a.CenterY() > b.CenterY()+2*stationR:
		return above, below
	case b.CenterX() >= a.CenterX():
		return right, left
	default:
		return left, right
	}
}

// stub is the point on a station's circle in the given direction.
func stub(cx, cy float64, s side) [2]float64 {
	r := float64(stationR)
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
