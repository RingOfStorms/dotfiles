package inventory

import (
	"os"
	"testing"
)

// TestParseRealFixture guards against the real inventory's shape drifting
// from what this package expects, e.g. `routes.<r>.via` being a list of
// strings (not a single string) and several route fields (name, fqdn,
// url, auth, health) being nullable. The fixture is a trimmed copy of
// `nix eval --json path:./containers#inventory` (sec + zitadel + h001),
// taken 2026-10-17; see flakes/fleet-edge/internal/inventory/testdata.
func TestParseRealFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/real-fixture.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	inv, err := Parse(b)
	if err != nil {
		t.Fatalf("parse real fixture: %v", err)
	}

	sec, ok := inv.Services["sec"]
	if !ok {
		t.Fatal("missing sec service")
	}
	secRoute, ok := sec.Routes["web"]
	if !ok {
		t.Fatal("missing sec web route")
	}
	if secRoute.FQDNStr() != "secrets.joshuabell.xyz" {
		t.Fatalf("unexpected sec fqdn: %q", secRoute.FQDNStr())
	}
	if secRoute.AuthStr() != "native-oidc" {
		t.Fatalf("unexpected sec auth: %q", secRoute.AuthStr())
	}
	if secRoute.ViaStr() != "edge" {
		t.Fatalf("unexpected sec via: %q", secRoute.ViaStr())
	}
	if secRoute.Exposure != "public" {
		t.Fatalf("unexpected sec exposure: %q", secRoute.Exposure)
	}

	zitadel, ok := inv.Services["zitadel"]
	if !ok {
		t.Fatal("missing zitadel service")
	}
	ziRoute, ok := zitadel.Routes["web"]
	if !ok {
		t.Fatal("missing zitadel web route")
	}
	if ziRoute.FQDNStr() != "sso.joshuabell.xyz" {
		t.Fatalf("unexpected zitadel fqdn: %q", ziRoute.FQDNStr())
	}
	if ziRoute.AuthStr() != "native" {
		t.Fatalf("unexpected zitadel auth: %q", ziRoute.AuthStr())
	}

	h001, ok := inv.Hosts["h001"]
	if !ok {
		t.Fatal("missing h001 host")
	}
	if h001.OverlayIP == nil || *h001.OverlayIP != "100.64.0.13" {
		t.Fatalf("unexpected h001 overlay ip: %v", h001.OverlayIP)
	}
}
