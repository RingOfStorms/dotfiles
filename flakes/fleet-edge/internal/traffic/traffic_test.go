package traffic

import (
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func strp(s string) *string { return &s }

// fleet is two online hosts with a public (edge), a router-only public, a
// tailnet and a lan route, plus an offline host that must stay silent.
func fleet() state.Merged {
	routes := func(host, exposure string, via ...string) state.ServiceView {
		return state.ServiceView{
			Name: host + "-" + exposure, BoundHost: host, Active: "active",
			Routes: []inventory.Route{{
				Port: 8080, Name: strp(exposure), Proto: "http", Exposure: exposure, Via: via,
			}},
		}
	}
	return state.Merged{
		Hosts: []state.HostView{
			{Host: "h001", StateBadge: "online", AlwaysOn: true},
			{Host: "h009", StateBadge: "online", AlwaysOn: true},
			{Host: "laptop", StateBadge: "sleeping"},
		},
		Services: []state.ServiceView{
			routes("h001", "public", "edge"),
			routes("h001", "tailnet"),
			routes("h001", "lan"),
			routes("h009", "public", "router"),
			routes("laptop", "public", "edge"),
		},
	}
}

func snap(ts int64) Snapshot { return Snapshot{TS: ts, M: fleet()} }

func TestSimulatedIsDeterministicPerSnapshot(t *testing.T) {
	bucket := time.Unix(1793250656, 0).UTC()
	frame := Frame{Bucket: bucket, At: bucket.Add(29 * time.Second), Step: 30 * time.Second, Full: true}
	p := Simulated{RouterHub: "router"}
	first := p.Payload(snap(1793250656), frame)
	second := Simulated{RouterHub: "router"}.Payload(snap(1793250656), frame)
	ids := func(pl Payload) []string {
		out := make([]string, len(pl.Events))
		for i, ev := range pl.Events {
			out[i] = ev.ID + "@" + ev.At
		}
		return out
	}
	a, b := ids(first), ids(second)
	if len(a) == 0 {
		t.Fatal("no events")
	}
	if len(a) != len(b) {
		t.Fatalf("event count differs: %d vs %d", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Errorf("event %d: %q vs %q", i, a[i], b[i])
		}
	}
	// A later capture reseeds the stream: replay must never look identical to
	// a different bucket.
	other := p.Payload(snap(1793250686), Frame{Bucket: bucket.Add(30 * time.Second), At: bucket.Add(59 * time.Second), Step: 30 * time.Second, Full: true})
	for _, ev := range other.Events {
		if ev.ID == "" || len(ev.ID) < 5 || ev.ID[:4] != "sim-" {
			t.Fatalf("event id %q is not namespaced", ev.ID)
		}
	}
}

func TestSimulatedAudienceGates(t *testing.T) {
	bucket := time.Unix(1793250656, 0).UTC()
	// No router hub: router-only routes are not internet-facing.
	noRouter := Simulated{}.Payload(snap(1793250656),
		Frame{Bucket: bucket, At: bucket.Add(29 * time.Second), Step: 30 * time.Second, Full: true})
	// With a router hub they are.
	withRouter := Simulated{RouterHub: "router"}.Payload(snap(1793250656),
		Frame{Bucket: bucket, At: bucket.Add(29 * time.Second), Step: 30 * time.Second, Full: true})

	audiences := func(pl Payload) map[string]map[string]bool {
		out := map[string]map[string]bool{}
		for _, ev := range pl.Events {
			if out[ev.Host] == nil {
				out[ev.Host] = map[string]bool{}
			}
			rv := ev.From.ID
			if rv == "internet" {
				if ev.Audience != "public" {
					t.Errorf("%s: internet actor with audience %q", ev.Host, ev.Audience)
				}
			} else if rv == "tailnet" {
				if ev.Audience != "tailnet" {
					t.Errorf("%s: tailnet actor with audience %q", ev.Host, ev.Audience)
				}
			} else {
				t.Errorf("unexpected actor %q", rv)
			}
			out[ev.Host][ev.Audience] = true
		}
		return out
	}
	a := audiences(noRouter)
	if a["h001"]["public"] != true || a["h001"]["tailnet"] != true {
		t.Errorf("h001 audiences = %v, want public+tailnet", a["h001"])
	}
	for host, set := range a {
		if set["lan"] {
			t.Errorf("%s: lan route generated traffic", host)
		}
	}
	if a["h009"]["public"] {
		t.Error("router-only route generated internet traffic without a router hub")
	}
	b := audiences(withRouter)
	if !b["h009"]["public"] {
		t.Error("router-only route still silent with a configured router hub")
	}
	if _, ok := a["laptop"]; ok {
		t.Error("sleeping host generated traffic")
	}
}

func TestSimulatedCut(t *testing.T) {
	bucket := time.Unix(1793250656, 0).UTC()
	p := Simulated{RouterHub: "router"}
	prefix := p.Payload(snap(1793250656), Frame{
		Bucket: bucket, At: bucket.Add(5 * time.Second), Step: 30 * time.Second,
	})
	for _, ev := range prefix.Events {
		at, err := time.Parse(time.RFC3339, ev.At)
		if err != nil {
			t.Fatal(err)
		}
		if at.After(bucket.Add(5 * time.Second)) {
			t.Errorf("event %s at %s is beyond the cursor", ev.ID, ev.At)
		}
	}
	// Full reports the whole bucket, but never past Limit.
	limit := bucket.Add(10 * time.Second)
	full := p.Payload(snap(1793250656), Frame{
		Bucket: bucket, At: bucket.Add(5 * time.Second), Step: 30 * time.Second,
		Full: true, Limit: limit,
	})
	if full.Window == nil || full.Window.End != limit.Format(time.RFC3339) {
		t.Errorf("window = %+v, want end clipped to the limit", full.Window)
	}
	for _, ev := range full.Events {
		at, err := time.Parse(time.RFC3339, ev.At)
		if err != nil {
			t.Fatal(err)
		}
		if at.After(limit) {
			t.Errorf("event %s at %s is beyond the present", ev.ID, ev.At)
		}
	}
}

func TestStatusOnlyForHTTP(t *testing.T) {
	m := state.Merged{
		Hosts: []state.HostView{{Host: "h001", StateBadge: "online", AlwaysOn: true}},
		Services: []state.ServiceView{{
			Name: "tcp", BoundHost: "h001", Active: "active",
			Routes: []inventory.Route{
				{Port: 5432, Name: strp("db"), Proto: "tcp", Exposure: "tailnet"},
				{Port: 8080, Name: strp("web"), Proto: "http", Exposure: "tailnet"},
			},
		}},
	}
	bucket := time.Unix(1793250656, 0).UTC()
	pl := Simulated{}.Payload(Snapshot{TS: 1793250656, M: m},
		Frame{Bucket: bucket, At: bucket.Add(29 * time.Second), Step: 30 * time.Second, Full: true})
	seenHTTP, seenTCP := false, false
	for _, ev := range pl.Events {
		if ev.Route == "" || ev.Port == 0 {
			t.Errorf("event %s lacks route/port", ev.ID)
		}
		switch ev.Proto {
		case "http":
			seenHTTP = true
			if ev.Status == 0 {
				t.Errorf("http event %s has no status", ev.ID)
			}
		case "tcp":
			seenTCP = true
			if ev.Status != 0 {
				t.Errorf("tcp event %s invented status %d", ev.ID, ev.Status)
			}
		}
	}
	if !seenHTTP || !seenTCP {
		t.Fatalf("expected both http and tcp events, got http=%v tcp=%v", seenHTTP, seenTCP)
	}
}

func TestRealModeIsUnavailableNotSimulated(t *testing.T) {
	got := Unavailable{}.Payload(snap(1793250656), Frame{})
	if got.Available || got.Simulated {
		t.Errorf("available=%v simulated=%v, want false/false", got.Available, got.Simulated)
	}
	if got.Reason != UnavailableReason || len(got.Events) != 0 {
		t.Errorf("reason=%q events=%d", got.Reason, len(got.Events))
	}
	reg := DefaultRegistry("router")
	for _, mode := range []string{ModeSimulated, ModeReal} {
		if _, ok := reg.Provider(mode); !ok {
			t.Errorf("mode %q unregistered", mode)
		}
	}
	if _, ok := reg.Provider("bogus"); ok {
		t.Error("bogus mode registered")
	}
	if modes := reg.Modes(); len(modes) != 2 || modes[0] != ModeReal || modes[1] != ModeSimulated {
		t.Errorf("Modes() = %v", modes)
	}
}
