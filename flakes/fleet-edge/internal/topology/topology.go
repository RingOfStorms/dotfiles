// Package topology lays out the /topology diagram: a hand-written spec
// (zones, physical devices, cabling, explanatory notes; supplied by the
// host config like the start-page links) merged with what fleet-edge
// already knows (inventory hosts and services, route `via` paths, live poll
// state). Physical gear the inventory can't know about lives in the spec;
// everything derivable (container placement, public paths, tailnet
// membership, agent polling) is derived so the diagram can't drift.
package topology

import (
	"encoding/json"
	"fmt"
	"os"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// Spec is the hand-written part of the diagram (JSON, --topology).
type Spec struct {
	// Width of the diagram in SVG units; 0 means DefaultWidth.
	Width int `json:"width"`
	// Rows stack top to bottom; each row's zones sit side by side with
	// widths proportional to Flex and share the tallest zone's height.
	Rows  []Row      `json:"rows"`
	Nodes []NodeSpec `json:"nodes"`
	Links []LinkSpec `json:"links"`
	// DefaultZone receives every inventory host the spec doesn't place
	// (so a new host in the fleet registry shows up without a spec edit).
	// "" leaves unplaced hosts out.
	DefaultZone string `json:"defaultZone"`
	// Hide lists inventory hosts never auto-placed.
	Hide []string `json:"hide"`
	Hubs Hubs     `json:"hubs"`
	// Notes are the "how it works" panel next to the diagram.
	Notes []Note `json:"notes"`
}

// Row is one horizontal band of zones.
type Row struct {
	Zones []Zone `json:"zones"`
}

// Zone is a labelled region nodes flow into (left to right, wrapping).
type Zone struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Kind picks the tint: internet, cloud, tailnet, home, rack, lan,
	// roaming (anything else is neutral).
	Kind string  `json:"kind"`
	Flex float64 `json:"flex"`
}

// NodeSpec places one box. Host binds it to an inventory host (live state,
// IPs, containers); ID defaults to Host.
type NodeSpec struct {
	ID    string   `json:"id"`
	Host  string   `json:"host"`
	Label string   `json:"label"`
	Kind  string   `json:"kind"`
	Zone  string   `json:"zone"`
	Lines []string `json:"lines"`
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

// Hubs name the nodes derived edges attach to; "" skips that edge family.
type Hubs struct {
	// Tailnet: coordination server; edge to every node with an overlay IP.
	Tailnet string `json:"tailnet"`
	// Edge: public reverse proxy for `via = "edge"` routes.
	Edge string `json:"edge"`
	// Router: port forwards for `via = "router"` routes.
	Router string `json:"router"`
	// Dashboard: where fleet-edge runs; edge to every polled host.
	Dashboard string `json:"dashboard"`
}

// Note is one paragraph of the explanation panel.
type Note struct {
	Title string `json:"title"`
	Text  string `json:"text"`
}

// DefaultWidth is the diagram width when the spec doesn't set one.
const DefaultWidth = 1800

// linkLayers maps every accepted link kind to its toggleable layer.
var linkLayers = map[string]string{
	"wan":      "physical",
	"ethernet": "physical",
	"trunk":    "physical",
	"wifi":     "physical",
	"kvm":      "physical",
	"power":    "physical",
	"tailnet":  "tailnet",
	"public":   "public",
	"agent":    "control",
	"control":  "control",
}

// LayerOf returns the layer a link kind belongs to.
func LayerOf(kind string) string { return linkLayers[kind] }

// Layer is one toggleable family of edges.
type Layer struct{ ID, Label string }

// Layers lists every layer in toggle order.
var Layers = []Layer{
	{"physical", "Physical"},
	{"tailnet", "Tailnet"},
	{"public", "Public paths"},
	{"control", "Agents & control"},
}

// Default is used when no spec is configured: every host in one zone.
func Default() *Spec {
	return &Spec{
		Rows:        []Row{{Zones: []Zone{{ID: "fleet", Label: "Fleet", Flex: 1}}}},
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

// MinWidth is the narrowest usable zone: below it a zone's inner area cannot
// hold a node box, so layout would draw boxes wider than the zone.
const MinWidth = 200

// Validate checks every reference against the spec and the inventory, so a
// typo fails at startup instead of silently dropping a box or a cable. It
// also checks that every zone the layout would compute is wide enough, since
// proportional flex can starve one zone in a wide diagram.
func (s *Spec) Validate(inv *inventory.Inventory) error {
	if s.Width < 0 {
		return fmt.Errorf("topology: width %d is negative", s.Width)
	}
	zones := map[string]bool{}
	for _, r := range s.Rows {
		for _, z := range r.Zones {
			if z.ID == "" {
				return fmt.Errorf("topology: zone with empty id")
			}
			if zones[z.ID] {
				return fmt.Errorf("topology: duplicate zone %q", z.ID)
			}
			if z.Flex < 0 {
				return fmt.Errorf("topology: zone %q has negative flex", z.ID)
			}
			zones[z.ID] = true
		}
	}
	width := s.diagramWidth()
	for _, row := range s.Rows {
		if len(row.Zones) == 0 {
			continue
		}
		for i, w := range zoneWidths(row, width) {
			if w >= MinWidth {
				continue
			}
			return fmt.Errorf("topology: zone %q would be %d wide in a %d-wide diagram of %d zones (minimum %d)",
				row.Zones[i].ID, w, width, len(row.Zones), MinWidth)
		}
	}
	if len(zones) == 0 {
		return fmt.Errorf("topology: no zones")
	}
	if s.DefaultZone != "" && !zones[s.DefaultZone] {
		return fmt.Errorf("topology: defaultZone %q is not a zone", s.DefaultZone)
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
		if !zones[n.Zone] {
			return fmt.Errorf("topology: node %q in unknown zone %q", id, n.Zone)
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
	return nil
}

func (n NodeSpec) nodeID() string {
	if n.ID != "" {
		return n.ID
	}
	return n.Host
}
