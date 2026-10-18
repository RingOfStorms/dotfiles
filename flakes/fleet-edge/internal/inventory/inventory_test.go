package inventory

import "testing"

const sampleNoRoutes = `{
  "services": {
    "jellyfin": {
      "name": "jellyfin",
      "kind": "nixos",
      "host": "h001",
      "description": "media server",
      "persist": {},
      "tcpPorts": [8096],
      "udpPorts": [],
      "nginx": null
    }
  },
  "hosts": {
    "h001": { "user": "root", "overlayIp": "100.64.0.13", "lanIp": "10.12.14.5" }
  },
  "containerHosts": ["h001"]
}`

const sampleWithRoutes = `{
  "services": {
    "photos": {
      "name": "photos",
      "kind": "nixos",
      "host": "h001",
      "description": "immich",
      "persist": {},
      "tcpPorts": [2283],
      "udpPorts": [],
      "nginx": null,
      "routes": {
        "web": {
          "port": 2283,
          "name": "photos",
          "fqdn": "photos.joshuabell.xyz",
          "url": "https://photos.joshuabell.xyz",
          "proto": "http",
          "exposure": "public",
          "auth": "native",
          "via": ["edge"],
          "health": "/api/server-info/ping"
        }
      }
    }
  },
  "hosts": {
    "h001": { "user": "root", "overlayIp": "100.64.0.13", "lanIp": "10.12.14.5" }
  },
  "containerHosts": ["h001"]
}`

func TestParseNoRoutes(t *testing.T) {
	inv, err := Parse([]byte(sampleNoRoutes))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	svc, ok := inv.Services["jellyfin"]
	if !ok {
		t.Fatal("missing jellyfin service")
	}
	if svc.Routes != nil {
		t.Fatalf("expected nil routes, got %v", svc.Routes)
	}
	if svc.Host != "h001" {
		t.Fatalf("expected host h001, got %q", svc.Host)
	}
	h, ok := inv.Hosts["h001"]
	if !ok {
		t.Fatal("missing h001 host")
	}
	if h.OverlayIP == nil || *h.OverlayIP != "100.64.0.13" {
		t.Fatalf("unexpected overlay ip: %v", h.OverlayIP)
	}
}

func TestParseWithRoutes(t *testing.T) {
	inv, err := Parse([]byte(sampleWithRoutes))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	svc := inv.Services["photos"]
	rt, ok := svc.Routes["web"]
	if !ok {
		t.Fatal("missing web route")
	}
	if rt.Exposure != "public" || rt.AuthStr() != "native" || rt.FQDNStr() != "photos.joshuabell.xyz" || rt.ViaStr() != "edge" {
		t.Fatalf("unexpected route: %+v", rt)
	}
}

const sampleTCPRouteNullFields = `{
  "services": {
    "db": {
      "name": "db",
      "kind": "nixos",
      "host": "h001",
      "description": "immich postgres",
      "persist": {},
      "tcpPorts": [5432],
      "udpPorts": [],
      "nginx": null,
      "routes": {
        "db": {
          "port": 5432,
          "name": null,
          "fqdn": null,
          "url": null,
          "proto": "tcp",
          "exposure": "tailnet",
          "auth": null,
          "via": [],
          "health": null
        }
      }
    }
  },
  "hosts": {
    "h001": { "user": "root", "overlayIp": "100.64.0.13", "lanIp": "10.12.14.5" }
  },
  "containerHosts": ["h001"]
}`

func TestParseTCPRouteWithNullFields(t *testing.T) {
	inv, err := Parse([]byte(sampleTCPRouteNullFields))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	rt, ok := inv.Services["db"].Routes["db"]
	if !ok {
		t.Fatal("missing db route")
	}
	if rt.FQDNStr() != "" || rt.URLStr() != "" || rt.AuthStr() != "" || rt.NameStr() != "" {
		t.Fatalf("expected empty strings for null fields, got %+v", rt)
	}
	if rt.ViaStr() != "" {
		t.Fatalf("expected empty via for non-public route, got %q", rt.ViaStr())
	}
	if rt.Proto != "tcp" || rt.Exposure != "tailnet" {
		t.Fatalf("unexpected proto/exposure: %+v", rt)
	}
}

func TestParseBadJSON(t *testing.T) {
	if _, err := Parse([]byte("not json")); err == nil {
		t.Fatal("expected error for invalid json")
	}
}

func TestParseEmptyServicesAndHosts(t *testing.T) {
	inv, err := Parse([]byte(`{}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if inv.Services == nil || inv.Hosts == nil {
		t.Fatal("expected empty maps, not nil")
	}
}
