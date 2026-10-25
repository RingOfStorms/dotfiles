// Package inventory parses the fleet inventory JSON produced by
// `nix eval --json <containers-flake>#inventory`. The shape is defined by
// containers/flake.nix and containers/cli/main.go; routes is a newer,
// optional field (absent on services that haven't adopted it yet).
package inventory

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// Route describes one declared route on a service, per
// containers/ROUTING-PLAN.md §2. All fields are informational here;
// fleet-edge does not enforce or generate anything from them yet.
type Route struct {
	Port     int     `json:"port"`
	Name     *string `json:"name"`
	FQDN     *string `json:"fqdn"`
	URL      *string `json:"url"`
	Proto    string  `json:"proto"`
	Exposure string  `json:"exposure"`
	Auth     *string `json:"auth"`
	// Via lists the public paths for this route (ROUTING-PLAN.md §2.4),
	// e.g. ["edge"] or ["router"]; empty/absent for non-public routes.
	Via    []string `json:"via"`
	Health *string  `json:"health"`
	// Icon is an optional start-page icon: a URL or a CDN icon name.
	Icon *string `json:"icon"`
	// Group is an optional start-page category for the route's tile.
	Group *string `json:"group"`
	// Fields the expose-override service (internal/overrides) validates
	// against and pushes to the edge. Absent in older inventories (zero
	// values: refused there, never guessed).
	Zone              *string `json:"zone"`
	PublicWithoutAuth bool    `json:"publicWithoutAuth"`
	Websockets        bool    `json:"websockets"`
	MaxBody           string  `json:"maxBody"`
	Buffering         bool    `json:"buffering"`
	RequestBuffering  *bool   `json:"requestBuffering"`
	Timeouts          string  `json:"timeouts"`
}

// Str returns s dereferenced, or "" if s is nil. Used by templates and
// tests to render the nullable string fields above.
func Str(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// FQDNStr, URLStr, AuthStr and NameStr return the nullable string fields
// as plain strings ("" if null), for use in templates. ViaStr joins the
// via list with ", " ("" if empty/absent, e.g. non-public routes).
func (r Route) FQDNStr() string  { return Str(r.FQDN) }
func (r Route) URLStr() string   { return Str(r.URL) }
func (r Route) AuthStr() string  { return Str(r.Auth) }
func (r Route) NameStr() string  { return Str(r.Name) }
func (r Route) ViaStr() string   { return strings.Join(r.Via, ", ") }
func (r Route) IconStr() string  { return Str(r.Icon) }
func (r Route) GroupStr() string { return Str(r.Group) }

// Service is one entry of inventory.services.
type Service struct {
	Name        string            `json:"name"`
	Kind        string            `json:"kind"`
	Host        string            `json:"host"`
	Description string            `json:"description"`
	Persist     map[string]string `json:"persist"`
	TCPPorts    []int             `json:"tcpPorts"`
	UDPPorts    []int             `json:"udpPorts"`
	Nginx       *string           `json:"nginx"`
	// Routes may be absent entirely on services that haven't migrated to
	// the routes model yet (ROUTING-PLAN.md §2). Treat missing as empty.
	Routes map[string]Route `json:"routes"`
}

// Host is one entry of inventory.hosts.
type Host struct {
	User      string   `json:"user"`
	OverlayIP *string  `json:"overlayIp"`
	LanIP     *string  `json:"lanIp"`
	PublicIP  *string  `json:"publicIp"`
	Trust     string   `json:"trust"`
	Role      string   `json:"role"`
	AlwaysOn  *bool    `json:"alwaysOn"`
	Replaces  []string `json:"replaces"`
}

// IsAlwaysOn reports whether the host is expected to be online 24/7.
// Defaults to true when Role == "server" or AlwaysOn is nil on a containerHost.
func (h Host) IsAlwaysOn() bool {
	if h.AlwaysOn != nil {
		return *h.AlwaysOn
	}
	return h.Role == "" || h.Role == "server"
}

// Inventory is the full document.
type Inventory struct {
	Services       map[string]Service `json:"services"`
	Hosts          map[string]Host    `json:"hosts"`
	ContainerHosts []string           `json:"containerHosts"`
	AgentHosts     []string           `json:"agentHosts"`
}

// Load reads and parses the inventory JSON file at path.
func Load(path string) (*Inventory, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read inventory %s: %w", path, err)
	}
	return Parse(b)
}

// Parse parses inventory JSON from bytes. Missing "routes" on a service
// unmarshals to a nil map, which callers must treat as empty.
func Parse(b []byte) (*Inventory, error) {
	var inv Inventory
	if err := json.Unmarshal(b, &inv); err != nil {
		return nil, fmt.Errorf("parse inventory: %w", err)
	}
	if inv.Services == nil {
		inv.Services = map[string]Service{}
	}
	if inv.Hosts == nil {
		inv.Hosts = map[string]Host{}
	}
	return &inv, nil
}

// PolledHosts returns the hosts that run a status/fleet-agent endpoint:
// inventory agentHosts (plus any host in Hosts with a declared Role), or
// containerHosts, or (if both are empty) every host with at least one
// service. Only names present in Hosts are returned, sorted.
func (inv *Inventory) PolledHosts() []string {
	set := map[string]bool{}
	for _, h := range inv.AgentHosts {
		set[h] = true
	}
	for name, h := range inv.Hosts {
		if h.Role != "" && h.OverlayIP != nil && *h.OverlayIP != "" {
			set[name] = true
		}
	}
	if len(inv.ContainerHosts) > 0 {
		for _, h := range inv.ContainerHosts {
			set[h] = true
		}
	} else if len(set) == 0 {
		for _, s := range inv.Services {
			if s.Host != "" {
				set[s.Host] = true
			}
		}
	}
	var out []string
	for h := range set {
		if _, ok := inv.Hosts[h]; ok {
			out = append(out, h)
		}
	}
	sort.Strings(out)
	return out
}

// CanonicalHost maps any retired host name declared in another host's
// `replaces` list (e.g. "h002" -> "h004") to its successor.
func (inv *Inventory) CanonicalHost(name string) string {
	if inv == nil {
		return name
	}
	if _, ok := inv.Hosts[name]; ok {
		return name
	}
	for canon, h := range inv.Hosts {
		for _, old := range h.Replaces {
			if old == name {
				return canon
			}
		}
	}
	return name
}
