package state

import (
	"context"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

func strp(s string) *string { return &s }

func sampleInventory() *inventory.Inventory {
	return &inventory.Inventory{
		Services: map[string]inventory.Service{
			"jellyfin": {
				Name: "jellyfin", Kind: "nixos", Host: "h001",
				Description: "media server",
			},
			"photos": {
				Name: "photos", Kind: "nixos", Host: "h001",
				Description: "immich",
				Routes: map[string]inventory.Route{
					"web": {Port: 2283, FQDN: strp("photos.joshuabell.xyz"), Exposure: "public", Auth: strp("native"), Via: []string{"edge"}},
				},
			},
		},
		Hosts: map[string]inventory.Host{
			"h001": {User: "root", OverlayIP: strp("100.64.0.13"), LanIP: strp("10.12.14.5")},
		},
	}
}

func TestMergeWithGoodPoll(t *testing.T) {
	inv := sampleInventory()
	polls := map[string]HostPoll{
		"h001": {
			Host: "h001", OK: true, PolledAt: time.Now(),
			Status: &HostStatus{
				Host: "h001",
				Services: map[string]ServiceStatus{
					"jellyfin": {Unit: "container@jellyfin", Active: "active", Enabled: true},
				},
			},
		},
	}
	m := Merge(inv, polls)
	if len(m.Services) != 2 {
		t.Fatalf("expected 2 services, got %d", len(m.Services))
	}
	var jf, photos *ServiceView
	for i := range m.Services {
		switch m.Services[i].Name {
		case "jellyfin":
			jf = &m.Services[i]
		case "photos":
			photos = &m.Services[i]
		}
	}
	if jf == nil || jf.Active != "active" || jf.Enabled == nil || !*jf.Enabled {
		t.Fatalf("unexpected jellyfin view: %+v", jf)
	}
	if photos == nil || photos.Active != "unknown" {
		t.Fatalf("expected unknown active for photos (no status entry), got %+v", photos)
	}
	if len(photos.Routes) != 1 || photos.Routes[0].FQDNStr() != "photos.joshuabell.xyz" {
		t.Fatalf("unexpected photos routes: %+v", photos.Routes)
	}
	if len(m.Hosts) != 1 || !m.Hosts[0].Reachable {
		t.Fatalf("unexpected hosts view: %+v", m.Hosts)
	}
}

func TestMergeUnreachableHost(t *testing.T) {
	inv := sampleInventory()
	polls := map[string]HostPoll{
		"h001": {Host: "h001", OK: false, Error: "context deadline exceeded", PolledAt: time.Now()},
	}
	m := Merge(inv, polls)
	for _, sv := range m.Services {
		if sv.Active != "unknown" {
			t.Fatalf("expected unknown active when host unreachable, got %+v", sv)
		}
	}
	if m.Hosts[0].Reachable {
		t.Fatal("expected unreachable host")
	}
	if m.Hosts[0].Error == "" {
		t.Fatal("expected error recorded")
	}
}

func TestMergeNoPollYet(t *testing.T) {
	inv := sampleInventory()
	m := Merge(inv, map[string]HostPoll{})
	if len(m.Services) != 2 {
		t.Fatalf("expected 2 services, got %d", len(m.Services))
	}
	for _, sv := range m.Services {
		if sv.Active != "unknown" {
			t.Fatalf("expected unknown with no poll data, got %+v", sv)
		}
	}
	if m.Hosts[0].Reachable {
		t.Fatal("expected not-reachable default when never polled")
	}
}

func TestHostURLSubstitution(t *testing.T) {
	h := inventory.Host{OverlayIP: strp("100.64.0.13"), LanIP: strp("10.12.14.5")}
	got := hostURL("http://{overlayIp}:9101/status.json", "h001", h)
	want := "http://100.64.0.13:9101/status.json"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestPolledHostsContainerHosts(t *testing.T) {
	inv := sampleInventory()
	inv.Hosts["gp3"] = inventory.Host{OverlayIP: strp("100.64.0.15")}
	inv.Hosts["h003"] = inventory.Host{OverlayIP: strp("100.64.0.4")}
	inv.ContainerHosts = []string{"h003", "h001", "missing"}
	got := inv.PolledHosts()
	if len(got) != 2 || got[0] != "h001" || got[1] != "h003" {
		t.Fatalf("got %v", got)
	}
}

func TestPolledHostsFallbackToServiceHosts(t *testing.T) {
	inv := sampleInventory()
	inv.Hosts["gp3"] = inventory.Host{OverlayIP: strp("100.64.0.15")}
	got := inv.PolledHosts()
	if len(got) != 1 || got[0] != "h001" {
		t.Fatalf("got %v", got)
	}
}

func TestMergeNoEndpointHost(t *testing.T) {
	inv := sampleInventory()
	inv.Hosts["gp3"] = inventory.Host{OverlayIP: strp("100.64.0.15")}
	inv.ContainerHosts = []string{"h001"}
	// A stale poll for a non-endpoint host must be ignored.
	polls := map[string]HostPoll{
		"h001": {Host: "h001", OK: true, PolledAt: time.Now()},
		"gp3":  {Host: "gp3", OK: false, Error: "refused", PolledAt: time.Now()},
	}
	m := Merge(inv, polls)
	for _, h := range m.Hosts {
		switch h.Host {
		case "h001":
			if !h.HasEndpoint || !h.Reachable {
				t.Fatalf("h001: %+v", h)
			}
		case "gp3":
			if h.HasEndpoint || h.Reachable || h.Error != "" || !h.PolledAt.IsZero() {
				t.Fatalf("gp3: %+v", h)
			}
		}
	}
}

func TestPollOnceOnlyPolledHosts(t *testing.T) {
	inv := sampleInventory()
	inv.Hosts["gp3"] = inventory.Host{OverlayIP: strp("100.64.0.15")}
	inv.ContainerHosts = []string{"h001"}
	p := NewPoller(inv, "http://127.0.0.1:1/{host}", 200*time.Millisecond)
	p.PollOnce(context.Background())
	if _, ok := p.polls["gp3"]; ok {
		t.Fatal("gp3 must not be polled")
	}
	if _, ok := p.polls["h001"]; !ok {
		t.Fatal("h001 must be polled")
	}
}
