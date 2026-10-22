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

func TestMergeBackupAge(t *testing.T) {
	inv := sampleInventory()
	inv.Services["old"] = inventory.Service{Name: "old", Kind: "nixos", Host: "h001"}
	inv.Services["never"] = inventory.Service{Name: "never", Kind: "nixos", Host: "h001"}
	inv.Services["bad"] = inventory.Service{Name: "bad", Kind: "nixos", Host: "h001"}
	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	polls := map[string]HostPoll{"h001": {Host: "h001", OK: true, Status: &HostStatus{Services: map[string]ServiceStatus{
		"jellyfin": {Active: "active", LastBackup: "2026-10-22T03:05:00-05:00"}, // 08:05Z: 3h55m
		"old":      {Active: "active", LastBackup: "2026-10-20T23:59:00Z"},      // 36h01m: stale
		"never":    {Active: "active"},
		"bad":      {Active: "active", LastBackup: "yesterday"},
	}}}}
	m := MergeAt(inv, polls, now)
	got := map[string]ServiceView{}
	for _, s := range m.Services {
		got[s.Name] = s
	}
	if v := got["jellyfin"]; v.Backup != "ok" || v.BackupAge != "3h" || v.LastBackup == nil || !v.LastBackup.Equal(time.Date(2026, 10, 22, 8, 5, 0, 0, time.UTC)) {
		t.Errorf("jellyfin: %+v", v)
	}
	if v := got["old"]; v.Backup != "stale" || v.BackupAge != "36h" {
		t.Errorf("old: %+v", v)
	}
	if got["never"].Backup != "none" || got["bad"].Backup != "none" {
		t.Errorf("never/bad: %q %q", got["never"].Backup, got["bad"].Backup)
	}
	if got["photos"].Backup != "unknown" { // host does not report it
		t.Errorf("photos: %q", got["photos"].Backup)
	}
	// exactly 36h is not stale yet
	polls["h001"].Status.Services["old"] = ServiceStatus{LastBackup: "2026-10-21T00:00:00Z"}
	if v := MergeAt(inv, polls, now); func() string {
		for _, s := range v.Services {
			if s.Name == "old" {
				return s.Backup
			}
		}
		return ""
	}() != "ok" {
		t.Error("36h exactly flagged stale")
	}
	// unreachable host: unknown
	m = MergeAt(inv, map[string]HostPoll{"h001": {Host: "h001", OK: false}}, now)
	for _, s := range m.Services {
		if s.Backup != "unknown" {
			t.Errorf("%s: %q with the host down", s.Name, s.Backup)
		}
	}
}

func TestFormatAge(t *testing.T) {
	for d, want := range map[time.Duration]string{
		-time.Hour: "<1m", 30 * time.Second: "<1m", 42 * time.Minute: "42m", 5 * time.Hour: "5h",
		47 * time.Hour: "47h", 48 * time.Hour: "2d", 51 * time.Hour: "2d 3h",
	} {
		if got := FormatAge(d); got != want {
			t.Errorf("%v: %q, want %q", d, got, want)
		}
	}
}

func TestBuildStoreSamplesNormalizesLegacyBcachefs(t *testing.T) {
	st := &HostStatus{
		Host: "o002",
		Filesystems: []FilesystemMount{
			{
				Mount:      "/",
				FSType:     "bcachefs",
				UsedBytes:  12_920_000_000,
				TotalBytes: 57_780_000_000,
				Bcachefs: &BcachefsInfo{
					RawTotalBytes:       57_780_000_000,
					RawUsedBytes:        12_920_000_000,
					OnlineReservedBytes: 189_000_000,
					UsableTotalBytes:    57_780_000_000,
					LogicalUsedBytes:    12_920_000_000,
					EffectiveFreeBytes:  44_860_000_000,
					Devices: []BcachefsDevice{
						{Name: "sda3", CapacityBytes: 57_780_000_000, UsedBytes: 12_920_000_000},
					},
				},
			},
		},
	}

	_, fsSamples := buildStoreSamples("o002", time.Unix(1700000000, 0), st)
	if len(fsSamples) != 1 {
		t.Fatalf("expected 1 fsSample, got %d", len(fsSamples))
	}
	if fsSamples[0].RawCapBytes != 57_780_000_000 || fsSamples[0].RawUsedBytes != 12_920_000_000 {
		t.Fatalf("expected normalized RawCapBytes/RawUsedBytes in store sample, got %+v", fsSamples[0])
	}
	bch := st.Filesystems[0].Bcachefs
	if bch.RawCapacityBytes != 57_780_000_000 || bch.UsableUsedBytes != 12_920_000_000 || bch.UsableFreeBytes != 44_860_000_000 || bch.Devices[0].SizeBytes != 57_780_000_000 {
		t.Fatalf("expected normalized BcachefsInfo fields, got %+v", bch)
	}
}

func TestConcurrentCurrentAndSetPoll(t *testing.T) {
	inv := sampleInventory()
	inv.ContainerHosts = []string{"h001"}
	p := NewPoller(inv, "http://127.0.0.1:1/{host}", 100*time.Millisecond)

	baseStatus := &HostStatus{
		Host: "h001",
		Filesystems: []FilesystemMount{
			{
				Mount:      "/data",
				FSType:     "bcachefs",
				UsedBytes:  100,
				TotalBytes: 200,
				Bcachefs: &BcachefsInfo{
					RawTotalBytes:      400,
					RawUsedBytes:       200,
					LogicalUsedBytes:   100,
					EffectiveFreeBytes: 100,
					Devices:            []BcachefsDevice{{Name: "sda", CapacityBytes: 400}},
				},
			},
		},
	}
	p.setPoll("h001", HostPoll{Host: "h001", OK: true, PolledAt: time.Now(), Status: baseStatus}, nil)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 100; i++ {
			st := cloneNormalizedHostStatus(baseStatus)
			p.setPoll("h001", HostPoll{Host: "h001", OK: true, PolledAt: time.Now(), Status: st}, nil)
		}
	}()

	for i := 0; i < 100; i++ {
		m := p.Current()
		if len(m.Hosts) != 1 || m.Hosts[0].Status == nil || len(m.Hosts[0].Status.Filesystems) != 1 {
			t.Fatalf("unexpected merged hosts: %+v", m.Hosts)
		}
		if m.Hosts[0].Status.Filesystems[0].Bcachefs.RawCapacityBytes != 400 {
			t.Fatalf("unexpected RawCapacityBytes: %d", m.Hosts[0].Status.Filesystems[0].Bcachefs.RawCapacityBytes)
		}
	}
	<-done
}
