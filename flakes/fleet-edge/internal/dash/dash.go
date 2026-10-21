// Package dash builds the start-page view: app tiles from inventory http
// routes plus configured extra links, grouped, with resolved icons.
package dash

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

// DefaultIconBase is the default CDN template for named icons; {name} is
// replaced by the icon name.
const DefaultIconBase = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/{name}.svg"

// DefaultGroup holds inventory routes that no extra link claims.
const DefaultGroup = "Fleet services"

// Link is a configured start-page entry that isn't (necessarily) a
// container route. A link whose URL equals a route URL replaces that
// route's tile and inherits its polled state.
type Link struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	Icon        string `json:"icon"`
	Group       string `json:"group"`
	Description string `json:"description"`
}

// LoadLinks reads a JSON array of links. An empty path means no links.
func LoadLinks(path string) ([]Link, error) {
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read links %s: %w", path, err)
	}
	var links []Link
	if err := json.Unmarshal(b, &links); err != nil {
		return nil, fmt.Errorf("parse links %s: %w", path, err)
	}
	for i, l := range links {
		if l.Name == "" || l.URL == "" {
			return nil, fmt.Errorf("links[%d]: name and url are required", i)
		}
	}
	return links, nil
}

// Tile is one app on the start page.
type Tile struct {
	Name        string
	URL         string
	IconURL     string // "" means use Letter
	Letter      string
	Description string
	Service     string // inventory service name, "" for plain links
	Host        string
	Active      string // polled state; "" for plain links
	Exposure    string
}

// Group is a titled section of tiles.
type Group struct {
	Name  string
	Tiles []Tile
}

// ResolveIcon turns an icon spec into an image URL: URLs and absolute
// paths pass through, names go through base ({name} substituted, or
// appended if base has no placeholder). "" yields "" (letter fallback).
func ResolveIcon(icon, base string) string {
	icon = strings.TrimSpace(icon)
	if icon == "" {
		return ""
	}
	if strings.HasPrefix(icon, "http://") || strings.HasPrefix(icon, "https://") || strings.HasPrefix(icon, "/") {
		return icon
	}
	if base == "" {
		base = DefaultIconBase
	}
	if strings.Contains(base, "{name}") {
		return strings.ReplaceAll(base, "{name}", icon)
	}
	return strings.TrimRight(base, "/") + "/" + icon + ".svg"
}

// Letter is the fallback glyph for a tile without an icon.
func Letter(name string) string {
	r, _ := utf8.DecodeRuneInString(strings.TrimSpace(name))
	if r == utf8.RuneError {
		return "?"
	}
	return string(unicode.ToUpper(r))
}

// Build merges inventory http routes with links into ordered groups.
// Link groups come first, in order of first appearance; unclaimed routes
// follow in DefaultGroup, sorted by name.
func Build(m state.Merged, links []Link, iconBase string) []Group {
	type routeInfo struct {
		svc  state.ServiceView
		icon string
		exp  string
		name string
	}
	byURL := map[string]routeInfo{}
	var urls []string
	for _, svc := range m.Services {
		for _, rt := range svc.Routes {
			u := strings.TrimRight(rt.URLStr(), "/")
			if u == "" {
				continue
			}
			if _, dup := byURL[u]; !dup {
				urls = append(urls, u)
			}
			byURL[u] = routeInfo{svc: svc, icon: rt.IconStr(), exp: rt.Exposure, name: rt.NameStr()}
		}
	}

	var order []string
	groups := map[string]*Group{}
	add := func(g string, t Tile) {
		if g == "" {
			g = DefaultGroup
		}
		if groups[g] == nil {
			groups[g] = &Group{Name: g}
			order = append(order, g)
		}
		groups[g].Tiles = append(groups[g].Tiles, t)
	}

	claimed := map[string]bool{}
	for _, l := range links {
		t := Tile{Name: l.Name, URL: l.URL, Description: l.Description, Letter: Letter(l.Name)}
		icon := l.Icon
		if ri, ok := byURL[strings.TrimRight(l.URL, "/")]; ok {
			claimed[strings.TrimRight(l.URL, "/")] = true
			t.Service, t.Host, t.Active, t.Exposure = ri.svc.Name, ri.svc.DeclaredHost, ri.svc.Active, ri.exp
			if icon == "" {
				icon = ri.icon
			}
			if t.Description == "" {
				t.Description = ri.svc.Description
			}
		}
		t.IconURL = ResolveIcon(icon, iconBase)
		add(l.Group, t)
	}

	sort.Slice(urls, func(i, j int) bool { return byURL[urls[i]].name < byURL[urls[j]].name })
	for _, u := range urls {
		if claimed[u] {
			continue
		}
		ri := byURL[u]
		add(DefaultGroup, Tile{
			Name: ri.name, URL: u, Letter: Letter(ri.name),
			IconURL:     ResolveIcon(ri.icon, iconBase),
			Description: ri.svc.Description, Service: ri.svc.Name,
			Host: ri.svc.DeclaredHost, Active: ri.svc.Active, Exposure: ri.exp,
		})
	}

	out := make([]Group, 0, len(order))
	for _, g := range order {
		out = append(out, *groups[g])
	}
	return out
}
