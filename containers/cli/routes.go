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
	"fmt"
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
	Name           *string `json:"name"`
	Zone           *string `json:"zone"`
	FQDN           *string `json:"fqdn"`
	URL            *string `json:"url"`
	Websockets     bool    `json:"websockets"`
	MaxBody        string  `json:"maxBody"`
	Buffering      bool    `json:"buffering"`
	Timeouts       string  `json:"timeouts"`
	ForwardedProto string  `json:"forwardedProto"`
	ExtraConfig    string  `json:"extraConfig"`
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

// routesVhost renders the host nginx config for a service's http routes
// that leave the host (exposure != local). Same shape as the hand-written
// vhosts: one server per route on :80/:443 (v4+v6) with the wildcard cert.
// Step 1 renders tailnet, lan and public identically; the internal/edge
// listener split and per-source allow lists come in step 3 (§2.3).
// Returns "" when nothing is exposed.
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
		fmt.Fprintf(&b, "# route %s: exposure %s, auth %s\n", n, r.Exposure, str(r.Auth))
		b.WriteString("server {\n")
		b.WriteString("  listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n")
		fmt.Fprintf(&b, "  server_name %s;\n", str(r.FQDN))
		b.WriteString("  ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;\n")
		b.WriteString("  ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;\n")
		fmt.Fprintf(&b, "  client_max_body_size %s;\n", r.MaxBody)
		b.WriteString("  location / {\n")
		fmt.Fprintf(&b, "    proxy_pass http://127.0.0.1:%d;\n", r.Port)
		b.WriteString("    proxy_http_version 1.1;\n")
		if r.Websockets {
			b.WriteString("    proxy_set_header Upgrade $http_upgrade;\n")
			b.WriteString("    proxy_set_header Connection $connection_upgrade;\n")
		}
		b.WriteString("    proxy_set_header Host $host;\n")
		b.WriteString("    proxy_set_header X-Real-IP $remote_addr;\n")
		b.WriteString("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n")
		fmt.Fprintf(&b, "    proxy_set_header X-Forwarded-Proto %s;\n", r.ForwardedProto)
		b.WriteString("    # TODO(ROUTING-PLAN §8 step 6): strip _oauth2_proxy* cookies before the backend.\n")
		fmt.Fprintf(&b, "    proxy_buffering %s;\n", map[bool]string{true: "on", false: "off"}[r.Buffering])
		fmt.Fprintf(&b, "    proxy_read_timeout %s;\n", r.Timeouts)
		fmt.Fprintf(&b, "    proxy_send_timeout %s;\n", r.Timeouts)
		if x := strings.TrimSpace(r.ExtraConfig); x != "" {
			for _, l := range strings.Split(x, "\n") {
				b.WriteString("    " + strings.TrimSpace(l) + "\n")
			}
		}
		b.WriteString("  }\n}\n")
	}
	return b.String()
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
	"tcp/53":    "dns",
	"udp/53":    "dns",
	"udp/41641": "tailscaled",
	"udp/68":    "dhcp client",
	"udp/546":   "dhcpv6 client",
	"udp/5353":  "mdns",
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
			proto := r.Proto
			if proto == "http" {
				proto = "tcp"
			}
			if r.Exposure == "local" {
				localOnly[proto+"/"+strconv.Itoa(r.Port)] = s.Name + "." + n
				continue
			}
			declared[proto+"/"+strconv.Itoa(r.Port)] = s.Name + "." + n + " (" + r.Exposure + ")"
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
		} else if o, ok := declared[key]; ok {
			row.Status, row.Owner = "declared", o
		} else if o, ok := localOnly[key]; ok {
			row.Status, row.Owner = "UNDECLARED", o+" is exposure=local but listens here"
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

// cmdAudit is read-only and informational: it always exits 0 unless the
// host can't be reached.
func cmdAudit(args []string) error {
	f := parse(args)
	loadInventory()
	hosts := f.pos
	if len(hosts) == 0 {
		hosts = containerHosts()
	}
	var svcs []Service
	for _, s := range inv.Services {
		svcs = append(svcs, s)
	}
	for _, h := range hosts {
		fmt.Printf("== %s\n", h)
		if dryRun {
			fmt.Printf("[%s (root)] ss -ltnupH\n", h)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		out, err := remoteOut(ctx, h, true, "ss -ltnupH")
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", h, err)
			continue
		}
		fmt.Print(auditTable(auditListeners(parseSS(out), svcs, h)))
	}
	return nil
}
