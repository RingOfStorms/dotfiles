// Package topology lays out the /topology diagram: a hand-written spec
// (columns of regions, physical devices, cabling, public DNS zone; supplied by
// the start-page links) merged with what fleet-edge already knows (inventory
// hosts and services, route `via` paths, live poll state). Physical gear the
// inventory can't know about lives in the spec; everything derivable
// (container placement, public paths, tailnet membership, agent polling, DNS
// ownership) is derived so the diagram can't drift.
package topology

import (
	"encoding/json"
	"fmt"
	"os"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// Spec is the hand-written part of the diagram (JSON, --topology).
//
// The diagram is vertical: columns sit left to right, each column stacks its
// regions top to bottom. A column's width is its share of the diagram width
// (Flex); a region's height is its natural content height plus its share of
// the column's leftover space (Flex). Nothing about a column's height affects
// its neighbours.
type Spec struct {
	// Width of the diagram in SVG units; 0 means DefaultWidth.
	Width int `json:"width"`
	// Height is the minimum diagram height in SVG units; 0 means "whatever
	// the tallest column needs". Filling a taller diagram stretches regions
	// with Flex > 0.
	Height  int        `json:"height"`
	Columns []Column   `json:"columns"`
	Nodes   []NodeSpec `json:"nodes"`
	Links   []LinkSpec `json:"links"`
	// DNS is the single source of public name facts: the zone's records
	// (route CNAMEs and hand entries) and the names written outside it. The
	// route cloud is built from this plus the inventory's declared routes, so
	// there is no second list of public FQDNs.
	DNS *DNS `json:"dns"`
	// DefaultZone receives every inventory host the spec doesn't place (so a
	// new host in the fleet registry shows up without a spec edit). "" leaves
	// unplaced hosts out.
	DefaultZone string `json:"defaultZone"`
	// Hide lists inventory hosts never auto-placed.
	Hide []string `json:"hide"`
	Hubs Hubs     `json:"hubs"`
}

// Column is one vertical band of the diagram.
type Column struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Flex shares the diagram width with the other columns. 0 means 1.
	Flex float64 `json:"flex"`
	// Zones stack top to bottom within the column.
	Zones []Zone `json:"zones"`
}

// Zone layouts. A zone either holds stations or is a derived route cloud.
const (
	// LayoutFlow packs stations left to right, wrapping (the default).
	LayoutFlow = "flow"
	// LayoutStack puts one station per row, so a rack reads top to bottom.
	LayoutStack = "stack"
	// LayoutRoutes draws the derived route cloud for Group instead of
	// stations: public names in the zone, or overlay names.
	LayoutRoutes = "routes"
)

// Route-cloud groups.
const (
	// GroupPublic is the public DNS zone: one marker per public FQDN,
	// bundled through the edge hub.
	GroupPublic = "public"
	// GroupOverlay is the tailnet/LAN zone: one dashed lead per marker to
	// the host that serves it.
	GroupOverlay = "overlay"
)

// Zone is a labelled region of a column.
type Zone struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Kind picks the tint: cloud, tailnet, home, rack, lan, roaming (anything
	// else is neutral).
	Kind string `json:"kind"`
	// Flex shares the column's leftover height. 0 means "natural height".
	Flex float64 `json:"flex"`
	// Layout is LayoutFlow, LayoutStack or LayoutRoutes.
	Layout string `json:"layout"`
	// Cols caps items per row; 0 means "as many as fit".
	Cols int `json:"cols"`
	// Fill is "row" (default, left to right then down) or "column" (top to
	// bottom then right) — the rack order.
	Fill string `json:"fill"`
	// Box draws the region as a solid card instead of open ground: one
	// physical enclosure, one green region.
	Box bool `json:"box"`
	// Group selects the route cloud for LayoutRoutes.
	Group string `json:"group"`
}

// fill is the effective fill order.
func (z Zone) fill() string {
	if z.Fill == "column" {
		return "column"
	}
	return "row"
}

// layout is the effective layout.
func (z Zone) layout() string {
	switch z.Layout {
	case LayoutFlow, LayoutStack, LayoutRoutes:
		return z.Layout
	}
	return LayoutFlow
}

// NodeSpec places one station. Host binds it to an inventory host (live
// state, IPs, containers); ID defaults to Host.
type NodeSpec struct {
	ID    string `json:"id"`
	Host  string `json:"host"`
	Label string `json:"label"`
	Kind  string `json:"kind"`
	Zone  string `json:"zone"`
	// Role is the plain-language job of the gear, drawn under its name
	// ("core switch", "reverse proxy"). Hosts default to the inventory role.
	Role string `json:"role"`
	// Segment draws a horizontal bar instead of a station head: a neutral
	// fabric rather than a device. It spans the zone, and its links attach at
	// the bar's ends.
	Segment bool `json:"segment"`
	// Badges are short membership chips ("tailnet", "VLAN 20"). Purely
	// descriptive: nothing is derived from them.
	Badges []string `json:"badges"`
	Lines  []string `json:"lines"`
	// Href makes the info panel link out (hosts link to /hosts/{name}).
	Href string `json:"href"`
}

// LinkSpec is one hand-declared connection (cabling, wifi, control flows).
type LinkSpec struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Kind  string `json:"kind"`
	Label string `json:"label"`
}

// DNS is the public zone: the records bunny serves for this domain.
type DNS struct {
	Zone     string      `json:"zone"`
	Records  []DNSRecord `json:"records"`
	External []string    `json:"external"`
}

// DNSRecord is one record of the public zone. It is also the layout's output
// type, so a record the diagram couldn't attribute keeps Declared=false
// instead of acquiring a guessed owner.
type DNSRecord struct {
	// Name is the record name relative to the zone ("git", "*.share").
	Name string `json:"name"`
	Type string `json:"type"`
	// Value is the target: a CNAME target FQDN, or an A/AAAA address.
	Value string `json:"value"`
	// TTL is kept for the dns-plan document; the diagram ignores it.
	TTL int `json:"ttl,omitempty"`
	// Source names the file/route that declared the record.
	Source string `json:"source,omitempty"`

	// Declared is true when a declared public route serves this name. Only
	// then do Host/Service/RouteKey name an owner: a name that resolves
	// through a CNAME chain is never attributed to a host by guessing.
	Declared bool   `json:"declared"`
	Host     string `json:"host,omitempty"`
	Service  string `json:"service,omitempty"`
	RouteKey string `json:"route,omitempty"`
}

// FQDN is the record's absolute name.
func (r DNSRecord) FQDN(zone string) string {
	if r.Name == "" {
		return zone
	}
	return r.Name + "." + zone
}

// Hubs name the nodes derived edges attach to; "" skips that edge family.
type Hubs struct {
	// Tailnet: coordination server. Empty since the tailnet is drawn as a
	// station tag and per-route leads, not as edges through a coordination
	// node.
	Tailnet string `json:"tailnet"`
	// Edge: public reverse proxy for `via = "edge"` routes.
	Edge string `json:"edge"`
	// Router: port forwards for `via = "router"` routes.
	Router string `json:"router"`
	// Dashboard: where fleet-edge runs; edge to every polled host.
	Dashboard string `json:"dashboard"`
}

// DefaultWidth is the diagram width when the spec doesn't set one.
const DefaultWidth = 1500

// linkLayers maps every accepted link kind to its toggleable layer.
var linkLayers = map[string]string{
	"wan":      "physical",
	"ethernet": "physical",
	"trunk":    "physical",
	"lan":      "physical",
	"wifi":     "physical",
	"kvm":      "physical",
	"power":    "physical",
	"tailnet":  "tailnet",
	"public":   "public",
	"agent":    "control",
	"control":  "control",
}

// LinkLan is the kind for a host attached to the LAN whose switch and port
// were never recorded: a real attachment, drawn dashed, claiming no cable.
const LinkLan = "lan"

// LayerOf returns the layer a link kind belongs to.
func LayerOf(kind string) string { return linkLayers[kind] }

// Layer is one toggleable family of overlays: edges the layout draws, and the
// journey traces topology.js derives from the metadata.
type Layer struct {
	ID, Label string
	// Default is the checkbox state on a first visit.
	Default bool
}

// Layers lists every layer in toggle order.
var Layers = []Layer{
	{"physical", "Physical links", true},
	{"tailnet", "Tailnet paths", true},
	{"public", "Public paths", true},
	{"control", "Agents & control", false},
}

// Default is used when no spec is configured: every host in one region.
func Default() *Spec {
	return &Spec{
		Columns: []Column{{
			ID:   "fleet",
			Flex: 1,
			Zones: []Zone{{
				ID: "fleet", Label: "Fleet", Kind: "rack", Flex: 1,
			}},
		}},
		DefaultZone: "fleet",
	}
}

// Load reads a spec file; "" means Default().
func Load(path string) (*Spec, error) {
	if path == "" {
		return Default(), nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read topology %s: %w", path, err)
	}
	var s Spec
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("parse topology %s: %w", path, err)
	}
	return &s, nil
}

// MinWidth is the narrowest usable column: below it a region's inner area
// cannot hold a station, so layout would draw a box wider than its column. It
// is the station width plus the zone padding on both sides.
const MinWidth = 224

// zones flattens every region, in reading order.
func (s *Spec) zones() []Zone {
	var out []Zone
	for _, c := range s.Columns {
		out = append(out, c.Zones...)
	}
	return out
}

// zone finds a region by id.
func (s *Spec) zone(id string) (Zone, bool) {
	for _, z := range s.zones() {
		if z.ID == id {
			return z, true
		}
	}
	return Zone{}, false
}

// Validate checks every reference against the spec and the inventory, so a
// typo fails at startup instead of silently dropping a box or a cable. It
// also checks that every column the layout would compute is wide enough,
// since proportional flex can starve one column in a wide diagram.
func (s *Spec) Validate(inv *inventory.Inventory) error {
	if s.Width < 0 {
		return fmt.Errorf("topology: width %d is negative", s.Width)
	}
	if s.Height < 0 {
		return fmt.Errorf("topology: height %d is negative", s.Height)
	}
	zones := map[string]Zone{}
	var order []string
	for _, c := range s.Columns {
		if c.Flex < 0 {
			return fmt.Errorf("topology: column %q has negative flex", c.ID)
		}
		if len(c.Zones) == 0 {
			return fmt.Errorf("topology: column %q has no zones", c.ID)
		}
		for _, z := range c.Zones {
			if z.ID == "" {
				return fmt.Errorf("topology: zone with empty id")
			}
			if _, dup := zones[z.ID]; dup {
				return fmt.Errorf("topology: duplicate zone %q", z.ID)
			}
			if z.Flex < 0 {
				return fmt.Errorf("topology: zone %q has negative flex", z.ID)
			}
			if z.Cols < 0 {
				return fmt.Errorf("topology: zone %q has negative cols", z.ID)
			}
			switch z.Layout {
			case "", LayoutFlow, LayoutStack, LayoutRoutes:
			default:
				return fmt.Errorf("topology: zone %q has unknown layout %q", z.ID, z.Layout)
			}
			switch z.Fill {
			case "", "row", "column":
			default:
				return fmt.Errorf("topology: zone %q has unknown fill %q", z.ID, z.Fill)
			}
			switch z.Group {
			case "":
				if z.Layout == LayoutRoutes {
					return fmt.Errorf("topology: zone %q lays out routes but names no group", z.ID)
				}
			case GroupPublic, GroupOverlay:
				if z.Layout != LayoutRoutes {
					return fmt.Errorf("topology: zone %q has group %q but does not lay out routes", z.ID, z.Group)
				}
			default:
				return fmt.Errorf("topology: zone %q has unknown group %q", z.ID, z.Group)
			}
			zones[z.ID] = z
			order = append(order, z.ID)
		}
	}
	if len(order) == 0 {
		return fmt.Errorf("topology: no zones")
	}
	width := s.diagramWidth()
	for i, w := range columnWidths(s.Columns, width) {
		if w >= MinWidth {
			continue
		}
		return fmt.Errorf("topology: column %q would be %d wide in a %d-wide diagram of %d columns (minimum %d)",
			s.Columns[i].ID, w, width, len(s.Columns), MinWidth)
	}
	groups := map[string]string{}
	for _, z := range zones {
		if z.Group == "" {
			continue
		}
		if prev, ok := groups[z.Group]; ok {
			return fmt.Errorf("topology: zones %q and %q both lay out the %s route cloud", prev, z.ID, z.Group)
		}
		groups[z.Group] = z.ID
	}
	if s.DefaultZone != "" {
		z, ok := zones[s.DefaultZone]
		if !ok {
			return fmt.Errorf("topology: defaultZone %q is not a zone", s.DefaultZone)
		}
		if z.layout() == LayoutRoutes {
			return fmt.Errorf("topology: defaultZone %q lays out routes, not stations", s.DefaultZone)
		}
	}
	ids := map[string]bool{}
	placedHosts := map[string]bool{}
	for _, n := range s.Nodes {
		id := n.nodeID()
		if id == "" {
			return fmt.Errorf("topology: node with neither id nor host")
		}
		if ids[id] {
			return fmt.Errorf("topology: duplicate node %q", id)
		}
		ids[id] = true
		z, ok := zones[n.Zone]
		if !ok {
			return fmt.Errorf("topology: node %q in unknown zone %q", id, n.Zone)
		}
		if z.layout() == LayoutRoutes {
			return fmt.Errorf("topology: node %q placed in routes zone %q", id, n.Zone)
		}
		if n.Host != "" {
			if _, ok := inv.Hosts[n.Host]; !ok {
				return fmt.Errorf("topology: node %q binds unknown inventory host %q", id, n.Host)
			}
			if placedHosts[n.Host] {
				return fmt.Errorf("topology: host %q placed twice", n.Host)
			}
			placedHosts[n.Host] = true
		}
	}
	hidden := map[string]bool{}
	for _, h := range s.Hide {
		hidden[h] = true
	}
	if s.DefaultZone != "" {
		for h := range inv.Hosts {
			if !placedHosts[h] && !hidden[h] {
				if ids[h] {
					return fmt.Errorf("topology: node id %q collides with auto-placed host", h)
				}
				ids[h] = true
			}
		}
	}
	for _, l := range s.Links {
		if _, ok := linkLayers[l.Kind]; !ok {
			return fmt.Errorf("topology: link %s->%s has unknown kind %q", l.From, l.To, l.Kind)
		}
		for _, end := range []string{l.From, l.To} {
			if !ids[end] {
				return fmt.Errorf("topology: link %s->%s references unknown node %q", l.From, l.To, end)
			}
		}
		if l.From == l.To {
			return fmt.Errorf("topology: link %s->%s is a self-loop", l.From, l.To)
		}
	}
	for name, hub := range map[string]string{
		"tailnet": s.Hubs.Tailnet, "edge": s.Hubs.Edge,
		"router": s.Hubs.Router, "dashboard": s.Hubs.Dashboard,
	} {
		if hub != "" && !ids[hub] {
			return fmt.Errorf("topology: hubs.%s references unknown node %q", name, hub)
		}
	}
	if s.DNS != nil {
		if err := s.DNS.validate(); err != nil {
			return err
		}
	}
	return nil
}

// validate checks the public zone is answerable: a zone name when records
// exist, and no two records claiming the same name and type.
func (d *DNS) validate() error {
	if len(d.Records) > 0 && d.Zone == "" {
		return fmt.Errorf("topology: dns has %d records but no zone", len(d.Records))
	}
	seen := map[string]bool{}
	for _, r := range d.Records {
		if r.Name == "" {
			return fmt.Errorf("topology: dns zone %q has a record with no name", d.Zone)
		}
		switch r.Type {
		case "A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA":
		default:
			return fmt.Errorf("topology: dns record %q has unknown type %q", r.Name, r.Type)
		}
		if r.Value == "" {
			return fmt.Errorf("topology: dns record %q has no value", r.Name)
		}
		key := r.Name + "/" + r.Type
		if seen[key] {
			return fmt.Errorf("topology: dns declares %q (%s) twice", r.Name, r.Type)
		}
		seen[key] = true
	}
	return nil
}

func (n NodeSpec) nodeID() string {
	if n.ID != "" {
		return n.ID
	}
	return n.Host
}
