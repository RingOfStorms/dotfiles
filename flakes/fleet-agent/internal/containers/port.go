package containers

// `cnt port` (ROUTING-PLAN.md §8 step 2): open a port for a while without a
// rebuild. The only state is elements in three nft sets of inet nixos-fw
// (host-module.nix creates them and the input-allow rules):
//
//	cnt-tmp   ifname . inet_proto . inet_service               (flags timeout)
//	cnt-tmp4  ifname . inet_proto . inet_service . ipv4_addr   (interval,timeout)
//	cnt-tmp6  ifname . inet_proto . inet_service . ipv6_addr   (interval,timeout)
//
// The kernel expires elements; a firewall reload empties the sets (fail
// closed). Each element carries comment "svc=<svc>". ifname is the real
// interface, or the literal "any" which the module's rules match for every
// interface (`"any" . meta l4proto . th dport @cnt-tmp accept`).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

const (
	portMaxFor  = 24 * time.Hour
	lanIfaceEtc = "/etc/fleet-containers/lan-interface"
	anyIface    = "any"
)

var portSets = []string{"cnt-tmp", "cnt-tmp4", "cnt-tmp6"}

type portReq struct {
	Svc    string
	Port   int
	Proto  string
	For    time.Duration // zero for close
	From   []string      // CIDRs (v4 and/or v6), resolved
	Iface  string        // tailnet | lan | any
	Host   string
	Force  bool
	Closer bool
}

// parsePortSpec parses "8000/tcp".
func parsePortSpec(s string) (int, string, error) {
	p, proto, ok := strings.Cut(s, "/")
	if !ok || (proto != "tcp" && proto != "udp") {
		return 0, "", fmt.Errorf("port %q: want <port>/<tcp|udp>", s)
	}
	n, err := strconv.Atoi(p)
	if err != nil || n < 1 || n > 65535 {
		return 0, "", fmt.Errorf("port %q: bad port number", s)
	}
	return n, proto, nil
}

func parseFor(s string) (time.Duration, error) {
	if s == "" {
		return 0, errors.New("--for is required (e.g. --for 30m; max 24h)")
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("--for %q: %v", s, err)
	}
	if d < time.Second {
		return 0, fmt.Errorf("--for %q: must be at least 1s", s)
	}
	if d > portMaxFor {
		return 0, fmt.Errorf("--for %q: at most 24h", s)
	}
	return d, nil
}

// resolveFrom turns a fleet host name into its overlay address(es), or
// normalizes a CIDR/IP to a CIDR.
func resolveFrom(v string, hosts map[string]Host) ([]string, error) {
	if h, ok := hosts[v]; ok {
		var out []string
		if h.OverlayIP != nil && *h.OverlayIP != "" {
			out = append(out, *h.OverlayIP+"/32")
		}
		if h.OverlayIP6 != nil && *h.OverlayIP6 != "" {
			out = append(out, *h.OverlayIP6+"/128")
		}
		if len(out) == 0 {
			return nil, fmt.Errorf("--from %s: host has no overlayIp in hosts/fleet.nix", v)
		}
		return out, nil
	}
	if ip := net.ParseIP(v); ip != nil {
		if ip.To4() != nil {
			return []string{ip.String() + "/32"}, nil
		}
		return []string{ip.String() + "/128"}, nil
	}
	_, n, err := net.ParseCIDR(v)
	if err != nil {
		return nil, fmt.Errorf("--from %q: not a fleet host, IP or CIDR", v)
	}
	if ones, _ := n.Mask.Size(); ones == 0 {
		return nil, fmt.Errorf("--from %q: a /0 is everything; omit --from instead", v)
	}
	return []string{n.String()}, nil
}

func isV6CIDR(c string) bool {
	ip, _, err := net.ParseCIDR(c)
	return err == nil && ip.To4() == nil
}

// parsePortArgs parses open/close arguments. Repeated --from is collected
// by hand since the shared parser keeps only the last value.
func parsePortArgs(args []string, closing bool, hosts map[string]Host) (portReq, error) {
	var froms, rest []string
	// Classic loop: the body advances i to consume --from values.
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--from" || a == "-from" {
			if i+1 >= len(args) {
				return portReq{}, errors.New("--from needs a value")
			}
			froms = append(froms, args[i+1])
			i++
			continue
		}
		if v, ok := strings.CutPrefix(a, "--from="); ok {
			froms = append(froms, v)
			continue
		}
		rest = append(rest, a)
	}
	f := parse(rest, "force-backend")
	r := portReq{Closer: closing, Host: f.vals["host"], Force: f.bools["force-backend"]}
	verb := map[bool]string{false: "open", true: "close"}[closing]
	if len(f.pos) != 2 {
		return r, fmt.Errorf("usage: cnt port %s <svc> <port>/<tcp|udp>%s [--from host|cidr]... [--iface tailnet|lan|any] [--host h]",
			verb, map[bool]string{false: " --for <dur>", true: ""}[closing])
	}
	r.Svc = f.pos[0]
	var err error
	if r.Port, r.Proto, err = parsePortSpec(f.pos[1]); err != nil {
		return r, err
	}
	if !closing {
		if r.For, err = parseFor(f.vals["for"]); err != nil {
			return r, err
		}
	} else if f.vals["for"] != "" {
		return r, errors.New("close takes no --for")
	}
	r.Iface = f.vals["iface"]
	if r.Iface == "" {
		r.Iface = "tailnet"
	}
	switch r.Iface {
	case "tailnet", "lan", "any":
	default:
		return r, fmt.Errorf("--iface %q: want tailnet, lan or any", r.Iface)
	}
	seen := map[string]bool{}
	for _, v := range froms {
		cs, err := resolveFrom(v, hosts)
		if err != nil {
			return r, err
		}
		for _, c := range cs {
			if !seen[c] {
				seen[c] = true
				r.From = append(r.From, c)
			}
		}
	}
	return r, nil
}

// backendOf names the http route on host that uses port as its backend.
func backendOf(svcs map[string]Service, host string, port int, proto string) string {
	if proto != "tcp" {
		return ""
	}
	var hits []string
	for _, s := range svcs {
		if resolvedHost(s) != host {
			continue
		}
		for _, n := range sortedRouteNames(s) {
			if r := s.Routes[n]; r.Proto == "http" && r.Port == port {
				hits = append(hits, s.Name+"."+n)
			}
		}
	}
	sort.Strings(hits)
	return strings.Join(hits, ", ")
}

// declaredOpen reports whether the service already opens port/proto
// declaratively (tcpPorts/udpPorts or a non-local tcp/udp route; both end up
// in its ports file).
func declaredOpen(s Service, port int, proto string) bool {
	ps := s.TCPPorts
	if proto == "udp" {
		ps = s.UDPPorts
	}
	for _, p := range ps {
		if p == port {
			return true
		}
	}
	for _, l := range routePorts(s) {
		if l == fmt.Sprintf("%s %d", proto, port) {
			return true
		}
	}
	return false
}

// portElems returns "set\telement-key" pairs. $IFACE is a shell variable
// set by the script (tailnet/any are constants, lan is read on the host).
func portElems(r portReq) [][2]string {
	key := fmt.Sprintf(`"$IFACE" . %s . %d`, r.Proto, r.Port)
	if len(r.From) == 0 {
		return [][2]string{{"cnt-tmp", key}}
	}
	var out [][2]string
	for _, c := range r.From {
		set := "cnt-tmp4"
		if isV6CIDR(c) {
			set = "cnt-tmp6"
		}
		out = append(out, [2]string{set, key + " . " + c})
	}
	return out
}

func ifaceScript(iface string) string {
	switch iface {
	case "tailnet":
		return "IFACE=tailscale0\n"
	case "any":
		return "IFACE=" + anyIface + "\n"
	}
	return fmt.Sprintf(`IFACE=$(cat %[1]s 2>/dev/null)
[ -n "$IFACE" ] || { echo "--iface lan: this host has no ringofstorms.containers.lanInterface set (%[1]s missing)" >&2; exit 1; }
`, lanIfaceEtc)
}

func installedCheck(s Service) string {
	marker := mutableUnits + "/" + unitOf(s)
	if s.Kind == "podman" {
		marker = gcroots + "/" + s.Name
	}
	return fmt.Sprintf("[ -e %s ] || [ -L %s ] || { echo %s >&2; exit 1; }\n", q(marker), q(marker),
		q(s.Name+" is not installed on this host"))
}

// portOpenScript is the root script run on the host. It refuses if the
// service is not installed there, says "already open (declared)" if the
// ports file lists it, warns if nothing listens, then adds the elements in
// one nft transaction (add+delete+add re-arms the timeout if it exists).
func portOpenScript(s Service, r portReq) string {
	var b strings.Builder
	b.WriteString("set -eu\n")
	b.WriteString(installedCheck(s))
	fmt.Fprintf(&b, "if grep -qx %s %s 2>/dev/null; then echo %s; exit 0; fi\n",
		q(fmt.Sprintf("%s %d", r.Proto, r.Port)), q("/var/lib/fleet-containers/ports/"+s.Name),
		q(fmt.Sprintf("%s %d/%s: already open (declared)", s.Name, r.Port, r.Proto)))
	b.WriteString(ifaceScript(r.Iface))
	flag := "-t"
	if r.Proto == "udp" {
		flag = "-u"
	}
	fmt.Fprintf(&b, "ss -lnH %s 'sport = :%d' | grep -q . || echo 'warning: nothing listens on %d/%s yet; opening anyway' >&2\n",
		flag, r.Port, r.Port, r.Proto)
	secs := int(r.For.Seconds())
	comment := "svc=" + s.Name
	b.WriteString("nft -f - <<EOF\n")
	for _, e := range portElems(r) {
		fmt.Fprintf(&b, "add element inet nixos-fw %s { %s timeout %ds comment \"%s\" }\n", e[0], e[1], secs, comment)
		fmt.Fprintf(&b, "delete element inet nixos-fw %s { %s }\n", e[0], e[1])
		fmt.Fprintf(&b, "add element inet nixos-fw %s { %s timeout %ds comment \"%s\" }\n", e[0], e[1], secs, comment)
	}
	b.WriteString("EOF\n")
	desc := portDesc(s, r)
	fmt.Fprintf(&b, "logger -t cnt-port \"open %s iface=$IFACE for=%ds by=${SUDO_USER:-$(id -un)}\"\n", desc, secs)
	fmt.Fprintf(&b, "echo \"opened %s on $IFACE for %s\"\n", desc, r.For)
	return b.String()
}

// portCloseScript deletes exactly the given live elements (found by
// closeTargets from `nft -j list set`), in one nft transaction.
func portCloseScript(s Service, r portReq, iface string, es []portEntry) string {
	var b strings.Builder
	b.WriteString("set -eu\n")
	b.WriteString("nft -f - <<EOF || { echo 'not open (or already expired); see cnt port ls' >&2; exit 1; }\n")
	for _, e := range es {
		key := fmt.Sprintf(`"%s" . %s . %s`, e.Iface, e.Proto, e.Port)
		if e.Set != "cnt-tmp" {
			key += " . " + e.From
		}
		fmt.Fprintf(&b, "delete element inet nixos-fw %s { %s }\n", e.Set, key)
	}
	b.WriteString("EOF\n")
	desc := portDesc(s, r)
	fmt.Fprintf(&b, "logger -t cnt-port \"close %s iface=%s n=%d by=${SUDO_USER:-$(id -un)}\"\n", desc, iface, len(es))
	fmt.Fprintf(&b, "echo \"closed %s on %s (%d element(s))\"\n", desc, iface, len(es))
	return b.String()
}

// closeTargets picks the live elements a close removes: same svc (comment),
// port, proto and iface, across all three sets. With --from, only those
// sources (nft prints /32 and /128 without the prefix length).
func closeTargets(es []portEntry, r portReq, iface string) []portEntry {
	want := map[string]bool{}
	for _, c := range r.From {
		want[normCIDR(c)] = true
	}
	var out []portEntry
	for _, e := range es {
		if e.Svc != r.Svc || e.Port != strconv.Itoa(r.Port) || e.Proto != r.Proto || e.Iface != iface {
			continue
		}
		if len(want) > 0 && (e.Set == "cnt-tmp" || !want[normCIDR(e.From)]) {
			continue
		}
		out = append(out, e)
	}
	return out
}

func normCIDR(c string) string {
	return strings.TrimSuffix(strings.TrimSuffix(c, "/32"), "/128")
}

// ifaceName resolves --iface to the name stored in the set elements.
func ifaceName(ctx context.Context, h, iface string) (string, error) {
	switch iface {
	case "tailnet":
		return "tailscale0", nil
	case "any":
		return anyIface, nil
	}
	out, err := remoteOut(ctx, h, false, "cat "+lanIfaceEtc)
	if err != nil || strings.TrimSpace(out) == "" {
		return "", fmt.Errorf("--iface lan: %s has no %s (ringofstorms.containers.lanInterface)", h, lanIfaceEtc)
	}
	return strings.TrimSpace(out), nil
}

func portClose(s Service, r portReq, h string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	iface, err := ifaceName(ctx, h, r.Iface)
	if err != nil {
		return err
	}
	out, err := remoteOut(ctx, h, true, portLsScript)
	if err != nil {
		if sudoNeedsPassword(err) {
			fmt.Fprint(os.Stderr, portNeedsRootMsg(h))
			return errors.New("port close needs root")
		}
		return fmt.Errorf("%s: listing open ports: %v", h, err)
	}
	es, err := parseNftSetJSON(out)
	if err != nil {
		return fmt.Errorf("%s: %v", h, err)
	}
	ts := closeTargets(es, r, iface)
	if len(ts) == 0 {
		return fmt.Errorf("%s: nothing open for %s on %s (or already expired); see cnt port ls", h, portDesc(s, r), iface)
	}
	return remote(h, true, portCloseScript(s, r, iface, ts))
}

func portDesc(s Service, r portReq) string {
	from := "all"
	if len(r.From) > 0 {
		from = strings.Join(r.From, ",")
	}
	return fmt.Sprintf("svc=%s %d/%s from=%s", s.Name, r.Port, r.Proto, from)
}

// portGuards runs the inventory-side checks. It returns a message to print
// and stop with (declared), or an error.
func portGuards(s Service, r portReq, host string, svcs map[string]Service) (string, error) {
	if !r.Closer {
		if s.Net.Private {
			// ROUTING-PLAN §8 step 5: the app is in its own netns, so a host
			// port opens nothing. Declare a tcp/udp route (DNAT) instead.
			return "", fmt.Errorf("%s has net.private: a host port doesn't reach it; declare a tcp/udp route (DNAT) instead", s.Name)
		}
		if b := backendOf(svcs, host, r.Port, r.Proto); b != "" && !r.Force {
			return "", fmt.Errorf("%d/%s is the http backend of %s on %s; nginx must stay the only way in (--force-backend to override)", r.Port, r.Proto, b, host)
		}
		if declaredOpen(s, r.Port, r.Proto) {
			return fmt.Sprintf("%s %d/%s: already open (declared)", s.Name, r.Port, r.Proto), nil
		}
	}
	return "", nil
}

func cmdPort(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: cnt port open|ls|close ...")
	}
	switch args[0] {
	case "ls", "list":
		return cmdPortLs(args[1:])
	case "open", "close":
	default:
		return fmt.Errorf("cnt port: unknown subcommand %q (open, ls, close)", args[0])
	}
	closing := args[0] == "close"
	loadInventory()
	r, err := parsePortArgs(args[1:], closing, inv.Hosts)
	if err != nil {
		return err
	}
	s := service(r.Svc)
	f := flags{vals: map[string]string{}}
	if r.Host != "" {
		f.vals["host"] = r.Host
	}
	h, _ := hostFor(s, f)
	msg, err := portGuards(s, r, h, inv.Services)
	if err != nil {
		return err
	}
	if msg != "" {
		fmt.Println(msg)
		return nil
	}
	if r.Iface == "any" && !closing {
		fmt.Fprintln(os.Stderr, "warning: --iface any opens the port on every interface (LAN and, on hosts with one, WAN)")
	}
	if closing {
		if dryRun {
			fmt.Printf("[%s (root)] %s\n# then delete every element of %s on --iface %s found in cnt-tmp/cnt-tmp4/cnt-tmp6 (comment svc=%s)\n", h, portLsScript, portDesc(s, r), r.Iface, s.Name)
			return nil
		}
		return portClose(s, r, h)
	}
	return remote(h, true, portOpenScript(s, r))
}

// ---------------------------------------------------------------- port ls

type portEntry struct {
	Set, Iface, Proto, Port, From, Svc string
	Expires                            time.Duration
}

// parseNftSetJSON parses `nft -j list set` output (one or more JSON
// documents, one per line).
func parseNftSetJSON(out string) ([]portEntry, error) {
	var es []portEntry
	dec := json.NewDecoder(strings.NewReader(out))
	for dec.More() {
		var doc struct {
			Nftables []map[string]json.RawMessage `json:"nftables"`
		}
		if err := dec.Decode(&doc); err != nil {
			return nil, fmt.Errorf("bad nft json: %v", err)
		}
		for _, obj := range doc.Nftables {
			raw, ok := obj["set"]
			if !ok {
				continue
			}
			var set struct {
				Name string            `json:"name"`
				Elem []json.RawMessage `json:"elem"`
			}
			if err := json.Unmarshal(raw, &set); err != nil {
				return nil, err
			}
			for _, el := range set.Elem {
				var w struct {
					Elem struct {
						Val     struct{ Concat []json.RawMessage } `json:"val"`
						Expires float64                            `json:"expires"`
						Comment string                             `json:"comment"`
					} `json:"elem"`
				}
				if err := json.Unmarshal(el, &w); err != nil || len(w.Elem.Val.Concat) < 3 {
					continue
				}
				parts := make([]string, len(w.Elem.Val.Concat))
				for i, c := range w.Elem.Val.Concat {
					parts[i] = nftValue(c)
				}
				e := portEntry{Set: set.Name, Iface: parts[0], Proto: parts[1], Port: parts[2], From: "all",
					Svc: strings.TrimPrefix(w.Elem.Comment, "svc="), Expires: time.Duration(w.Elem.Expires) * time.Second}
				if len(parts) > 3 {
					e.From = parts[3]
				}
				es = append(es, e)
			}
		}
	}
	return es, nil
}

// nftValue renders a concat member: string, number, prefix or range.
func nftValue(m json.RawMessage) string {
	var s string
	if json.Unmarshal(m, &s) == nil {
		return s
	}
	var n json.Number
	if json.Unmarshal(m, &n) == nil {
		return n.String()
	}
	var p struct {
		Prefix *struct {
			Addr string `json:"addr"`
			Len  int    `json:"len"`
		} `json:"prefix"`
		Range []json.RawMessage `json:"range"`
	}
	if json.Unmarshal(m, &p) == nil {
		if p.Prefix != nil {
			return fmt.Sprintf("%s/%d", p.Prefix.Addr, p.Prefix.Len)
		}
		if len(p.Range) == 2 {
			return nftValue(p.Range[0]) + "-" + nftValue(p.Range[1])
		}
	}
	return string(m)
}

func portLsTable(host string, es []portEntry) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tSVC\tPORT\tIFACE\tFROM\tEXPIRES")
	sort.SliceStable(es, func(i, j int) bool {
		if es[i].Svc != es[j].Svc {
			return es[i].Svc < es[j].Svc
		}
		return es[i].Port < es[j].Port
	})
	for _, e := range es {
		fmt.Fprintf(w, "%s\t%s\t%s/%s\t%s\t%s\t%s\n", host, dash(e.Svc), e.Port, e.Proto, e.Iface, e.From, e.Expires)
	}
	w.Flush()
	return b.String()
}

const portLsScript = `for s in cnt-tmp cnt-tmp4 cnt-tmp6; do nft -j list set inet nixos-fw "$s" || exit 1; echo; done`

func cmdPortLs(args []string) error {
	f := parse(args)
	loadInventory()
	hosts := f.pos
	if len(hosts) == 0 {
		hosts = containerHosts()
	}
	var failed []string
	for _, h := range hosts {
		if dryRun {
			fmt.Printf("[%s (root)] %s\n", h, portLsScript)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		out, err := remoteOut(ctx, h, true, portLsScript)
		cancel()
		if err != nil {
			if sudoNeedsPassword(err) {
				fmt.Fprint(os.Stderr, portNeedsRootMsg(h))
			} else {
				fmt.Fprintf(os.Stderr, "%s: %v\n", h, err)
			}
			failed = append(failed, h)
			continue
		}
		es, err := parseNftSetJSON(out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", h, err)
			failed = append(failed, h)
			continue
		}
		if len(es) == 0 {
			fmt.Printf("%s: no temporary ports open\n", h)
			continue
		}
		fmt.Print(portLsTable(h, es))
	}
	if len(failed) > 0 {
		return fmt.Errorf("could not list: %s", strings.Join(failed, ", "))
	}
	return nil
}

// portNeedsRootMsg mirrors audit's needsRootMsg: `sudo -n` over plain ssh
// can't prompt for a password.
func portNeedsRootMsg(h string) string {
	return fmt.Sprintf(`%[1]s: cnt port needs root and sudo there wants a password (plain ssh has no TTY to prompt).
  Run it on %[1]s itself (sudo cnt port ...), or use ssh as root / passwordless sudo for %[1]s.
`, h)
}
