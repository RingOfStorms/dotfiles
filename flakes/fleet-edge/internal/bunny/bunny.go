// Package bunny plans public DNS changes for one bunny.net zone
// (containers/ROUTING-PLAN.md §5.2, §8 step 4).
//
// The desired record set is generated at build time from the container
// routes plus a hand-kept list (hosts/h005). Plan compares it with the live
// zone and never touches a record it doesn't own: records in the zone that
// aren't declared are reported as unmanaged and left alone. There is no
// write path except Apply, which only executes a plan's create/update/retire
// rows; retire deletes only records listed exactly (name, type, value).
package bunny

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"syscall"
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
	// Service is the container service a generated route record belongs to
	// ("" for hand-kept names). Such a record is published only while the
	// placement registry places the service (ForPlacements).
	Service string `json:"service,omitempty"`
}

// Spec is the build-time input (hosts/h005, JSON).
type Spec struct {
	Zone    string    `json:"zone"`
	Records []Desired `json:"records"`
	// External lists names written by something else on purpose (e.g. the
	// DDNS updater owns "home"). They are reported as such, never planned.
	External []string `json:"external"`
	// Retire lists records to delete: only a live record matching name,
	// type and value exactly is deleted. Anything else under that name is
	// reported as retire-mismatch and blocks Apply.
	Retire []Retired `json:"retire"`
}

// Retired is one record to delete.
type Retired struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Value string `json:"value"`
}

// Action kinds.
const (
	Keep      = "keep"      // live record matches
	Create    = "create"    // declared, missing
	Update    = "update"    // declared, same name+type, value or ttl differs
	Conflict  = "conflict"  // declared name exists with another type: needs a human
	External  = "external"  // owned by another writer (DDNS)
	Unmanaged = "unmanaged" // in the zone, not declared: left alone
	Retire    = "retire"    // listed in Retire and matching exactly: delete
	// RetireMismatch: a Retire entry's name exists with another type or
	// value. Never deleted; blocks Apply until the list is fixed.
	RetireMismatch = "retire-mismatch"
	// Override: a record created by an active `cnt expose` public override
	// (internal/overrides, ROUTING-PLAN §8 step 7). Owned by that service:
	// never retired, updated or counted as a conflict here; Ops skips it.
	Override = "override"
)

// Owned is one zone record held by an active expose override, by bunny id.
type Owned struct {
	ID      int64  `json:"recordId"`
	Name    string `json:"name"`
	Service string `json:"service"`
}

// Change is one line of the plan.
type Change struct {
	Action string
	Name   string
	Type   string
	Old    string // value/ttl now
	New    string // value/ttl wanted
	ID     int64
	Source string
	// wanted record, for Apply (create/update)
	Value string
	TTL   int
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
	for _, r := range s.Retire {
		if _, err := typeNumber(r.Type); err != nil || r.Name == "" || r.Value == "" {
			return fmt.Errorf("retire %q %s %q: need name, a known type and value", r.Name, r.Type, r.Value)
		}
		for _, d := range s.Records {
			if strings.EqualFold(d.Name, r.Name) {
				return fmt.Errorf("retire %s: name is also declared", r.Name)
			}
		}
	}
	return nil
}

// ForPlacements is the spec with the record set following the placement
// registry (containers/PLACEMENT-PLAN.md §5): a route record whose service is
// not placed contributes no name. It moves to Retire, so the live record is
// deleted only while it is exactly the one the spec would have created; any
// other record under that name is a retire-mismatch and blocks Apply. Values
// stay declarative (o002/home), only membership changes. Hand records are
// untouched. The receiver is not modified.
func (s *Spec) ForPlacements(placed func(service string) bool) *Spec {
	out := *s
	out.Records = nil
	out.Retire = append([]Retired(nil), s.Retire...)
	for _, d := range s.Records {
		if d.Service == "" || placed(d.Service) {
			out.Records = append(out.Records, d)
			continue
		}
		out.Retire = append(out.Retire, Retired{Name: d.Name, Type: d.Type, Value: d.Value})
	}
	return &out
}

func norm(v string) string { return strings.TrimSuffix(strings.ToLower(v), ".") }

func fmtVal(v string, ttl int) string { return fmt.Sprintf("%s ttl=%d", v, ttl) }

// Plan compares the spec with a live zone. Pure; no I/O.
func Plan(spec *Spec, z *Zone) []Change { return PlanWith(spec, z, nil) }

// PlanWith is Plan plus the records owned by active expose overrides
// (matched by record id). An owned record whose name the spec doesn't
// declare is reported as Override, even if it's on the retire list. A
// declared name wins over an override (the route became public in
// service.nix): it's planned normally and the override releases it.
func PlanWith(spec *Spec, z *Zone, owned []Owned) []Change {
	ownedBy := map[int64]Owned{}
	for _, o := range owned {
		if o.ID != 0 {
			ownedBy[o.ID] = o
		}
	}
	var out []Change
	external := map[string]bool{}
	for _, n := range spec.External {
		external[strings.ToLower(n)] = true
	}
	byName := map[string][]Record{}
	for _, r := range z.Records {
		byName[strings.ToLower(r.Name)] = append(byName[strings.ToLower(r.Name)], r)
	}
	retire := map[string]Retired{}
	for _, r := range spec.Retire {
		retire[strings.ToLower(r.Name)] = r
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
		c := Change{Name: d.Name, Type: d.Type, New: fmtVal(d.Value, d.TTL), Source: d.Source, Value: d.Value, TTL: d.TTL}
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
		src := ""
		if o, ok := ownedBy[r.ID]; ok && strings.EqualFold(o.Name, r.Name) {
			out = append(out, Change{Action: Override, Name: r.Name, Type: TypeName(r.Type), Old: fmtVal(r.Value, r.TTL), ID: r.ID, Source: "cnt expose " + o.Service})
			continue
		}
		if rt, ok := retire[name]; ok {
			src = "retire list"
			if rt.Type == TypeName(r.Type) && norm(rt.Value) == norm(r.Value) {
				a = Retire
			} else {
				a = RetireMismatch
				src = fmt.Sprintf("retire list wants %s %s", rt.Type, rt.Value)
			}
		}
		out = append(out, Change{Action: a, Name: r.Name, Type: TypeName(r.Type), Old: fmtVal(r.Value, r.TTL), ID: r.ID, Source: src})
	}
	order := map[string]int{Conflict: 0, RetireMismatch: 0, Create: 1, Update: 2, Retire: 3, Keep: 4, Override: 5, External: 6, Unmanaged: 7}
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
	fmt.Fprintf(w, "\n%s: %d create, %d update, %d retire, %d conflict, %d retire-mismatch, %d keep, %d override, %d external, %d unmanaged (never deleted)\n",
		zone, counts[Create], counts[Update], counts[Retire], counts[Conflict], counts[RetireMismatch], counts[Keep], counts[Override], counts[External], counts[Unmanaged])
}

// Client talks to the bunny API. Apply, CreateRecord and DeleteRecord write.
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

func (c *Client) base() string {
	if c.Base == "" {
		return "https://api.bunny.net"
	}
	return c.Base
}

func (c *Client) do(ctx context.Context, method, path string, body any, want int) error {
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base()+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("AccessKey", c.Key)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != want && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bunny %s %s: %s", method, path, resp.Status)
	}
	return nil
}

func typeNumber(name string) (int, error) {
	for n, s := range typeNames {
		if s == name {
			return n, nil
		}
	}
	return 0, fmt.Errorf("unknown record type %s", name)
}

// Op is one write Apply performed (or would perform).
type Op struct {
	Method string
	Path   string
	Change Change
}

// Ops turns a plan into the API calls for its create, update and retire
// rows, in that order. It refuses the whole plan if any row is a conflict
// or retire-mismatch, so nothing is written while a human is needed.
func Ops(zoneID int64, plan []Change) ([]Op, error) {
	var ops []Op
	for _, c := range plan {
		switch c.Action {
		case Conflict, RetireMismatch:
			return nil, fmt.Errorf("refusing to apply: %s %s %s (%s); fix the spec first", c.Action, c.Name, c.Type, c.Old)
		}
	}
	for _, want := range []string{Create, Update, Retire} {
		for _, c := range plan {
			if c.Action != want {
				continue
			}
			switch want {
			case Create:
				ops = append(ops, Op{"PUT", fmt.Sprintf("/dnszone/%d/records", zoneID), c})
			case Update:
				ops = append(ops, Op{"POST", fmt.Sprintf("/dnszone/%d/records/%d", zoneID, c.ID), c})
			case Retire:
				if c.ID == 0 {
					return nil, fmt.Errorf("retire %s: no record id", c.Name)
				}
				ops = append(ops, Op{"DELETE", fmt.Sprintf("/dnszone/%d/records/%d", zoneID, c.ID), c})
			}
		}
	}
	return ops, nil
}

// Apply executes ops in order and stops at the first error. done reports
// each op that succeeded (for the log).
func (c *Client) Apply(ctx context.Context, ops []Op, done func(Op)) error {
	for _, op := range ops {
		var body any
		want := http.StatusNoContent
		if op.Method != http.MethodDelete {
			t, err := typeNumber(op.Change.Type)
			if err != nil {
				return err
			}
			body = map[string]any{"Type": t, "Name": op.Change.Name, "Value": op.Change.Value, "Ttl": op.Change.TTL}
			if op.Method == "POST" {
				body.(map[string]any)["Id"] = op.Change.ID
			}
			if op.Method == "PUT" {
				want = http.StatusCreated
			}
		}
		if err := c.do(ctx, op.Method, op.Path, body, want); err != nil {
			return err
		}
		if done != nil {
			done(op)
		}
	}
	return nil
}

// CreateRecord adds one record and returns its bunny id (expose overrides).
func (c *Client) CreateRecord(ctx context.Context, zoneID int64, name, typ, value string, ttl int) (int64, error) {
	t, err := typeNumber(typ)
	if err != nil {
		return 0, err
	}
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	b, _ := json.Marshal(map[string]any{"Type": t, "Name": name, "Value": value, "Ttl": ttl})
	path := fmt.Sprintf("/dnszone/%d/records", zoneID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, c.base()+path, bytes.NewReader(b))
	if err != nil {
		return 0, err
	}
	req.Header.Set("AccessKey", c.Key)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("bunny PUT %s: %s", path, resp.Status)
	}
	var rec Record
	if err := json.NewDecoder(resp.Body).Decode(&rec); err != nil || rec.ID == 0 {
		return 0, fmt.Errorf("bunny PUT %s: no record id in reply", path)
	}
	return rec.ID, nil
}

// DeleteRecord removes one record by id. A record that is already gone
// counts as deleted.
func (c *Client) DeleteRecord(ctx context.Context, zoneID, id int64) error {
	err := c.do(ctx, http.MethodDelete, fmt.Sprintf("/dnszone/%d/records/%d", zoneID, id), nil, http.StatusNoContent)
	if err != nil && strings.Contains(err.Error(), "404") {
		return nil
	}
	return err
}

// FindRecord returns the live record with id (nil if gone).
func (z *Zone) FindRecord(id int64) *Record {
	for i := range z.Records {
		if z.Records[i].ID == id {
			return &z.Records[i]
		}
	}
	return nil
}

// Lock takes an exclusive flock on path (created if missing) so dns-plan
// --apply and the overrides service never write the zone at the same time.
// The returned func releases it.
func Lock(path string) (func(), error) {
	// Read-only + world-readable: root (dns-plan) and the DynamicUser
	// unit must both be able to open it whoever created it; flock
	// works on a read-only fd.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDONLY, 0o644)
	if err != nil {
		return nil, err
	}
	if st, err := f.Stat(); err == nil && st.Mode().Perm()&0o044 != 0o044 {
		_ = f.Chmod(0o644) // best effort (umask 0077 units)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
