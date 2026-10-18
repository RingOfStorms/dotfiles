// Package inventory parses the fleet inventory JSON produced by
// `nix eval --json <containers-flake>#inventory`. The shape is defined by
// containers/flake.nix and containers/cli/main.go; routes is a newer,
// optional field (absent on services that haven't adopted it yet).
package inventory

import (
	"encoding/json"
	"fmt"
	"os"
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
func (r Route) FQDNStr() string { return Str(r.FQDN) }
func (r Route) URLStr() string  { return Str(r.URL) }
func (r Route) AuthStr() string { return Str(r.Auth) }
func (r Route) NameStr() string { return Str(r.Name) }
func (r Route) ViaStr() string  { return strings.Join(r.Via, ", ") }

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
	User      string  `json:"user"`
	OverlayIP *string `json:"overlayIp"`
	LanIP     *string `json:"lanIp"`
}

// Inventory is the full document.
type Inventory struct {
	Services       map[string]Service `json:"services"`
	Hosts          map[string]Host    `json:"hosts"`
	ContainerHosts []string           `json:"containerHosts"`
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
