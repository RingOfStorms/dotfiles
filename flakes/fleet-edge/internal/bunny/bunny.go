// Package bunny plans public DNS changes for one bunny.net zone
// (containers/ROUTING-PLAN.md §5.2, §8 step 4).
//
// The desired record set is generated at build time from the container
// routes plus a hand-kept list (hosts/h005). Plan compares it with the live
// zone and never touches a record it doesn't own: records in the zone that
// aren't declared are reported as unmanaged and left alone. There is no
// write path in this package yet; the first runs are diff only.
package bunny

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

// bunny's numeric record types (https://docs.bunny.net/reference/dnszonepublic_index).
var typeNames = map[int]string{
	0: "A", 1: "AAAA", 2: "CNAME", 3: "TXT", 4: "MX", 5: "REDIRECT", 6: "FLATTEN",
	7: "PULLZONE", 8: "SRV", 9: "CAA", 10: "PTR", 11: "SCRIPT", 12: "NS",
}

// TypeName renders a bunny record type ("A", "CNAME", or "TYPE<n>").
func TypeName(t int) string {
	if n, ok := typeNames[t]; ok {
		return n
	}
	return fmt.Sprintf("TYPE%d", t)
}

// Record is one live record in the zone (subset of bunny's JSON).
type Record struct {
	ID    int64  `json:"Id"`
	Type  int    `json:"Type"`
	Name  string `json:"Name"` // label relative to the zone, "" = apex
	Value string `json:"Value"`
	TTL   int    `json:"Ttl"`
}

// Zone is one bunny DNS zone with its records.
type Zone struct {
	ID      int64    `json:"Id"`
	Domain  string   `json:"Domain"`
	Records []Record `json:"Records"`
}

// Desired is one declared record.
type Desired struct {
	Name   string `json:"name"` // label relative to the zone
	Type   string `json:"type"` // "A", "AAAA", "CNAME", "TXT"
	Value  string `json:"value"`
	TTL    int    `json:"ttl"`
	Source string `json:"source"` // e.g. "immich.web" or "hand"
}

// Spec is the build-time input (hosts/h005, JSON).
type Spec struct {
	Zone    string    `json:"zone"`
	Records []Desired `json:"records"`
	// External lists names written by something else on purpose (e.g. the
	// DDNS updater owns "home"). They are reported as such, never planned.
	External []string `json:"external"`
}

// Action kinds.
const (
	Keep      = "keep"      // live record matches
	Create    = "create"    // declared, missing
	Update    = "update"    // declared, same name+type, value or ttl differs
	Conflict  = "conflict"  // declared name exists with another type: needs a human
	External  = "external"  // owned by another writer (DDNS)
	Unmanaged = "unmanaged" // in the zone, not declared: left alone
)

// Change is one line of the plan.
type Change struct {
	Action string
	Name   string
	Type   string
	Old    string // value/ttl now
	New    string // value/ttl wanted
	ID     int64
	Source string
}

// LoadSpec reads the desired record set.
func LoadSpec(path string) (*Spec, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Spec
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := s.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &s, nil
}

// Validate refuses duplicate and external targets (ROUTING-PLAN §4: every
// name in the zone must point at a server we control).
func (s *Spec) Validate() error {
	if s.Zone == "" {
		return fmt.Errorf("zone is empty")
	}
	seen := map[string]bool{}
	for _, d := range s.Records {
		k := strings.ToLower(d.Name) + "/" + d.Type
		if seen[k] {
			return fmt.Errorf("%s %s declared twice", d.Name, d.Type)
		}
		seen[k] = true
		switch d.Type {
		case "A", "AAAA", "TXT":
		case "CNAME":
			v := strings.TrimSuffix(strings.ToLower(d.Value), ".")
			if v != s.Zone && !strings.HasSuffix(v, "."+s.Zone) {
				return fmt.Errorf("%s CNAME %s: target outside %s is not allowed", d.Name, d.Value, s.Zone)
			}
		default:
			return fmt.Errorf("%s: type %s not supported", d.Name, d.Type)
		}
		if d.TTL < 60 {
			return fmt.Errorf("%s: ttl %d < 60", d.Name, d.TTL)
		}
	}
	return nil
}

func norm(v string) string { return strings.TrimSuffix(strings.ToLower(v), ".") }

func fmtVal(v string, ttl int) string { return fmt.Sprintf("%s ttl=%d", v, ttl) }

// Plan compares the spec with a live zone. Pure; no I/O.
func Plan(spec *Spec, z *Zone) []Change {
	var out []Change
	external := map[string]bool{}
	for _, n := range spec.External {
		external[strings.ToLower(n)] = true
	}
	byName := map[string][]Record{}
	for _, r := range z.Records {
		byName[strings.ToLower(r.Name)] = append(byName[strings.ToLower(r.Name)], r)
	}
	declared := map[string]bool{}
	for _, d := range spec.Records {
		name := strings.ToLower(d.Name)
		declared[name] = true
		var same, other []Record
		for _, r := range byName[name] {
			if TypeName(r.Type) == d.Type {
				same = append(same, r)
			} else {
				other = append(other, r)
			}
		}
		c := Change{Name: d.Name, Type: d.Type, New: fmtVal(d.Value, d.TTL), Source: d.Source}
		switch {
		case len(same) == 1:
			r := same[0]
			c.ID, c.Old = r.ID, fmtVal(r.Value, r.TTL)
			if norm(r.Value) == norm(d.Value) && r.TTL == d.TTL {
				c.Action = Keep
			} else {
				c.Action = Update
			}
		case len(same) > 1:
			c.Action, c.Old = Conflict, fmt.Sprintf("%d %s records", len(same), d.Type)
		case len(other) > 0:
			r := other[0]
			c.Action, c.ID, c.Old = Conflict, r.ID, TypeName(r.Type)+" "+fmtVal(r.Value, r.TTL)
		default:
			c.Action = Create
		}
		out = append(out, c)
	}
	for _, r := range z.Records {
		name := strings.ToLower(r.Name)
		if declared[name] {
			continue
		}
		a := Unmanaged
		if external[name] {
			a = External
		}
		out = append(out, Change{Action: a, Name: r.Name, Type: TypeName(r.Type), Old: fmtVal(r.Value, r.TTL), ID: r.ID})
	}
	order := map[string]int{Conflict: 0, Create: 1, Update: 2, Keep: 3, External: 4, Unmanaged: 5}
	sort.SliceStable(out, func(i, j int) bool {
		if order[out[i].Action] != order[out[j].Action] {
			return order[out[i].Action] < order[out[j].Action]
		}
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].Type < out[j].Type
	})
	return out
}

// Render prints a plan as a fixed-width table plus a summary line.
func Render(w io.Writer, zone string, plan []Change) {
	counts := map[string]int{}
	for _, c := range plan {
		counts[c.Action]++
		name := c.Name
		if name == "" {
			name = "@"
		}
		line := fmt.Sprintf("%-9s %-14s %-5s", c.Action, name, c.Type)
		switch c.Action {
		case Create:
			line += "  + " + c.New
		case Update, Conflict:
			line += "  " + c.Old + "  ->  " + c.New
		default:
			line += "  " + c.Old
		}
		if c.Source != "" {
			line += "  [" + c.Source + "]"
		}
		fmt.Fprintln(w, strings.TrimRight(line, " "))
	}
	fmt.Fprintf(w, "\n%s: %d create, %d update, %d conflict, %d keep, %d external, %d unmanaged (never deleted)\n",
		zone, counts[Create], counts[Update], counts[Conflict], counts[Keep], counts[External], counts[Unmanaged])
}

// Client reads zones from the bunny API. Read-only on purpose.
type Client struct {
	Key  string
	Base string // default https://api.bunny.net
	HTTP *http.Client
}

// ZoneByDomain fetches the zone (records embedded) for domain.
func (c *Client) ZoneByDomain(ctx context.Context, domain string) (*Zone, error) {
	base := c.Base
	if base == "" {
		base = "https://api.bunny.net"
	}
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/dnszone?page=1&perPage=1000", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("AccessKey", c.Key)
	req.Header.Set("Accept", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bunny GET /dnszone: %s", resp.Status)
	}
	var page struct {
		Items []Zone `json:"Items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return nil, fmt.Errorf("bunny GET /dnszone: %w", err)
	}
	for i := range page.Items {
		if strings.EqualFold(page.Items[i].Domain, domain) {
			return &page.Items[i], nil
		}
	}
	return nil, fmt.Errorf("zone %s not found in bunny", domain)
}
