package containers

// Routes (ROUTING-PLAN.md §2, step 1 of §8): the host vhost and firewall
// ports generated from service.nix `routes`, `cnt routes` and `cnt audit`.
//
// lib.nix normalizes and validates routes (defaults filled in, bad combos
// throw), so the CLI trusts the inventory. validateRoutes mirrors the checks
// that would make the generated config unsafe, as a second line in case the
// inventory comes from an older lib.nix.

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

type Route struct {
	Port              int      `json:"port"`
	Proto             string   `json:"proto"`
	Exposure          string   `json:"exposure"`
	Auth              *string  `json:"auth"`
	Via               []string `json:"via"`
	Allow             []string `json:"allow"`
	Health            *string  `json:"health"`
	Icon              *string  `json:"icon"`  // informational (fleet-edge start page)
	Group             *string  `json:"group"` // informational (fleet-edge start-page category)
	PublicWithoutAuth bool     `json:"publicWithoutAuth"`
	// http only (null for tcp/udp)
	Name       *string `json:"name"`
	FQDN       *string `json:"fqdn"`
	URL        *string `json:"url"`
	Websockets bool    `json:"websockets"`
	MaxBody    string  `json:"maxBody"`
	Buffering  bool    `json:"buffering"`
	Timeouts   string  `json:"timeouts"`
	// nil (older lib.nix) or true: nginx default; false: stream request bodies.
	RequestBuffering *bool  `json:"requestBuffering"`
	ForwardedProto   string `json:"forwardedProto"`
	ExtraConfig      string `json:"extraConfig"`
	// auth = oauth2-proxy only: zitadel roles (any of), unauthenticated path prefixes.
	Groups []string `json:"groups"`
	Bypass []string `json:"bypass"`
	// Set by routesVhost from the service (not in the inventory): the
	// backend address nginx proxies to. "" means 127.0.0.1.
	backend string
}

func sortedRouteNames(s Service) []string {
	names := make([]string, 0, len(s.Routes))
	for n := range s.Routes {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// validateRoutes mirrors the lib.nix safety checks.
func validateRoutes(s Service) error {
	if len(s.Routes) > 0 && s.Nginx != nil && strings.TrimSpace(*s.Nginx) != "" {
		return fmt.Errorf("%s: set either routes or nginx, not both", s.Name)
	}
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		where := s.Name + ".routes." + n
		if r.Port < 1 || r.Port > 65535 {
			return fmt.Errorf("%s: bad port %d", where, r.Port)
		}
		switch r.Proto {
		case "http", "tcp", "udp":
		default:
			return fmt.Errorf("%s: unknown proto %q", where, r.Proto)
		}
		switch r.Exposure {
		case "local", "tailnet", "lan", "public":
		default:
			return fmt.Errorf("%s: unknown exposure %q", where, r.Exposure)
		}
		if r.Exposure != "local" && r.Auth == nil {
			return fmt.Errorf("%s: auth is required when exposure != local", where)
		}
		if r.Exposure == "public" && str(r.Auth) == "none" && !r.PublicWithoutAuth {
			return fmt.Errorf("%s: public with auth none needs publicWithoutAuth", where)
		}
		if r.Proto == "http" && r.FQDN == nil {
			return fmt.Errorf("%s: http route without fqdn (old lib.nix?)", where)
		}
		if (len(r.Groups) > 0 || len(r.Bypass) > 0) && str(r.Auth) != "oauth2-proxy" {
			return fmt.Errorf("%s: groups/bypass only apply to auth oauth2-proxy", where)
		}
		for _, g := range r.Groups {
			if g == "" || strings.Trim(g, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-") != "" {
				return fmt.Errorf("%s: group %q is not allowed", where, g)
			}
		}
		for _, p := range r.Bypass {
			if !strings.HasPrefix(p, "/") || strings.Trim(p, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-") != "" {
				return fmt.Errorf("%s: bypass %q is not allowed", where, p)
			}
		}
		// Values pasted into nginx: no statement injection via ; { } or newlines.
		for _, v := range []string{str(r.FQDN), r.MaxBody, r.Timeouts, r.ForwardedProto} {
			if strings.ContainsAny(v, "; {}\n\t\"'$") {
				return fmt.Errorf("%s: value %q is not allowed in nginx config", where, v)
			}
		}
		// Location-level allow/deny replaces (not extends) the server-level
		// exposure ACL (writeExposureACL), so it could widen a route.
		for _, l := range strings.Split(r.ExtraConfig, "\n") {
			if f := strings.Fields(l); len(f) > 0 && (f[0] == "allow" || f[0] == "deny" || f[0] == "satisfy") {
				return fmt.Errorf("%s: extraConfig must not set %s (exposure is the ACL)", where, f[0])
			}
		}
	}
	return nil
}

// Edge listener (ROUTING-PLAN §2.3). o002 proxies public `via = edge` routes
// to <overlayIp>:edgePort on the service host over the tailnet (plain http
// inside WireGuard; TLS ends on o002). Keep edgePort in sync with lib.nix
// edgePort and host-module.nix nginx.edge.port. The host module defines
// the peer maps and the real_ip include used below, and its firewall admits
// edgePort only from the edge's overlay addresses.
const edgePort = 8443

// isEdgeRoute: http, public, and reached through the edge (o002).
func isEdgeRoute(r Route) bool {
	if r.Proto != "http" || r.Exposure != "public" {
		return false
	}
	for _, v := range r.Via {
		if v == "edge" {
			return true
		}
	}
	return false
}

// routesVhost renders the host nginx config for a service's http routes
// that leave the host (exposure != local):
//
//   - internal server (:80/:443, v4+v6, wildcard cert) for every such
//     route, public ones included (LAN/tailnet clients go direct). It never
//     trusts forwarded headers. With the host module's
//     nginx.edge.blockInternal on, it returns 444 to the edge peer.
//   - edge server (:8443, v4+v6) only for public routes via edge. It
//     returns 444 unless the TCP peer ($realip_remote_addr) is the edge,
//     and only it trusts X-Forwarded-For (real_ip) from the edge.
//
// tailnet and lan routes get only the internal server. Their source ACL
// (§2.1: enforced by transport peer, never DNS) is either an include
// written by host-module.nix (writeExposureACL) or, for a tailnet route
// with `allow`, per-host `allow <overlayIp>; # allow: <host>` lines plus
// `deny all;` -- the same set the host firewall admits on 80/443 for that
// route (srcPortLines). Returns "" when nothing is exposed.
func routesVhost(s Service) string {
	var b strings.Builder
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		if r.Proto != "http" || r.Exposure == "local" {
			continue
		}
		// Private network (ROUTING-PLAN §8 step 5): proxy to the guest IP.
		r.backend = backendAddr(s)
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "# route %s: exposure %s, auth %s; internal listener\n", n, r.Exposure, str(r.Auth))
		b.WriteString("server {\n")
		b.WriteString("  listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n")
		fmt.Fprintf(&b, "  server_name %s;\n", str(r.FQDN))
		// Cert paths live in one place: host-module.nix nginx.tls.certDir.
		b.WriteString("  include /etc/fleet-containers/nginx-tls.conf;\n")
		b.WriteString("  if ($fleet_edge_block_internal) {\n    return 444;\n  }\n")
		// net.uses callers (ROUTING-PLAN §8 step 5; FLOWS-AUDIT target
		// design (a)): same-host private guests come in on 10.233.0.1,
		// which the tailnet/lan ACL would refuse; cross-host callers
		// arrive masqueraded as their host's overlay IP. The firewall
		// half (srcPortLines) follows live discovery; this list resolves
		// both sides through the placement registry, and only falls back
		// to the declared host where the registry has no row.
		for _, c := range callerIPs(s, n) {
			fmt.Fprintf(&b, "  allow %s; # %s\n", c.ip, c.comment)
		}
		writeRouteACL(&b, r)
		writeRouteBody(&b, r)
		b.WriteString("}\n")
		if !isEdgeRoute(r) {
			continue
		}
		fmt.Fprintf(&b, "\n# route %s: edge listener (only the edge peer; X-Forwarded-For trusted)\n", n)
		b.WriteString("server {\n")
		fmt.Fprintf(&b, "  listen %d;\n  listen [::]:%d;\n", edgePort, edgePort)
		fmt.Fprintf(&b, "  server_name %s;\n", str(r.FQDN))
		b.WriteString("  include /etc/fleet-containers/nginx-edge-realip.conf;\n")
		b.WriteString("  if ($fleet_edge_peer = 0) {\n    return 444;\n  }\n")
		writeRouteBody(&b, r)
		b.WriteString("}\n")
	}
	return b.String()
}

// writeRouteACL restricts the internal server to the route's exposure
// (ROUTING-PLAN §2.1). The CIDRs live in Nix: host-module.nix writes
// /etc/fleet-containers/nginx-acl-{tailnet,lan}.conf (allow ...; deny all;).
// Server level, so every location (incl. /oauth2/ and the auth_request
// subrequest) inherits it; locations must not set their own allow/deny.
// nginx runs allow/deny in the access phase before auth_request, and the
// edge-peer 444 above (rewrite phase) before both. public: no ACL here
// (LAN and tailnet use the internal listener; the edge server is separate).
//
// A tailnet route with `allow` renders the named hosts' overlay IPs instead
// of the include (lib.nix only allows `allow` there): the same hosts the
// host firewall admits on 80/443 for that route (srcPortLines), so the two
// layers agree and a new vhost's sources are narrowed in both places at
// once. Names without an overlay IP in the inventory are skipped: the
// include would have admitted a wider range, so failing narrow is right.
func writeRouteACL(b *strings.Builder, r Route) {
	if r.Exposure == "tailnet" && len(r.Allow) > 0 {
		for _, a := range r.Allow {
			if ip := hostOverlayIP(a); ip != "" {
				fmt.Fprintf(b, "  allow %s; # allow: %s\n", ip, a)
			}
		}
		b.WriteString("  deny all;\n")
		return
	}
	switch r.Exposure {
	case "tailnet", "lan":
		fmt.Fprintf(b, "  include /etc/fleet-containers/nginx-acl-%s.conf;\n", r.Exposure)
	}
}

// Fleet oauth2-proxy (ROUTING-PLAN §4, §8 step 6). It runs on h005
// (hosts/h005/oauth2-proxy.nix). auth_request subrequests go straight to it
// over the tailnet (plain http inside WireGuard; h005's firewall admits 4180
// only from container hosts). Browser login starts and ends on
// oauth2SigninHost, the one redirect URI registered in zitadel; the session
// cookie is on .joshuabell.xyz, so every gated vhost sees it. Keep these in
// sync with hosts/h005/oauth2-proxy.nix.
const (
	oauth2Upstream   = "http://100.64.0.3:4180"
	oauth2SigninHost = "sso-proxy.joshuabell.xyz"
)

// writeCookieStrip removes oauth2-proxy cookies (_oauth2_proxy, split
// _oauth2_proxy_0.., _oauth2_proxy*_csrf) from what the backend sees, on
// every route, gated or not: a compromised app never gets a fleet session.
// Server-level `if`/`set` (rewrite phase) so the vhost needs nothing from
// the host module. One cookie per round; four covers session + 2 splits + csrf.
func writeCookieStrip(b *strings.Builder) {
	writeIndented(b, "  ", nginxCookieStrip)
}

// Shared with lib.nix nginxSnippets (h005 private zone, hand vhosts): one copy.
//
//go:embed nginx/oauth2-cookie-strip.conf
var nginxCookieStrip string

//go:embed nginx/oauth2-identity-clear.conf
var nginxIdentityClear string

func writeIndented(b *strings.Builder, indent, s string) {
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		b.WriteString(indent + l + "\n")
	}
}

// writeRouteBody writes client_max_body_size, the oauth2-proxy locations
// for gated routes, and the proxy location(s).
// X-Real-IP/$remote_addr is the TCP peer on the internal listener and the
// client (from o002's X-Forwarded-For via real_ip) on the edge listener, so
// the last X-Forwarded-For entry is trustworthy on both.
func writeRouteBody(b *strings.Builder, r Route) {
	fmt.Fprintf(b, "  client_max_body_size %s;\n", r.MaxBody)
	writeCookieStrip(b)
	gated := str(r.Auth) == "oauth2-proxy"
	if gated {
		q := ""
		if len(r.Groups) > 0 {
			q = "?allowed_groups=" + strings.Join(r.Groups, ",")
		}
		b.WriteString("  # auth = oauth2-proxy: fleet oauth2-proxy on h005 (ROUTING-PLAN §8 step 6).\n")
		b.WriteString("  location = /oauth2/auth {\n")
		fmt.Fprintf(b, "    proxy_pass %s/oauth2/auth%s;\n", oauth2Upstream, q)
		b.WriteString("    proxy_pass_request_body off;\n")
		b.WriteString("    proxy_set_header Content-Length \"\";\n")
		writeOauth2Headers(b)
		b.WriteString("  }\n")
		b.WriteString("  location /oauth2/ {\n")
		fmt.Fprintf(b, "    proxy_pass %s;\n", oauth2Upstream)
		writeOauth2Headers(b)
		b.WriteString("  }\n")
		b.WriteString("  location @fleet_oauth2_signin {\n")
		fmt.Fprintf(b, "    return 302 https://%s/oauth2/start?rd=https://$host$request_uri;\n", oauth2SigninHost)
		b.WriteString("  }\n")
	}
	writeProxyLocation(b, r, "/", gated)
	if gated {
		for _, p := range r.Bypass {
			writeProxyLocation(b, r, "^~ "+p, false)
		}
	}
}

func writeOauth2Headers(b *strings.Builder) {
	b.WriteString("    proxy_set_header Host $host;\n")
	b.WriteString("    proxy_set_header X-Real-IP $remote_addr;\n")
	b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Proto https;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Host $host;\n")
	b.WriteString("    proxy_set_header X-Forwarded-Uri $request_uri;\n")
}

func writeProxyLocation(b *strings.Builder, r Route, loc string, gated bool) {
	fmt.Fprintf(b, "  location %s {\n", loc)
	if gated {
		b.WriteString("    auth_request /oauth2/auth;\n")
		b.WriteString("    error_page 401 = @fleet_oauth2_signin;\n")
		b.WriteString("    auth_request_set $fleet_auth_user $upstream_http_x_auth_request_user;\n")
		b.WriteString("    auth_request_set $fleet_auth_email $upstream_http_x_auth_request_email;\n")
		b.WriteString("    auth_request_set $fleet_auth_groups $upstream_http_x_auth_request_groups;\n")
		b.WriteString("    auth_request_set $fleet_auth_cookie $upstream_http_set_cookie;\n")
		b.WriteString("    add_header Set-Cookie $fleet_auth_cookie;\n")
	}
	backend := r.backend
	if backend == "" {
		backend = "127.0.0.1"
	}
	fmt.Fprintf(b, "    proxy_pass http://%s:%d;\n", backend, r.Port)
	b.WriteString("    proxy_http_version 1.1;\n")
	if r.Websockets {
		b.WriteString("    proxy_set_header Upgrade $http_upgrade;\n")
		b.WriteString("    proxy_set_header Connection $connection_upgrade;\n")
	}
	b.WriteString("    proxy_set_header Host $host;\n")
	b.WriteString("    proxy_set_header X-Real-IP $remote_addr;\n")
	b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
	fmt.Fprintf(b, "    proxy_set_header X-Forwarded-Proto %s;\n", r.ForwardedProto)
	// Identity only from auth_request; always overwritten so clients can't
	// inject it (empty = header not sent).
	if gated {
		b.WriteString("    proxy_set_header Cookie $fleet_cookie;\n")
		b.WriteString("    proxy_set_header X-Auth-Request-User $fleet_auth_user;\n")
		b.WriteString("    proxy_set_header X-Auth-Request-Email $fleet_auth_email;\n")
		b.WriteString("    proxy_set_header X-Auth-Request-Groups $fleet_auth_groups;\n")
	} else {
		writeIndented(b, "    ", nginxIdentityClear)
	}
	fmt.Fprintf(b, "    proxy_buffering %s;\n", onOff(r.Buffering))
	if r.RequestBuffering != nil && !*r.RequestBuffering {
		b.WriteString("    proxy_request_buffering off;\n")
	}
	fmt.Fprintf(b, "    proxy_read_timeout %s;\n", r.Timeouts)
	fmt.Fprintf(b, "    proxy_send_timeout %s;\n", r.Timeouts)
	if x := strings.TrimSpace(r.ExtraConfig); x != "" {
		for _, l := range strings.Split(x, "\n") {
			b.WriteString("    " + strings.TrimSpace(l) + "\n")
		}
	}
	b.WriteString("  }\n")
}

func onOff(v bool) string {
	if v {
		return "on"
	}
	return "off"
}

// routePorts lists raw tcp/udp routes that leave the host, in the ports
// file format ("tcp 25565"). Same effect as tcpPorts/udpPorts today.
func routePorts(s Service) []string {
	var out []string
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		if (r.Proto == "tcp" || r.Proto == "udp") && r.Exposure != "local" {
			out = append(out, fmt.Sprintf("%s %d", r.Proto, r.Port))
		}
	}
	return out
}

// portsFileLines is the service's ports file (host-module.nix applyPorts):
// tcpPorts/udpPorts and routePorts open on the host ("tcp 3032"). For a
// private-network service (ROUTING-PLAN §8 step 5) its tcp/udp routes are
// DNATed to the guest instead ("tcp 3032 dnat 10.233.3.2"), and
// internet = false adds "noinet ve-<name>". lib.nix refuses
// tcpPorts/udpPorts together with net.private.
func portsFileLines(s Service, host string) []string {
	var out []string
	if s.Net.Private {
		out = append(out, "guest ve-"+s.Name)
	}
	if !s.Net.Private {
		for _, p := range s.TCPPorts {
			out = append(out, fmt.Sprintf("tcp %d", p))
		}
		for _, p := range s.UDPPorts {
			out = append(out, fmt.Sprintf("udp %d", p))
		}
	}
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		if (r.Proto != "tcp" && r.Proto != "udp") || r.Exposure == "local" {
			continue
		}
		l := fmt.Sprintf("%s %d", r.Proto, r.Port)
		if s.Net.Private {
			l += " dnat " + backendAddr(s)
			// tailnet: only on the host's overlay IP, as a socket bound
			// there was. Without a known overlay IP, skip it (fail closed).
			if r.Exposure == "tailnet" {
				ip := hostOverlayIP(host)
				if ip == "" {
					continue
				}
				l += " " + ip
				// allow = [ hosts ]: one line per source overlay IP
				// (fleet-net-nat @routes_from); unknown hosts are dropped.
				if len(r.Allow) > 0 {
					for _, a := range r.Allow {
						if src := hostOverlayIP(a); src != "" {
							out = append(out, l+" "+src)
						}
					}
					continue
				}
			} else if len(r.Allow) > 0 {
				// allow is only implemented for tailnet tcp/udp routes.
				continue
			}
			// lan (H4): not on every interface like public; apply-ports puts
			// it in @routes_lan (nginx.acl.lan sources + tailnet peers). An
			// older apply-ports rejects "lan" as a bad address (fails closed).
			if r.Exposure == "lan" {
				l += " lan"
			}
		}
		out = append(out, l)
	}
	if s.Net.Private && s.Internet != nil && !*s.Internet {
		out = append(out, "noinet ve-"+s.Name)
	}
	out = append(out, netExceptions(s, host)...)
	return out
}

// fleetPlacement is one discovery sweep of the container hosts, cached for
// the process: which hosts each installed service was found on, and which
// hosts did not answer. net.uses admission follows the live fleet, not the
// `host` field of service.nix: a service that moved without the repo being
// updated still lands where it actually runs.
type fleetPlacement struct {
	found map[string][]string // service -> hosts it is installed on, sorted
	down  map[string]bool     // hosts that could not be probed
}

var (
	fleetPlacementCache *fleetPlacement
	// fleetProbe is how every discovery asks a host what it has installed:
	// placement resolution (locate), net.uses admission and the sweep below.
	fleetProbe = probe // var so tests can fake the fleet
	// retired holds the (service, host) pairs this process removed. A probe
	// that still reports one -- a host that has not re-read its gcroots yet,
	// or a sweep that raced the uninstall -- must not re-admit it.
	retired = map[string]map[string]bool{}
)

// resetFleetPlacement drops the cached sweep, for a command that changed
// where a service runs (move, destroy) and must not act on the old answer.
func resetFleetPlacement() { fleetPlacementCache = nil }

// retirePlacement records that name no longer runs on host, so discovery
// cannot keep admitting that copy. Other copies of the same name are
// untouched: they are still running and still dial out as their own hosts.
func retirePlacement(name, host string) {
	if retired[name] == nil {
		retired[name] = map[string]bool{}
	}
	retired[name][host] = true
}

// fleetPlacementNow is the cached discovery sweep, or nil when discovery is
// not attempted: --dry-run must leave the fleet alone, and an inventory with
// no services has no net.uses caller to place. A service installed on this
// machine is recorded without probing here, as hostForRead does.
func fleetPlacementNow() *fleetPlacement {
	if fleetPlacementCache != nil {
		return fleetPlacementCache
	}
	loadInventory()
	if inv == nil || len(inv.Services) == 0 || dryRun {
		return nil
	}
	p := &fleetPlacement{found: map[string][]string{}, down: map[string]bool{}}
	find := func(name, h string) {
		// A copy this process already removed is not a placement, however
		// the probe still reports it.
		if retired[name][h] || slices.Contains(p.found[name], h) {
			return
		}
		p.found[name] = append(p.found[name], h)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, h := range containerHosts() {
		if isLocal(h) {
			for _, s := range inv.Services {
				if installedHere(s) {
					mu.Lock()
					find(s.Name, h)
					mu.Unlock()
				}
			}
		}
		wg.Add(1)
		go func(h string) {
			defer wg.Done()
			rows, err := fleetProbe(ctx, h)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				p.down[h] = true
				return
			}
			for _, r := range rows {
				find(r.svc, h)
			}
		}(h)
	}
	wg.Wait()
	for name := range p.found {
		sort.Strings(p.found[name])
	}
	fleetPlacementCache = p
	return p
}

// places reports from which hosts name reaches its callees, for net.uses
// admission: every host discovery found it installed on (a stale copy on an
// old host still dials out from that host's overlay IP), nothing when every
// host answered and nobody has it, or -- when any host failed to answer and
// the name was found nowhere -- the declared host, with known = false: a
// partial sweep cannot rule out that the caller is running on the host that
// did not answer. Pairs this process retired are never reported, not even
// through that fallback: a copy it just removed must not come back because
// somebody else's probe failed.
func (p *fleetPlacement) places(name, declared string) (hosts []string, known bool) {
	if p == nil {
		// No discovery (--dry-run): the declared host stands in, so the
		// printed script stays offline.
		if retired[name][declared] {
			return nil, true
		}
		return []string{declared}, true
	}
	if hosts := p.found[name]; len(hosts) > 0 {
		return hosts, true
	}
	if len(p.down) > 0 {
		if retired[name][declared] {
			return nil, true
		}
		return []string{declared}, false
	}
	return nil, true
}

// srcPortLines is this service's 80/443 admission as ports-file lines
// (host-module.nix applyPorts, which refills the nixos-fw @src* sets on
// every run): ROUTING-PLAN 8.2. Computed from the service's own routes at
// the host it is being deployed to -- not from a host-keyed inventory map --
// so a service deployed or moved onto a host reaches its own vhost there.
// Every service on a host contributes its own lines; applyPorts flushes the
// sets once per run and adds all of them. nginx still enforces the per-vhost
// exposure ACL, so over-admission here is only TCP reachability.
//
//	web <addr|cidr>   -> @src (v4) / @src6 (v6)
//	weblan <cidr>     -> @src_lan
//
// An http route with no `allow` admits the whole tailnet range (the same
// literal lib.nix webSourcesByHost uses for the build-time half); one with
// `allow` admits exactly the named hosts' overlay IPs, and an unknown name
// is skipped (fail closed). A net.uses caller of an http route is admitted
// too, from every host its live discovery puts it on: nothing for this host
// (@guest-egress already accepts the guest address), else that host's overlay
// IP. A caller every host answered for but nobody has is admitted nowhere --
// it was destroyed, so falling back to its declared host would undo the
// withdraw. Only an inconclusive sweep falls back to the declared host. The
// CLI refreshes this on deploy, move and destroy (main.go refreshCallers),
// retiring the pair it removed so one destroyed copy does not take a
// surviving copy's admission with it; the build-time half is lib.nix
// webSourcesByHost.
func srcPortLines(s Service, host string) []string {
	if inv == nil {
		return nil
	}
	var (
		ips  []string
		lan  bool
		seen = map[string]bool{}
	)
	add := func(ip string) {
		if ip == "" || seen[ip] {
			return
		}
		seen[ip] = true
		ips = append(ips, ip)
	}
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		if r.Proto != "http" || r.Exposure == "local" {
			continue
		}
		if len(r.Allow) == 0 {
			add("100.64.0.0/10")
		}
		for _, a := range r.Allow {
			add(hostOverlayIP(a))
		}
		// LAN clients reach the vhost directly unless the route is only
		// published through the router (minecraft), as in webSourcesByHost.
		if (r.Exposure == "lan" || r.Exposure == "public") && !slices.Contains(r.Via, "router") {
			lan = true
		}
	}
	// net.uses lands on the callee's nginx (ROUTING-PLAN §8 step 5). Only
	// http: tcp/udp uses are covered by netExceptions' egress elements,
	// which are what fleet-net matches for those flows. Where a caller runs
	// comes from discovery, not from its `host` field: a service moved
	// without a repo update must still reach the callee's vhost, and one
	// installed twice is admitted from both hosts.
	if len(inv.Services) > 0 {
		fp := fleetPlacementNow()
		admitCaller := func(c Service, entry string) {
			places, known := fp.places(c.Name, c.Host)
			if !known {
				// A host did not answer, so the fleet cannot contradict the
				// declaration: fall back to it rather than cut the caller off.
				fmt.Fprintf(os.Stderr, "warning: %s uses %s but was not discovered (a host did not answer); admitting its declared host %s\n", c.Name, entry, c.Host)
				places = []string{c.Host}
			} else if len(places) == 0 {
				// Every host answered and none has it: destroyed, or not yet
				// deployed. Admitting the declaration here would re-admit a
				// service that `cnt destroy` just withdrew.
				fmt.Fprintf(os.Stderr, "note: %s uses %s but is installed on no host; not admitting it\n", c.Name, entry)
				return
			}
			for _, p := range places {
				// On this host the guest's own address is already accepted
				// by @guest-egress; elsewhere the flow arrives masqueraded as
				// that host's overlay IP.
				if p == "" || p == host {
					continue
				}
				if ip := hostOverlayIP(p); ip != "" {
					add(ip)
				} else {
					fmt.Fprintf(os.Stderr, "warning: %s uses %s from %s, which has no overlayIp in the inventory; not admitting it\n", c.Name, entry, p)
				}
			}
		}
		callers := make([]Service, 0, len(inv.Services))
		for _, c := range inv.Services {
			callers = append(callers, c)
		}
		sort.Slice(callers, func(i, j int) bool { return callers[i].Name < callers[j].Name })
		for _, n := range sortedRouteNames(s) {
			if r := s.Routes[n]; r.Proto != "http" || r.Exposure == "local" {
				continue
			}
			entry := s.Name + "." + n
			for _, c := range callers {
				// net.uses only applies with net.private (lib.nix rejects
				// it otherwise), so there is no Net.Private test here.
				if slices.Contains(c.Net.Uses, entry) {
					admitCaller(c, entry)
				}
			}
		}
	}
	sort.Strings(ips)
	out := make([]string, 0, len(ips)+1)
	for _, ip := range ips {
		out = append(out, "web "+ip)
	}
	if lan && inv.LanSubnet != "" {
		out = append(out, "weblan "+inv.LanSubnet)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// ---------------------------------------------------------------- cnt routes

func cmdRoutes(args []string) error {
	f := parse(args, "no-overrides")
	loadInventory()
	var svcs []Service
	if len(f.pos) > 0 {
		svcs = []Service{service(f.pos[0])}
	} else {
		for _, s := range inv.Services {
			svcs = append(svcs, s)
		}
		sort.Slice(svcs, func(i, j int) bool { return svcs[i].Name < svcs[j].Name })
	}
	var ovs []override
	if !dryRun && !f.bools["no-overrides"] {
		hosts := map[string]bool{}
		for _, s := range svcs {
			if h := resolvedHost(s); h != "" && needsHostVhost(s) {
				hosts[h] = true
			}
		}
		var hs []string
		for h := range hosts {
			hs = append(hs, h)
		}
		sort.Strings(hs)
		ovs = fetchOverrides(hs)
	}
	fmt.Print(routesTableWith(svcs, ovs, time.Now()))
	return nil
}

func routesTable(svcs []Service) string { return routesTableWith(svcs, nil, time.Now()) }

// routesTableWith shows declared exposure, and the effective one where a
// `cnt expose` override is active (ROUTING-PLAN §5.3: "overridden").
func routesTableWith(svcs []Service, ovs []override, now time.Time) string {
	ov := map[string]override{}
	for _, o := range ovs {
		ov[o.Service+"."+o.Route] = o
	}
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "SERVICE\tROUTE\tFQDN\tPROTO\tPORT\tEXPOSURE\tAUTH\tVIA\tHOST")
	for _, s := range svcs {
		for _, n := range sortedRouteNames(s) {
			r := s.Routes[n]
			exp := r.Exposure
			if o, ok := ov[s.Name+"."+n]; ok {
				exp = fmt.Sprintf("%s (OVERRIDDEN from %s, %s left)", o.Exposure, r.Exposure, o.left(now))
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", s.Name, n, dash(str(r.FQDN)), r.Proto, r.Port,
				exp, dash(str(r.Auth)), dash(strings.Join(r.Via, ",")), dash(resolvedHost(s)))
		}
		if len(s.Routes) == 0 && s.Nginx != nil {
			fmt.Fprintf(w, "%s\t(nginx string, not converted)\t-\t-\t-\t-\t-\t-\t%s\n", s.Name, dash(resolvedHost(s)))
		}
	}
	w.Flush()
	return b.String()
}

// ---------------------------------------------------------------- cnt audit

// hostAllowlist: ports a host may listen on without a service declaring
// them. Keep this short; everything else should come from a route.
var hostAllowlist = map[string]string{
	"tcp/22":    "sshd",
	"tcp/80":    "nginx",
	"tcp/443":   "nginx",
	"tcp/8443":  "nginx edge listener (ROUTING-PLAN 2.3)",
	"tcp/53":    "dns",
	"udp/53":    "dns",
	"udp/41641": "tailscaled",
	"udp/68":    "dhcp client",
	"udp/546":   "dhcpv6 client",
	"udp/5353":  "mdns",
}

// tailnetNets: tailscale's overlay ranges (CGNAT v4, ULA v6).
var tailnetNets = func() []*net.IPNet {
	var ns []*net.IPNet
	for _, c := range []string{"100.64.0.0/10", "fd7a:115c:a1e0::/48"} {
		_, n, _ := net.ParseCIDR(c)
		ns = append(ns, n)
	}
	return ns
}()

func isTailnetOrWildcard(addr string) bool {
	if addr == "*" || addr == "0.0.0.0" || addr == "::" {
		return true
	}
	ip := net.ParseIP(addr)
	if ip == nil {
		return false
	}
	for _, n := range tailnetNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// hostProcessOwner classifies host daemons whose ports can't go in
// hostAllowlist: tailscaled opens random tcp ports (peerapi, one per
// address family) on the overlay IPs, and systemd-resolved answers LLMNR on
// 5355. Matched by process name, never by port alone; tailscaled only on
// tailnet or wildcard addresses (on a LAN IP it stays UNDECLARED).
func hostProcessOwner(l listener) string {
	if strings.Contains(l.Process, "tailscaled") && isTailnetOrWildcard(l.Addr) {
		return "tailscaled (dynamic peerapi/derp socket)"
	}
	if strings.HasPrefix(l.Process, "systemd-resolve") && l.Port == "5355" {
		return "llmnr (systemd-resolved; propose disabling)"
	}
	return ""
}

type listener struct {
	Proto, Addr, Port, Process string
}

// parseSS parses `ss -ltnupH` output. Columns: Netid State Recv-Q Send-Q
// Local Peer [Process]. Local is addr:port, [v6]:port or addr%iface:port.
func parseSS(out string) []listener {
	var ls []listener
	for _, line := range strings.Split(out, "\n") {
		fs := strings.Fields(line)
		if len(fs) < 6 {
			continue
		}
		local := fs[4]
		i := strings.LastIndex(local, ":")
		if i < 0 {
			continue
		}
		addr, port := local[:i], local[i+1:]
		addr = strings.TrimSuffix(strings.TrimPrefix(addr, "["), "]")
		if j := strings.Index(addr, "%"); j >= 0 {
			addr = addr[:j]
		}
		proc := ""
		if len(fs) > 6 {
			proc = strings.Join(fs[6:], " ")
			if a := strings.Index(proc, `(("`); a >= 0 {
				if e := strings.Index(proc[a+3:], `"`); e >= 0 {
					proc = proc[a+3 : a+3+e]
				}
			}
		}
		ls = append(ls, listener{Proto: fs[0], Addr: addr, Port: port, Process: proc})
	}
	return ls
}

func isLoopback(addr string) bool {
	return strings.HasPrefix(addr, "127.") || addr == "::1" || addr == "::ffff:127.0.0.1"
}

type auditRow struct {
	listener
	Status, Owner string
}

// auditListeners classifies the non-loopback listeners on host. Route
// ports of net.private services (ROUTING-PLAN §8 step 5) live in the
// guest's netns, so a *host* listener on one, loopback included, is STALE
// (an old host-network instance or a leak), unless a host-network service
// on the same host declares that port too.
func auditListeners(ls []listener, svcs []Service, host string, hostDecl ...hostListener) []auditRow {
	declared := map[string]string{}
	localOnly := map[string]string{} // exposure = local: must not be on the network
	private := map[string]string{}
	for _, s := range svcs {
		if resolvedHost(s) != host {
			continue
		}
		if s.Net.Private {
			for _, n := range sortedRouteNames(s) {
				r := s.Routes[n]
				p := r.Proto
				if p == "http" {
					p = "tcp"
				}
				private[p+"/"+strconv.Itoa(r.Port)] = s.Name + "." + n + " is in a private netns (" + backendAddr(s) + "); the host must not listen on it"
			}
			continue
		}
		for _, p := range s.TCPPorts {
			declared["tcp/"+strconv.Itoa(p)] = s.Name + " (tcpPorts)"
		}
		for _, p := range s.UDPPorts {
			declared["udp/"+strconv.Itoa(p)] = s.Name + " (udpPorts)"
		}
		for _, n := range sortedRouteNames(s) {
			r := s.Routes[n]
			if r.Proto == "http" {
				localOnly["tcp/"+strconv.Itoa(r.Port)] = s.Name + "." + n + " is an http backend; must listen on loopback only (nginx proxies it)"
				continue
			}
			if r.Exposure == "local" {
				localOnly[r.Proto+"/"+strconv.Itoa(r.Port)] = s.Name + "." + n + " is exposure=local but listens here"
				continue
			}
			declared[r.Proto+"/"+strconv.Itoa(r.Port)] = s.Name + "." + n + " (" + r.Exposure + ")"
		}
	}
	var rows []auditRow
	seen := map[string]bool{}
	for _, l := range ls {
		key := l.Proto + "/" + l.Port
		_, hostDeclared := declared[key]
		_, hostLocal := localOnly[key]
		if o, ok := private[key]; ok && !hostDeclared && !hostLocal {
			if !seen[key+" "+l.Addr] {
				seen[key+" "+l.Addr] = true
				rows = append(rows, auditRow{listener: l, Status: "STALE", Owner: o})
			}
			continue
		}
		if isLoopback(l.Addr) {
			continue
		}
		if seen[key+" "+l.Addr] {
			continue
		}
		seen[key+" "+l.Addr] = true
		row := auditRow{listener: l, Status: "UNDECLARED"}
		if o, ok := hostAllowlist[key]; ok {
			row.Status, row.Owner = "host", o
		} else if o := matchHostListener(l, hostDecl); o != "" {
			row.Status, row.Owner = "declared", o
		} else if o := hostProcessOwner(l); o != "" {
			row.Status, row.Owner = "host", o
		} else if o, ok := declared[key]; ok {
			row.Status, row.Owner = "declared", o
		} else if o, ok := localOnly[key]; ok {
			row.Status, row.Owner = "UNDECLARED", o
		}
		rows = append(rows, row)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		bad := func(s string) bool { return s == "UNDECLARED" || s == "STALE" }
		if bad(rows[i].Status) != bad(rows[j].Status) {
			return bad(rows[i].Status)
		}
		pi, _ := strconv.Atoi(rows[i].Port)
		pj, _ := strconv.Atoi(rows[j].Port)
		if pi != pj {
			return pi < pj
		}
		return rows[i].Proto < rows[j].Proto
	})
	return rows
}

func auditTable(rows []auditRow) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "STATUS\tPROTO\tADDR\tPORT\tPROCESS\tOWNER")
	n := 0
	for _, r := range rows {
		if r.Status == "UNDECLARED" {
			n++
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", r.Status, r.Proto, r.Addr, r.Port, dash(r.Process), dash(r.Owner))
	}
	w.Flush()
	fmt.Fprintf(&b, "\n%d undeclared non-loopback listener(s)\n", n)
	return b.String()
}

// cmdAudit is read-only and informational: it exits 0 unless the host can't
// be reached or the input is unusable. It needs root on the remote host to
// see process names (ss -p); sshArgs already wraps non-root users in
// `sudo -n` (see main.go), which fails cleanly instead of hanging when sudo
// wants a password. Plain ssh has no TTY, so password sudo can't prompt
// there: run ss locally on the host and feed the file in with --stdin.
func cmdAudit(args []string) error {
	f := parse(args, "stdin")
	loadInventory()
	hosts := f.pos
	if len(hosts) == 0 {
		hosts = containerHosts()
	}
	if f.bools["stdin"] && len(hosts) != 1 {
		fmt.Fprintln(os.Stderr, "usage: containers audit <host> --stdin   (reads ss -ltnupH from stdin, exactly one host)")
		return nil
	}
	if !dryRun {
		defer printRoutingAudit(os.Stdout, edgeClientFor)
	}
	var svcs []Service
	for _, s := range inv.Services {
		svcs = append(svcs, s)
	}
	for _, h := range hosts {
		if f.bools["stdin"] {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s: reading stdin: %v\n", h, err)
				continue
			}
			ssOut, hl, ov := splitAudit(string(b))
			ls := parseSS(ssOut)
			if len(ls) == 0 {
				fmt.Fprintln(os.Stderr, "no ss output on stdin; collection failed?")
				continue
			}
			fmt.Printf("== %s\n", h)
			fmt.Print(auditTable(auditListeners(ls, svcs, h, parseHostListeners(hl)...)))
			printAuditOverrides(parseOverrides(ov, h))
			continue
		}
		fmt.Printf("== %s\n", h)
		if dryRun {
			fmt.Printf("[%s (root)] %s\n", h, auditCollectScript)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		out, err := remoteOut(ctx, h, true, auditCollectScript)
		cancel()
		if err != nil {
			if sudoNeedsPassword(err) {
				fmt.Fprint(os.Stderr, needsRootMsg(h))
				continue
			}
			fmt.Fprintf(os.Stderr, "%s: %v\n", h, err)
			continue
		}
		ssOut, hl, ov := splitAudit(out)
		fmt.Print(auditTable(auditListeners(parseSS(ssOut), svcs, h, parseHostListeners(hl)...)))
		printAuditOverrides(parseOverrides(ov, h))
	}
	return nil
}

type routingCheck struct {
	Layer   string `json:"layer"`
	FQDN    string `json:"fqdn"`
	Service string `json:"service"`
	Host    string `json:"host"`
	Want    string `json:"want"`
	Got     string `json:"got"`
	Status  string `json:"status"`
	Detail  string `json:"detail"`
}

// Routing shows DNS, HTTP edge, TCP stream and WAN forward layers. It is
// diagnostic: an unavailable authority is not an audit failure. A machine
// without credentials omits the section quietly.
func printRoutingAudit(w io.Writer, client func() (*edgeClient, error)) {
	c, err := client()
	if errors.Is(err, errNoToken) {
		return
	}
	fmt.Fprintln(w, "== routing (h005)")
	if err != nil {
		fmt.Fprintf(w, "pending: %v\n", err)
		return
	}
	var report struct {
		Checks []routingCheck `json:"checks"`
		Errors []string       `json:"errors"`
	}
	if err := c.do("GET", "/api/placements/routing", nil, &report); err != nil {
		fmt.Fprintf(w, "pending: %v\n", err)
		return
	}
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "LAYER\tNAME\tSTATUS\tWANT\tGOT\tDETAIL")
	for _, row := range report.Checks {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\n", row.Layer, row.FQDN, row.Status, dash(row.Want), dash(row.Got), row.Detail)
	}
	_ = tw.Flush()
	for _, err := range report.Errors {
		fmt.Fprintf(w, "pending: %s\n", err)
	}
}

// needsRootMsg: sudo over plain ssh has no TTY to ask for a password.
func needsRootMsg(h string) string {
	return fmt.Sprintf(`audit needs root on %[1]s and sudo there wants a password (plain ssh has no TTY to prompt).
Either run it on %[1]s itself:
  sudo ss -ltnupH > /tmp/%[1]s.ss && cnt audit %[1]s --stdin < /tmp/%[1]s.ss
or collect over ssh with a TTY and feed the file in:
  ssh -t %[1]s 'sudo ss -ltnupH > /tmp/%[1]s.ss' && scp %[1]s:/tmp/%[1]s.ss /tmp/ && cnt audit %[1]s --stdin < /tmp/%[1]s.ss
`, h)
}

// sudoNeedsPassword reports whether err looks like `sudo -n`'s failure when
// it needs an interactive password (as opposed to e.g. a dead host).
func sudoNeedsPassword(err error) bool {
	return err != nil && strings.Contains(err.Error(), "a password is required")
}

// ------------------------------------------------- private-net exceptions

// usesTarget resolves a net.uses entry ("svc.route").
func usesTarget(u string) (Service, Route, bool) {
	i := strings.IndexByte(u, '.')
	if i < 0 || inv == nil {
		return Service{}, Route{}, false
	}
	t, ok := inv.Services[u[:i]]
	if !ok {
		return Service{}, Route{}, false
	}
	r, ok := t.Routes[u[i+1:]]
	return t, r, ok
}

// netExceptions is the guest's allow list beyond internet + DNS
// (ROUTING-PLAN §8 step 5), as ports-file "allow" lines:
// "allow ve-<name> <ipv4> <proto> <port>". net.uses of an http route goes
// to the nginx that serves it: this host's 10.233.0.1:443 when the callee
// lives here (split DNS answers with the host's own overlay IP, so the
// overlay IP too), else the callee host's overlay IP:443. A tcp/udp route
// goes to its DNAT/host port on the callee host (overlay IP), or this
// host's addresses when local. net.egress entries pass through as given.
func netExceptions(s Service, host string) []string {
	if !s.Net.Private {
		return nil
	}
	ve := "ve-" + s.Name
	var out []string
	add := func(ip, proto string, port int) {
		out = append(out, fmt.Sprintf("allow %s %s %s %d", ve, ip, proto, port))
	}
	hostIPs := func(h string) []string {
		var ips []string
		if h == host {
			ips = append(ips, "10.233.0.1")
		}
		if inv != nil {
			if hh, ok := inv.Hosts[h]; ok && hh.OverlayIP != nil {
				ips = append(ips, *hh.OverlayIP)
			}
		}
		return ips
	}
	for _, u := range s.Net.Uses {
		t, r, ok := usesTarget(u)
		if !ok {
			continue
		}
		th := resolvedHost(t)
		if th == "" {
			continue
		}
		proto, ports := "tcp", []int{80, 443}
		if r.Proto == "tcp" || r.Proto == "udp" {
			proto, ports = r.Proto, []int{r.Port}
		}
		// Same host, both private: straight to the guest (also how local
		// routes, which have no name or host port, are reached).
		if th == host && t.Net.Private && t.Net.IP != nil {
			p := r.Proto
			if p == "http" {
				p = "tcp"
			}
			add(*t.Net.IP, p, r.Port)
		}
		if r.Exposure == "local" {
			continue
		}
		for _, ip := range hostIPs(th) {
			for _, p := range ports {
				add(ip, proto, p)
			}
		}
	}
	for _, e := range s.Net.Egress {
		// "<ipv4>:<port>/<proto>", validated by lib.nix
		hp, proto, _ := strings.Cut(e, "/")
		ip, port, _ := strings.Cut(hp, ":")
		p, err := strconv.Atoi(port)
		if err == nil {
			add(ip, proto, p)
		}
	}
	return out
}

// callerEntry is one `allow <ip>; # net.uses <svc>` line: either a private
// guest IP on this host, or a caller host's overlay IP (cross-host uses).
type callerEntry struct {
	ip      string
	comment string
}

// callerIPs lists sources that reach nginx here via net.uses of
// s.<route>, in addition to the route's own exposure ACL:
//   - same host, private caller: its guest IP (10.233.x.2) arrives via
//     10.233.0.1, which the tailnet/lan ACL would refuse;
//   - a different host: the caller host's overlay IP, since a cross-host
//     caller's packets leave masqueraded as that host (FLOWS-AUDIT target
//     design (a): "the callee's vhost renders allow <caller host
//     overlayIp>; # net.uses <svc>").
//
// Both sides are resolved through the placement registry, so a caller or a
// callee that moved without the repo being updated is still admitted on the
// host it actually runs on; a pair the registry has no row for falls back to
// the declared host, and so is only as current as the repo. This is the nginx
// half, rendered by a deploy of the callee itself. The firewall half
// (srcPortLines) follows live discovery instead, and main.go refreshCallers
// rewrites it on a deploy, move or destroy; a vhost left stale that way still
// refuses the caller until the callee's next deploy.
func callerIPs(s Service, route string) []callerEntry {
	if inv == nil {
		return nil
	}
	sh := resolvedHost(s)
	var out []callerEntry
	seenHost := map[string]bool{}
	for _, c := range inv.Services {
		for _, u := range c.Net.Uses {
			if u != s.Name+"."+route {
				continue
			}
			ch := resolvedHost(c)
			if c.Net.Private && c.Net.IP != nil && ch == sh {
				out = append(out, callerEntry{ip: *c.Net.IP, comment: "net.uses " + c.Name})
				continue
			}
			if ch == "" || ch == sh || seenHost[ch] {
				continue
			}
			if ip := hostOverlayIP(ch); ip != "" {
				out = append(out, callerEntry{ip: ip, comment: "net.uses " + c.Name})
				seenHost[ch] = true
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ip < out[j].ip })
	return out
}

// hostOverlayIP is the host's tailnet IPv4 from the inventory, or "".
func hostOverlayIP(host string) string {
	if inv == nil {
		return ""
	}
	if h, ok := inv.Hosts[host]; ok && h.OverlayIP != nil {
		return *h.OverlayIP
	}
	return ""
}

// ------------------------------------------------- declared host listeners

// hostListenersFile is written by host-module.nix: host daemons the module
// itself declares (the status endpoint today), one per line:
//
//	<tcp|udp> <addr|*> <port> <owner...>
//
// audit reads it over the same ssh as ss, so the allowlist stays data-driven
// (the address and port come from the host's config, not from the CLI).
const hostListenersFile = "/etc/fleet-containers/host-listeners"

type hostListener struct {
	Proto, Addr, Port, Owner string
}

func parseHostListeners(s string) []hostListener {
	var out []hostListener
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		f := strings.Fields(l)
		if len(f) < 4 || (f[0] != "tcp" && f[0] != "udp") {
			continue
		}
		if p, err := strconv.Atoi(f[2]); err != nil || p < 1 || p > 65535 {
			continue
		}
		addr := strings.TrimSuffix(strings.TrimPrefix(f[1], "["), "]")
		out = append(out, hostListener{Proto: f[0], Addr: addr, Port: f[2], Owner: strings.Join(f[3:], " ")})
	}
	return out
}

// matchHostListener: same proto and port, and the same address (a declared
// "*" matches any). An undeclared address on that port stays UNDECLARED.
func matchHostListener(l listener, hs []hostListener) string {
	for _, h := range hs {
		if h.Proto == l.Proto && h.Port == l.Port && (h.Addr == "*" || h.Addr == l.Addr) {
			return h.Owner
		}
	}
	return ""
}

// auditCollectScript gathers ss, the declared host listeners and the
// active expose overrides in one root ssh, separated by marker lines.
const (
	auditMarkHost = "#### fleet host-listeners"
	auditMarkOv   = "#### fleet overrides"
)

var auditCollectScript = "ss -ltnupH\necho '" + auditMarkHost + "'\ncat " + hostListenersFile + " 2>/dev/null || true\necho '" + auditMarkOv + "'\n" + overridesListScript + "\n"

// splitAudit splits collected output into ss, host-listeners and overrides.
// Plain `ss` output (no markers, e.g. --stdin) is all ss.
func splitAudit(out string) (ss, hostL, ovs string) {
	ss, rest, ok := strings.Cut(out, auditMarkHost+"\n")
	if !ok {
		return out, "", ""
	}
	hostL, ovs, _ = strings.Cut(rest, auditMarkOv+"\n")
	return ss, hostL, ovs
}

// printAuditOverrides lists active `cnt expose` overrides under the audit
// table: they are intended, but a reviewer must see them.
func printAuditOverrides(ovs []override) {
	if len(ovs) == 0 {
		return
	}
	fmt.Printf("\n%d active expose override(s):\n", len(ovs))
	fmt.Print(overridesTable(ovs, time.Now()))
	for _, o := range ovs {
		if o.Exposure == "public" {
			fmt.Println("public overrides: run cnt expose --list for h005/DNS/o002 state and leftovers")
			break
		}
	}
}
