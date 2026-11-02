package reconcile

import (
	"context"
	"errors"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/overrides"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
	"strings"
	"testing"
	"time"
)

func TestTailnetLANOverrideFollowsPlacementAndExpiry(t *testing.T) {
	rg := newRig(t)
	rg.place("arr", "h001", placements.Committed)
	until := time.Now().Add(time.Hour).Unix()
	failed := false
	rg.r.cfg.Status = func(ctx context.Context, h string) ([]overrides.HostOverride, error) {
		if failed {
			return nil, errors.New("offline")
		}
		return []overrides.HostOverride{{Service: "arr", Route: "sonarr", Exposure: "lan", Until: until}}, nil
	}
	rg.pass()
	if got := rg.file(rg.lan, "sonarr.example.com"); !strings.Contains(got, "10.12.14.10") {
		t.Fatal(got)
	}
	rg.exp.Host["arr"] = "h003"
	rg.pass()
	if got := rg.file(rg.lan, "sonarr.example.com"); !strings.Contains(got, "10.12.14.30") {
		t.Fatal(got)
	}
	failed = true
	rg.pass()
	if rg.file(rg.lan, "sonarr.example.com") == "" {
		t.Fatal("lost answer during status failure")
	}
	failed = false
	until = 1
	rg.pass()
	if got := rg.file(rg.lan, "sonarr.example.com"); got != "" {
		t.Fatalf("expired override kept: %s", got)
	}
	if rg.file(rg.tail, "sonarr.example.com") == "" {
		t.Fatal("tailnet answer lost")
	}
}
