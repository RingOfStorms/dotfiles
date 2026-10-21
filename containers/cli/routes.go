package main

// Routes (ROUTING-PLAN.md §2, step 1 of §8): the host vhost and firewall
// ports generated from service.nix `routes`, `cnt routes` and `cnt audit`.
//
// lib.nix normalizes and validates routes (defaults filled in, bad combos
// throw), so the CLI trusts the inventory. validateRoutes mirrors the checks
// that would make the generated config unsafe, as a second line in case the
// inventory comes from an older lib.nix.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
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
	PublicWithoutAuth bool     `json:"publicWithoutAuth"`
	// http only (null for tcp/udp)
	Name       *string `json:"name"`
	Zone       *string `json:"zone"`
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
		if r.Exposure == "public" && str(r.Zone) == "private" {
			return fmt.Errorf("%s: private zone can't be public", where)
		}
		if r.Proto == "http" && r.FQDN == nil {
			return fmt.Errorf("%s: http route without fqdn (old lib.nix?)", where)
		}
		// Values pasted into nginx: no statement injection via ; { } or newlines.
		for _, v := range []string{str(r.FQDN), r.MaxBody, r.Timeouts, r.ForwardedProto} {
			if strings.ContainsAny(v, "; {}\n\t\"'$") {
				return fmt.Errorf("%s: value %q is not allowed in nginx config", where, v)
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
// tailnet and lan routes get only the internal server; their per-source
// allow lists come with fleet-edge (step 4). Returns "" when nothing is
// exposed.
func routesVhost(s Service) string {
	var b strings.Builder
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		if r.Proto != "http" || r.Exposure == "local" {
			continue
		}
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "# route %s: exposure %s, auth %s; internal listener\n", n, r.Exposure, str(r.Auth))
		b.WriteString("server {\n")
		b.WriteString("  listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n")
		fmt.Fprintf(&b, "  server_name %s;\n", str(r.FQDN))
		b.WriteString("  ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;\n")
		b.WriteString("  ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;\n")
		b.WriteString("  if ($fleet_edge_block_internal) {\n    return 444;\n  }\n")
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

// writeRouteBody writes client_max_body_size and the proxy location.
// X-Real-IP/$remote_addr is the TCP peer on the internal listener and the
// client (from o002's X-Forwarded-For via real_ip) on the edge listener, so
// the last X-Forwarded-For entry is trustworthy on both.
func writeRouteBody(b *strings.Builder, r Route) {
	fmt.Fprintf(b, "  client_max_body_size %s;\n", r.MaxBody)
	b.WriteString("  location / {\n")
	fmt.Fprintf(b, "    proxy_pass http://127.0.0.1:%d;\n", r.Port)
	b.WriteString("    proxy_http_version 1.1;\n")
	if r.Websockets {
		b.WriteString("    proxy_set_header Upgrade $http_upgrade;\n")
		b.WriteString("    proxy_set_header Connection $connection_upgrade;\n")
	}
	b.WriteString("    proxy_set_header Host $host;\n")
	b.WriteString("    proxy_set_header X-Real-IP $remote_addr;\n")
	b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
	fmt.Fprintf(b, "    proxy_set_header X-Forwarded-Proto %s;\n", r.ForwardedProto)
	b.WriteString("    # TODO(ROUTING-PLAN §8 step 6): strip _oauth2_proxy* cookies before the backend.\n")
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

// ---------------------------------------------------------------- cnt routes

func cmdRoutes(args []string) error {
	f := parse(args)
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
	fmt.Print(routesTable(svcs))
	return nil
}

func routesTable(svcs []Service) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "SERVICE\tROUTE\tFQDN\tPROTO\tPORT\tEXPOSURE\tAUTH\tVIA\tHOST")
	for _, s := range svcs {
		for _, n := range sortedRouteNames(s) {
			r := s.Routes[n]
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", s.Name, n, dash(str(r.FQDN)), r.Proto, r.Port,
				r.Exposure, dash(str(r.Auth)), dash(strings.Join(r.Via, ",")), dash(s.Host))
		}
		if len(s.Routes) == 0 && s.Nginx != nil {
			fmt.Fprintf(w, "%s\t(nginx string, not converted)\t-\t-\t-\t-\t-\t-\t%s\n", s.Name, dash(s.Host))
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

// auditListeners classifies the non-loopback listeners on host.
func auditListeners(ls []listener, svcs []Service, host string) []auditRow {
	declared := map[string]string{}
	localOnly := map[string]string{} // exposure = local: must not be on the network
	for _, s := range svcs {
		if s.Host != host {
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
		if isLoopback(l.Addr) {
			continue
		}
		key := l.Proto + "/" + l.Port
		if seen[key+" "+l.Addr] {
			continue
		}
		seen[key+" "+l.Addr] = true
		row := auditRow{listener: l, Status: "UNDECLARED"}
		if o, ok := hostAllowlist[key]; ok {
			row.Status, row.Owner = "host", o
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
		if (rows[i].Status == "UNDECLARED") != (rows[j].Status == "UNDECLARED") {
			return rows[i].Status == "UNDECLARED"
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
		return errors.New("usage: containers audit <host> --stdin   (reads ss -ltnupH from stdin, exactly one host)")
	}
	var svcs []Service
	for _, s := range inv.Services {
		svcs = append(svcs, s)
	}
	for _, h := range hosts {
		if f.bools["stdin"] {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				return fmt.Errorf("%s: reading stdin: %v", h, err)
			}
			ls := parseSS(string(b))
			if len(ls) == 0 {
				return errors.New("no ss output on stdin; collection failed?")
			}
			fmt.Printf("== %s\n", h)
			fmt.Print(auditTable(auditListeners(ls, svcs, h)))
			continue
		}
		fmt.Printf("== %s\n", h)
		if dryRun {
			fmt.Printf("[%s (root)] ss -ltnupH\n", h)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		out, err := remoteOut(ctx, h, true, "ss -ltnupH")
		cancel()
		if err != nil {
			if sudoNeedsPassword(err) {
				fmt.Fprint(os.Stderr, needsRootMsg(h))
				return errors.New("audit needs root")
			}
			fmt.Fprintf(os.Stderr, "%s: %v\n", h, err)
			continue
		}
		fmt.Print(auditTable(auditListeners(parseSS(out), svcs, h)))
	}
	return nil
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
