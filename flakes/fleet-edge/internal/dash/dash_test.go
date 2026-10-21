package dash

import (
	"os"
	"path/filepath"
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func strp(s string) *string { return &s }

func TestResolveIcon(t *testing.T) {
	cases := []struct{ icon, base, want string }{
		{"", "", ""},
		{"jellyfin", "", "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/jellyfin.svg"},
		{"https://x/y.png", "", "https://x/y.png"},
		{"/assets/a.svg", "", "/assets/a.svg"},
		{"git", "https://icons.example/{name}.png", "https://icons.example/git.png"},
		{"git", "https://icons.example/svg/", "https://icons.example/svg/git.svg"},
	}
	for _, c := range cases {
		if got := ResolveIcon(c.icon, c.base); got != c.want {
			t.Errorf("ResolveIcon(%q,%q) = %q, want %q", c.icon, c.base, got, c.want)
		}
	}
}

func TestLetter(t *testing.T) {
	if Letter("jellyfin") != "J" || Letter("") != "?" || Letter(" ärr") != "Ä" {
		t.Fatal("unexpected letter")
	}
}

func TestBuildMergesLinksAndRoutes(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"forgejo": {Name: "forgejo", Host: "h001", Description: "git", Routes: map[string]inventory.Route{
				"web": {Name: strp("git"), URL: strp("https://git.example"), Exposure: "public"},
				"ssh": {Port: 22, Proto: "tcp"},
			}},
			"atuin": {Name: "atuin", Host: "h001", Routes: map[string]inventory.Route{
				"web": {Name: strp("atuin"), URL: strp("https://atuin.example"), Icon: strp("atuin")},
			}},
		},
		Hosts: map[string]inventory.Host{"h001": {}},
	}
	m := state.Merge(inv, nil)
	links := []Link{
		{Name: "Git", URL: "https://git.example/", Icon: "forgejo", Group: "Apps"},
		{Name: "Radarr", URL: "http://h001:7878", Group: "Media"},
	}
	gs := Build(m, links, "")
	if len(gs) != 3 || gs[0].Name != "Apps" || gs[1].Name != "Media" || gs[2].Name != DefaultGroup {
		t.Fatalf("groups = %+v", gs)
	}
	git := gs[0].Tiles[0]
	if git.Service != "forgejo" || git.Active != "unknown" || git.Description != "git" ||
		git.IconURL != "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/forgejo.svg" {
		t.Fatalf("git tile = %+v", git)
	}
	if r := gs[1].Tiles[0]; r.IconURL != "" || r.Letter != "R" || r.Service != "" {
		t.Fatalf("radarr tile = %+v", r)
	}
	if len(gs[2].Tiles) != 1 || gs[2].Tiles[0].Name != "atuin" || gs[2].Tiles[0].IconURL == "" {
		t.Fatalf("default group = %+v", gs[2])
	}
}

func TestLoadLinks(t *testing.T) {
	if l, err := LoadLinks(""); err != nil || l != nil {
		t.Fatal("empty path should be no links")
	}
	p := filepath.Join(t.TempDir(), "l.json")
	os.WriteFile(p, []byte(`[{"name":"A","url":"http://a","group":"G"}]`), 0o600)
	l, err := LoadLinks(p)
	if err != nil || len(l) != 1 || l[0].Group != "G" {
		t.Fatalf("LoadLinks = %+v, %v", l, err)
	}
	os.WriteFile(p, []byte(`[{"name":"A"}]`), 0o600)
	if _, err := LoadLinks(p); err == nil {
		t.Fatal("expected error for missing url")
	}
}

func TestHostInference(t *testing.T) {
	inv := &inventory.Inventory{
		Services: map[string]inventory.Service{
			"immich": {Name: "immich", Host: "h001", Routes: map[string]inventory.Route{
				"web": {Name: strp("photos"), URL: strp("https://photos.example.com")},
			}},
			"localai": {Name: "localai", Host: "joe", Routes: map[string]inventory.Route{
				"web": {Name: strp("localai"), URL: strp("https://localai.ts.example.com/api")},
			}},
		},
		Hosts: map[string]inventory.Host{
			"h001": {OverlayIP: strp("100.64.0.1"), LanIP: strp("10.12.14.10")},
			"h005": {OverlayIP: strp("100.64.0.5"), LanIP: strp("10.12.14.1")},
			"joe":  {},
		},
	}
	m := state.Merge(inv, nil)
	ix := NewHostIndex(m)
	cases := map[string]string{
		"http://h001.net.example.com:7878":     "h001",
		"http://H001.NET.joshuabell.xyz/":      "h001",
		"http://h005.local:3000":               "h005",
		"http://10.12.14.1:3000":               "h005",
		"http://100.64.0.1:8090/x":             "h001",
		"https://localai.ts.example.com":       "joe",
		"https://photos.example.com/share/abc": "h001",
		"http://h001:7878":                     "h001",
		"https://git.example.com":              "",
		"http://h999.net.example.com":          "",
		"http://net.example.com":               "",
		"http://h001.net.":                     "",
		"http://h001.lan":                      "",
		"not a url":                            "",
		"":                                     "",
	}
	for u, want := range cases {
		if got := ix.Infer(u); got != want {
			t.Errorf("Infer(%q) = %q, want %q", u, got, want)
		}
	}

	links := []Link{
		{Name: "Radarr", URL: "http://h001.net.example.com:7878", Group: "Media"},
		{Name: "Photos", URL: "https://photos.example.com/", Group: "Docs"},
		{Name: "Elsewhere", URL: "https://example.org", Group: "Docs"},
	}
	gs := Build(m, links, "")
	if len(gs) != 3 || gs[0].Tiles[0].Host != "h001" || gs[1].Tiles[0].Host != "h001" || gs[1].Tiles[1].Host != "" {
		t.Fatalf("groups = %+v", gs)
	}
	for _, tl := range gs[2].Tiles {
		if tl.Host == "" {
			t.Fatalf("inventory tile without host: %+v", tl)
		}
	}
}
