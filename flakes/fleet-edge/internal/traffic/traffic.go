// Package traffic models request flow across the fleet topology. Only a
// deterministic simulated provider exists today: the same snapshot and frame
// always produce the same events, so replay animates identically across
// restarts. A real provider is selected by name and answers "unavailable"
// rather than ever falling back to simulation.
package traffic

import (
	"fmt"
	"sort"
	"strconv"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

// Modes accepted by the API.
const (
	ModeSimulated = "simulated"
	ModeReal      = "real"
)

// SimulatedProvider is the identity reported for generated events.
const SimulatedProvider = "simulated-deterministic"

// UnavailableReason is reported instead of inventing traffic when no real
// provider is connected.
const UnavailableReason = "real traffic provider not connected"

// Endpoint is one side of a simulated request. internet/tailnet are symbolic
// (virtual) and never map to a drawn node.
type Endpoint struct {
	ID      string `json:"id"`
	Virtual bool   `json:"virtual,omitempty"`
}

// Event is one simulated request.
type Event struct {
	ID       string   `json:"id"`
	Seq      int      `json:"seq"`
	At       string   `json:"at"`
	Kind     string   `json:"kind"`
	From     Endpoint `json:"from"`
	To       Endpoint `json:"to"`
	Host     string   `json:"host"`
	Service  string   `json:"service"`
	Route    string   `json:"route,omitempty"`
	Audience string   `json:"audience"`
	Proto    string   `json:"proto"`
	Port     int      `json:"port,omitempty"`
	// Status is the HTTP status of a request event; 0 for a non-HTTP route,
	// where an HTTP status would be meaningless.
	Status    int  `json:"status,omitempty"`
	MS        int  `json:"ms"`
	Bytes     int  `json:"bytes"`
	Simulated bool `json:"simulated"`
}

// Window is the interval the events belong to.
type Window struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

// Payload is the `traffic` object of the frame/traffic responses.
type Payload struct {
	Mode      string  `json:"mode"`
	Available bool    `json:"available"`
	Simulated bool    `json:"simulated"`
	Provider  string  `json:"provider,omitempty"`
	Message   string  `json:"message,omitempty"`
	Reason    string  `json:"reason,omitempty"`
	Epoch     string  `json:"epoch,omitempty"`
	Window    *Window `json:"window,omitempty"`
	Events    []Event `json:"events"`
}

// Snapshot is the recorded state a payload is generated from: its identity
// plus the merged topology at that instant.
type Snapshot struct {
	TS int64
	M  state.Merged
}

// Frame is the request being answered: bucket is the snapshot's 30 s window
// start and At is the instant the viewer asked for. Full asks for events over
// the whole window instead of the prefix up to At, so a replay can queue a
// little ahead of its cursor instead of stalling at a bucket edge; Limit caps
// such a window at the present instant, since nothing may be reported for a
// time that has not happened yet.
type Frame struct {
	Bucket time.Time
	At     time.Time
	Step   time.Duration
	Full   bool
	Limit  time.Time
}

// cut is the last instant this frame may report an event for.
func (f Frame) cut() time.Time {
	end := f.Bucket.Add(f.Step)
	if !f.Full {
		return f.At
	}
	if !f.Limit.IsZero() && end.After(f.Limit) {
		return f.Limit
	}
	return end
}

// Provider produces the traffic payload of one frame. Providers are swappable
// at startup; none of them may invent health, only requests on declared routes.
type Provider interface {
	// Mode is the API mode string this provider answers for.
	Mode() string
	// Payload returns the events of snap for frame.
	Payload(snap Snapshot, frame Frame) Payload
}

// Registry maps API mode strings to providers. The server builds one at
// construction, so a real provider is plugged in by handing over a registry
// entry — no endpoint, payload or frontend change.
type Registry map[string]Provider

// DefaultRegistry is what the server uses when no registry is configured: the
// deterministic simulation and the honestly-unavailable real mode.
func DefaultRegistry(routerHub string) Registry {
	return Registry{
		ModeSimulated: Simulated{RouterHub: routerHub},
		ModeReal:      Unavailable{},
	}
}

// Provider returns the provider registered for mode.
func (r Registry) Provider(mode string) (Provider, bool) {
	p, ok := r[mode]
	return p, ok
}

// Modes lists the registered modes, sorted, for configuration checks and
// diagnostics.
func (r Registry) Modes() []string {
	out := make([]string, 0, len(r))
	for mode := range r {
		out = append(out, mode)
	}
	sort.Strings(out)
	return out
}

// Unavailable answers for a traffic source that is not connected. It exists so
// the real-traffic option is explicit and never silently degrades to made-up
// events; it is a complete answer, not a stub awaiting an implementation.
type Unavailable struct{}

// Mode implements Provider.
func (Unavailable) Mode() string { return ModeReal }

// Payload implements Provider.
func (Unavailable) Payload(Snapshot, Frame) Payload {
	return Payload{
		Mode:      ModeReal,
		Available: false,
		Simulated: false,
		Reason:    UnavailableReason,
		Message:   "No measured traffic source is connected; enable a real provider to see actual requests.",
		Events:    []Event{},
	}
}

// Simulated generates deterministic placeholder requests. RouterHub names the
// topology node that terminates router port-forwards; empty means a route that
// only enters via the router is not treated as internet-facing.
type Simulated struct {
	RouterHub string
}

// Mode implements Provider.
func (Simulated) Mode() string { return ModeSimulated }

// Payload implements Provider.
func (p Simulated) Payload(snap Snapshot, frame Frame) Payload {
	if frame.Step <= 0 {
		frame.Step = 30 * time.Second
	}
	bucket := frame.Bucket
	// The advertised window ends where the events end: a full-window request
	// clipped at the present instant must not claim to cover the future.
	end := bucket.Add(frame.Step)
	if frame.Full && !frame.Limit.IsZero() && end.After(frame.Limit) {
		end = frame.Limit.UTC().Truncate(time.Second)
	}
	out := Payload{
		Mode:      ModeSimulated,
		Available: true,
		Simulated: true,
		Provider:  SimulatedProvider,
		Message:   "Simulated traffic — not measured",
		Epoch:     "sim:" + bucket.UTC().Format(time.RFC3339),
		Window:    &Window{Start: bucket.UTC().Format(time.RFC3339), End: end.UTC().Format(time.RFC3339)},
		Events:    []Event{},
	}
	cut := frame.cut()
	for _, route := range routes(snap.M, p.RouterHub != "") {
		seed := hash(snap.TS, route.service, route.key)
		count := 1 + int(seed%2)
		for i := range count {
			offset := mix(seed+uint64(i)*0x9e3779b97f4a7c15) % uint64(frame.Step/time.Second)
			at := bucket.Add(time.Duration(offset) * time.Second)
			if at.After(cut) {
				continue
			}
			out.Events = append(out.Events, event(snap.TS, route, seed, i, at))
		}
	}
	sort.Slice(out.Events, func(i, j int) bool {
		if out.Events[i].At != out.Events[j].At {
			return out.Events[i].At < out.Events[j].At
		}
		return out.Events[i].ID < out.Events[j].ID
	})
	for i := range out.Events {
		out.Events[i].Seq = i
	}
	return out
}

type routeRef struct {
	service  string
	key      string // stable route identity: name, else fqdn/url, else port
	route    string // display name of this route within the service
	host     string
	proto    string
	port     int
	audience string
}

// routes lists the declared routes of hosts that were online in the snapshot,
// sorted so generation order never depends on map iteration. local/lan routes
// are skipped: they are not reachable from the internet or the tailnet, so
// animating them would be a fabrication. A public route is only internet-facing
// when the edge (or a configured router hub) actually carries it.
func routes(m state.Merged, routerPublic bool) []routeRef {
	online := make(map[string]bool, len(m.Hosts))
	for _, h := range m.Hosts {
		if h.StateBadge == "online" {
			online[h.Host] = true
		}
	}
	var out []routeRef
	for _, svc := range m.Services {
		if !online[svc.DeclaredHost] {
			continue
		}
		for i, r := range svc.Routes {
			audience, ok := audience(r, routerPublic)
			if !ok {
				continue
			}
			proto := r.Proto
			if proto == "" {
				proto = "https"
			}
			key := routeKey(r, i)
			name := r.NameStr()
			if name == "" {
				name = key
			}
			out = append(out, routeRef{
				service:  svc.Name,
				key:      key,
				route:    name,
				host:     svc.DeclaredHost,
				proto:    proto,
				port:     r.Port,
				audience: audience,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].service != out[j].service {
			return out[i].service < out[j].service
		}
		return out[i].key < out[j].key
	})
	return out
}

// audience decides the plane a route's traffic comes from. ok=false removes
// the route from simulation entirely.
func audience(r inventory.Route, routerPublic bool) (string, bool) {
	switch r.Exposure {
	case "public":
		switch {
		case contains(r.Via, "edge"):
			return "public", true
		case routerPublic && contains(r.Via, "router"):
			return "public", true
		}
		// Publicly declared but nothing carries it: not reachable yet.
		return "", false
	case "tailnet":
		return "tailnet", true
	default: // "", "local", "lan"
		return "", false
	}
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// routeKey is the route's stable identity within its service. It names a route
// for seeding; it is never dialled, so it is not an address.
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

func event(snapshotTS int64, r routeRef, seed uint64, idx int, at time.Time) Event {
	h := mix(seed + uint64(idx+1)*0x2545f4914f6cdd1d)
	from := Endpoint{ID: "internet", Virtual: true}
	if r.audience != "public" {
		from.ID = "tailnet"
	}
	ev := Event{
		ID:        fmt.Sprintf("sim-%d-%08x-%d", snapshotTS, uint32(seed), idx),
		At:        at.UTC().Format(time.RFC3339),
		Kind:      "request",
		From:      from,
		To:        Endpoint{ID: r.host},
		Host:      r.host,
		Service:   r.service,
		Route:     r.route,
		Audience:  r.audience,
		Proto:     r.proto,
		Port:      r.port,
		MS:        int(4 + (h>>8)%220),
		Bytes:     int(512 + (h>>16)%500000),
		Simulated: true,
	}
	// A status only means something for HTTP; a TCP/UDP route reports the
	// request without inventing an HTTP result.
	if r.proto == "http" || r.proto == "https" {
		statuses := [...]int{200, 200, 200, 200, 204, 304, 404, 500}
		ev.Status = statuses[h%uint64(len(statuses))]
	}
	return ev
}

// hash folds the capture timestamp, service and route identity into a seed, so
// a route keeps its character while every snapshot reseeds the stream.
func hash(snapshotTS int64, service, route string) uint64 {
	const (
		offset64 = 14695981039346656037
		prime64  = 1099511628211
	)
	h := uint64(offset64)
	script := func(s string) {
		for i := range s {
			h ^= uint64(s[i])
			h *= prime64
		}
		h ^= 0xff
		h *= prime64
	}
	h ^= mix(uint64(snapshotTS))
	h *= prime64
	script(service)
	script(route)
	return mix(h)
}

// mix is splitmix64's finalizer: cheap, well-distributed, and independent of
// any library RNG whose sequence might change.
func mix(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}
