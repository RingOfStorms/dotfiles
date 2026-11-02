package containers

// `cnt expose`: change one http route's
// exposure on its host for a while, without a commit or a rebuild.
//
// tailnet and lan are host-local: only the generated vhost (ACL include)
// changes. public also needs h005 (fleet-edge-overrides: public CNAME) and
// o002 (runtime vhost); the order and the API are in edgeapi.go.
// until = 0 means forever (public only): no
// timer, never swept; --revoke or a deploy ends it.
//
// State, per service, on the service's host:
//
//	/var/lib/fleet-containers/overrides/<svc>/override.json  what, until (unix), by, reason
//	/var/lib/fleet-containers/overrides/<svc>/baseline.conf  the vhost from service.nix
//
// One override per service at a time. Expiry is enforced on the host, never
// by the CLI remembering it:
//
//   - a transient timer (systemd-run --on-active, unit fleet-expose-<svc>)
//     starts the sweep unit one second after the deadline;
//   - fleet-containers-expose-boot.service (host module) runs
//     `containers expose-expire --boot --all` before nginx: files only, no
//     reload (nginx starts with them);
//   - fleet-containers-expose-expire.service (NOT ordered before nginx)
//     runs `containers expose-expire --all` every minute and from the
//     deadline timer: checked, blocking nginx -t + reload. A reverted file
//     sets overrides/.reload-pending first; it is cleared only after that
//     reload, and every sweep/revoke retries it (fails while pending).
//
// expose-expire puts baseline.conf back (nginx -t; on failure the site is
// removed: fail closed), reloads nginx and deletes the override; until
// that reload succeeds the dir stays with override.json renamed to
// `reverted`, so `--reset` keeps retrying instead of reporting clean. `cnt
// deploy` of the service drops its override, but only once the site from
// service.nix has passed nginx -t and the reload (service.nix wins); if
// that fails the override and its timer stay, so expiry still narrows it.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

var overridesDir = "/var/lib/fleet-containers/overrides" // var for tests
var svcNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)

const exposeMaxFor = 24 * time.Hour

// exposeLevels a route may be overridden to (host-local only).
var exposeLevels = map[string]bool{"tailnet": true, "lan": true, "public": true}

// publicDefaultFor is --for when omitted for public (any duration or
// "forever" is allowed there; h005 owns the expiry).
const publicDefaultFor = 8 * time.Hour

var exposeRank = map[string]int{"local": 0, "tailnet": 1, "lan": 2, "public": 3}

type override struct {
	Service  string `json:"service"`
	Route    string `json:"route"`
	Exposure string `json:"exposure"`
	Baseline string `json:"baseline"`
	At       int64  `json:"at"`
	Until    int64  `json:"until"`
	By       string `json:"by"`
	Reason   string `json:"reason"`
	Host     string `json:"-"`
}

// splitTarget parses "svc", "svc.route" or "svc/route".
func splitTarget(t string) (string, string) {
	if i := strings.IndexAny(t, "./"); i >= 0 {
		return t[:i], t[i+1:]
	}
	return t, ""
}

// pickRoute resolves the route name: given, or the service's only http route.
func pickRoute(s Service, route string) (string, error) {
	if route != "" {
		if _, ok := s.Routes[route]; !ok {
			return "", fmt.Errorf("%s has no route %q (routes: %s)", s.Name, route, strings.Join(sortedRouteNames(s), ", "))
		}
		return route, nil
	}
	var http []string
	for _, n := range sortedRouteNames(s) {
		if s.Routes[n].Proto == "http" {
			http = append(http, n)
		}
	}
	if len(http) != 1 {
		return "", fmt.Errorf("%s: name the route (%s.<route>); http routes: %s", s.Name, s.Name, dash(strings.Join(http, ", ")))
	}
	return http[0], nil
}

// exposeCheck validates an override and returns the service as it would be
// with it applied. Same safety rules as lib.nix: no public without auth
// unless publicWithoutAuth. h005 re-checks all of it (overrides.Check).
func exposeCheck(s Service, route, level string) (Service, error) {
	r, ok := s.Routes[route]
	if !ok {
		return s, fmt.Errorf("%s has no route %q", s.Name, route)
	}
	where := s.Name + "." + route
	if r.Proto != "http" {
		return s, fmt.Errorf("%s: only http routes can be exposed for now (tcp/udp DNAT is build-time per exposure)", where)
	}
	if r.Exposure == "local" {
		return s, fmt.Errorf("%s is exposure = local in service.nix; that is a decision, not a default to widen at runtime", where)
	}
	if !exposeLevels[level] {
		return s, fmt.Errorf("exposure %q: want tailnet, lan or public", level)
	}
	if level == "public" {
		if str(r.Auth) == "none" && !r.PublicWithoutAuth {
			return s, fmt.Errorf("%s: public with auth none needs publicWithoutAuth in service.nix", where)
		}

		if len(r.Via) > 0 && !(len(r.Via) == 1 && r.Via[0] == "edge") {
			return s, fmt.Errorf("%s: via %v; public expose only goes through the edge", where, r.Via)
		}
	}
	if level == r.Exposure {
		return s, fmt.Errorf("%s is already %s in service.nix (cnt expose --revoke %s drops an override)", where, level, s.Name)
	}
	if exposeRank[level] < exposeRank[r.Exposure] {
		return s, fmt.Errorf("%s: expose only widens (%s -> %s would cut current clients); change service.nix to narrow", where, r.Exposure, level)
	}
	o := s
	o.Routes = map[string]Route{}
	for k, v := range s.Routes {
		o.Routes[k] = v
	}
	r.Exposure = level
	if level == "public" {
		r.Via = []string{"edge"} // lib.nix default for public http
	}
	o.Routes[route] = r
	if err := validateRoutes(o); err != nil {
		return s, err
	}
	return o, nil
}

func overrideUnit(svc string) string { return "fleet-expose-" + svc }

// exposeScript is the root script on the host. Order (fail closed): the
// override file first (so the boot/minute sweep reverts even if a later
// step dies), then the site (nginx -t, rollback = drop the override), then
// the exact-time timer.
func exposeScript(s Service, o override, secs int, baseline, conf string) string {
	var b strings.Builder
	d := overridesDir + "/" + s.Name
	b.WriteString("set -eu\n")
	b.WriteString(installedCheck(s))
	b.WriteString("[ -e /etc/systemd/system/fleet-containers-expose-boot.service ] || { echo 'this host lacks cnt expose support (rebuild with the current containers host module)' >&2; exit 1; }\n")
	fmt.Fprintf(&b, "d=%s\n", q(d))
	fmt.Fprintf(&b, "if [ -e \"$d/override.json\" ] && ! grep -q %s \"$d/override.json\"; then echo %s >&2; exit 1; fi\n",
		q(`"route":"`+o.Route+`"`), q(s.Name+" already has an override on another route; cnt expose --revoke "+s.Name+" first"))
	b.WriteString("install -d -m755 " + q(overridesDir) + " \"$d\"\n")
	if o.Until > 0 {
		fmt.Fprintf(&b, "now=$(date +%%s); until=%d; [ \"$until\" -gt \"$now\" ] || exit 0; by=${SUDO_USER:-$(id -un)}\n", o.Until)
	} else if secs == 0 {
		b.WriteString("now=$(date +%s); until=0; by=${SUDO_USER:-$(id -un)}\n")
	} else {
		fmt.Fprintf(&b, "now=$(date +%%s); until=$((now + %d)); by=${SUDO_USER:-$(id -un)}\n", secs)
	}
	fmt.Fprintf(&b, "printf %%s %s > \"$d/baseline.conf\"\n", q(baseline))
	// JSON by hand: every field except by/at/until is CLI-validated
	// (names, enum, reason via json.Marshal).
	reason, _ := json.Marshal(o.Reason)
	fmt.Fprintf(&b, "printf '{\"service\":\"%s\",\"route\":\"%s\",\"exposure\":\"%s\",\"baseline\":\"%s\",\"at\":%%s,\"until\":%%s,\"by\":\"%%s\",\"reason\":%%s}\\n' \"$now\" \"$until\" \"$by\" %s > \"$d/override.json.new\"\n",
		s.Name, o.Route, o.Exposure, o.Baseline, q(string(reason)))
	// A re-expose replaces a live override: keep the old one so a rejected
	// site (which restores the previous, still widened, file) keeps its
	// expiry state instead of losing it.
	b.WriteString("rm -f \"$d/override.json.old\"; [ ! -e \"$d/override.json\" ] || cp -p \"$d/override.json\" \"$d/override.json.old\"\n")
	b.WriteString("mv -f \"$d/override.json.new\" \"$d/override.json\"\n")
	b.WriteString("(\n" + nginxSiteScript(nginxDir, s.Name, conf) + ") || { if [ -e \"$d/override.json.old\" ]; then mv -f \"$d/override.json.old\" \"$d/override.json\"; else rm -rf \"$d\"; fi; exit 1; }\n")
	b.WriteString("rm -f \"$d/override.json.old\"\n")
	u := overrideUnit(s.Name)
	fmt.Fprintf(&b, "systemctl stop %[1]s.timer %[1]s.service 2>/dev/null || true\nsystemctl reset-failed %[1]s.timer %[1]s.service 2>/dev/null || true\n", u)
	if secs == 0 {
		fmt.Fprintf(&b, "logger -t cnt-expose \"expose %s.%s %s (baseline %s) forever by=$by\"\n", s.Name, o.Route, o.Exposure, o.Baseline)
		fmt.Fprintf(&b, "echo \"%s.%s is %s with no expiry (baseline %s; cnt expose --revoke %s ends it)\"\n", s.Name, o.Route, o.Exposure, o.Baseline, s.Name)
		return b.String()
	}
	if o.Until > 0 {
		fmt.Fprintf(&b, "systemd-run --quiet --unit=%s --on-active=\"$((until - $(date +%%s) + 1))s\" --timer-property=AccuracySec=1s /run/current-system/sw/bin/systemctl start fleet-containers-expose-expire.service\n", u)
	} else {
		fmt.Fprintf(&b, "systemd-run --quiet --unit=%s --on-active=%ds --timer-property=AccuracySec=1s /run/current-system/sw/bin/systemctl start fleet-containers-expose-expire.service\n", u, secs+1)
	}
	fmt.Fprintf(&b, "logger -t cnt-expose \"expose %s.%s %s (baseline %s) for %ds by=$by\"\n", s.Name, o.Route, o.Exposure, o.Baseline, secs)
	fmt.Fprintf(&b, "echo \"%s.%s is %s until $(date -d @$until '+%%F %%T %%Z') (baseline %s)\"\n", s.Name, o.Route, o.Exposure, o.Baseline)
	return b.String()
}

// revokeScript runs expose-expire now (it ignores the deadline with --now).
func revokeScript(svc string) string {
	return fmt.Sprintf("set -eu\n[ -e %s ] || [ -e %s ] || [ -e %s ] || { echo 'no override for %s'; exit 0; }\n/run/current-system/sw/bin/containers expose-expire --now %s\n",
		q(overridesDir+"/"+svc+"/override.json"), q(overridesDir+"/"+svc), q(overridesDir+"/.reload-pending"), svc, svc)
}

// dropOverrideScript is used by deploy/destroy: service.nix wins. It must
// run only AFTER the site from service.nix is live (deploy) or the site is
// gone (destroy): dropped earlier, a failed or interrupted site step would
// leave the widened site behind with nothing left to expire it.
func dropOverrideScript(svc string) string {
	return fmt.Sprintf(`! [ -d %[1]s ] || { echo 'dropping the cnt expose override of %[2]s (service.nix wins)' >&2; rm -rf %[1]s; systemctl stop %[3]s.timer 2>/dev/null || true; }
`, q(overridesDir+"/"+svc), svc, overrideUnit(svc))
}

const overridesListScript = `for f in /var/lib/fleet-containers/overrides/*/override.json; do [ -e "$f" ] && { cat "$f"; echo; }; done; for f in /var/lib/fleet-containers/overrides/*/reverted; do [ -e "$f" ] && { f=${f%/reverted}; echo "REVERTED ${f##*/}"; }; done; [ ! -e /var/lib/fleet-containers/overrides/.reload-pending ] || echo RELOAD-PENDING; true`

// reloadPendingLine marks a host whose nginx still owes the revert reload.
const reloadPendingLine = "RELOAD-PENDING"

// revertedPrefix starts a line naming a service whose override files were
// reverted but whose reload has not succeeded yet (the orphan dir is kept
// until it has).
const revertedPrefix = "REVERTED "

// hostOverrideState is one host's override listing.
type hostOverrideState struct {
	Overrides []override
	Pending   bool     // .reload-pending: nginx may still serve a reverted (wider) vhost
	Reverted  []string // services reverted on disk, reload not yet done
}

func parseHostOverrides(out, host string) hostOverrideState {
	st := hostOverrideState{Overrides: parseOverrides(out, host), Pending: hasReloadPending(out)}
	for _, l := range strings.Split(out, "\n") {
		if s, ok := strings.CutPrefix(strings.TrimSpace(l), revertedPrefix); ok && svcNameRe.MatchString(s) {
			st.Reverted = append(st.Reverted, s)
		}
	}
	return st
}

// owesReload reports whether svc's revert may not be live in nginx yet:
// the host's reload is pending and svc's orphan dir is there, or no orphan
// dir names anyone (an older agent that deleted the dir first).
func (st hostOverrideState) owesReload(svc string) bool {
	return st.Pending && (len(st.Reverted) == 0 || slices.Contains(st.Reverted, svc))
}

func parseOverrides(out, host string) []override {
	var ovs []override
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if !strings.HasPrefix(l, "{") {
			continue
		}
		var o override
		if json.Unmarshal([]byte(l), &o) == nil && o.Service != "" {
			o.Host = host
			ovs = append(ovs, o)
		}
	}
	return ovs
}

func (o override) left(now time.Time) string {
	if o.Until == 0 {
		return "forever"
	}
	d := time.Unix(o.Until, 0).Sub(now).Round(time.Second)
	if d <= 0 {
		return "expired (revert pending)"
	}
	return d.String()
}

func overridesTable(ovs []override, now time.Time) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tSERVICE\tROUTE\tEXPOSURE\tBASELINE\tUNTIL\tLEFT\tBY\tREASON")
	sort.SliceStable(ovs, func(i, j int) bool { return ovs[i].Host+ovs[i].Service < ovs[j].Host+ovs[j].Service })
	for _, o := range ovs {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", o.Host, o.Service, o.Route, o.Exposure, o.Baseline,
			untilStr(o.Until), o.left(now), dash(o.By), dash(o.Reason))
	}
	w.Flush()
	return b.String()
}

func untilStr(u int64) string {
	if u == 0 {
		return "never"
	}
	return time.Unix(u, 0).Local().Format("2006-01-02 15:04:05")
}

// fetchOverrides reads active overrides from hosts (best effort: an
// unreachable host is reported on stderr and skipped).
func fetchOverrides(hosts []string) []override {
	ovs, _ := fetchOverridesState(hosts)
	return ovs
}

// fetchOverridesState also returns hosts whose nginx still owes a revert
// reload (warned on stderr for every caller: routes, audit, move).
func fetchOverridesState(hosts []string) ([]override, []string) {
	var all []override
	var pending []string
	for _, h := range hosts {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		out, err := remoteOut(ctx, h, false, overridesListScript)
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: overrides unknown: %v\n", h, err)
			continue
		}
		all = append(all, parseOverrides(out, h)...)
		if hasReloadPending(out) {
			pending = append(pending, h)
			fmt.Fprintf(os.Stderr, "%s: reload pending: nginx may still serve a reverted (wider) vhost; the minute sweep retries (journalctl -u fleet-containers-expose-expire)\n", h)
		}
	}
	return all, pending
}

func hasReloadPending(out string) bool {
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimSpace(l) == reloadPendingLine {
			return true
		}
	}
	return false
}

func cmdExpose(args []string) error {
	f := parse(args, "list", "yes")
	loadInventory()
	if f.bools["list"] {
		hosts := f.pos
		if len(hosts) == 0 {
			hosts = containerHosts()
		}
		ovs, pending := fetchOverridesState(hosts)
		if len(ovs) == 0 {
			fmt.Println("no active host overrides")
		} else {
			fmt.Print(overridesTable(ovs, time.Now()))
		}
		for _, h := range pending {
			fmt.Printf("%s: reload pending (reverted files not yet live in nginx)\n", h)
		}
		if c, err := newEdgeClient(); err == nil {
			rows, v, err := c.list(true)
			if err != nil {
				fmt.Fprintf(os.Stderr, "h005: public overrides unknown: %v\n", err)
			} else if len(rows) > 0 {
				fmt.Println()
				fmt.Print(edgeTable(rows, v, time.Now()))
			}
			if err == nil {
				for _, l := range edgeLeftovers(ovs, rows, v) {
					fmt.Println("LEFTOVER " + l)
				}
			}
		}
		return nil
	}
	if v := f.vals["reset"]; v != "" {
		s := service(v)
		c, err := newEdgeClient()
		var api edgeAPI
		if err == nil {
			api = c
		}
		hosts := containerHosts()
		if h, _, herr := resolveHost(s, f); herr == nil && !slices.Contains(hosts, h) {
			hosts = append(hosts, h)
		}
		return exposeReset(api, err, s.Name, hosts, listHostOverrides,
			func(h string) error { return remote(h, true, revokeScript(s.Name)) })
	}
	if v := f.vals["revoke"]; v != "" {
		s := service(v)
		// h005 first (o002, then DNS), then the host. h005 down: the host
		// still closes (444 at :8443) and h005/o002 expire on their own.
		if c, err := newEdgeClient(); err == nil {
			if err := c.revoke(s.Name); err != nil {
				fmt.Fprintf(os.Stderr, "warning: h005: %v (its sweep and o002's expiry clean up; check cnt expose --list)\n", err)
			}
		} else if !errors.Is(err, errNoToken) {
			fmt.Fprintf(os.Stderr, "warning: h005: %v\n", err)
		}
		h, _ := hostFor(s, f)
		return remote(h, true, revokeScript(s.Name))
	}
	if len(f.pos) < 1 {
		return errors.New("usage: cnt expose <svc>[.<route>] --exposure tailnet|lan|public --for DUR|forever [--reason TEXT] | --list [host...] | --revoke <svc> | --reset <svc>")
	}
	svcName, route := splitTarget(f.pos[0])
	s := service(svcName)
	route, err := pickRoute(s, route)
	if err != nil {
		return err
	}
	level := f.vals["exposure"]
	if level == "" && len(f.pos) > 1 {
		level = f.pos[1]
	}
	if level == "" {
		return errors.New("--exposure tailnet|lan|public is required")
	}
	d, err := exposeFor(level, f.vals["for"])
	if err != nil {
		return err
	}
	o, err := exposeCheck(s, route, level)
	if err != nil {
		return err
	}
	if !needsHostVhost(s) {
		return fmt.Errorf("%s has no host vhost to override", s.Name)
	}
	h, _ := hostFor(s, f)
	baseline, conf := exposeSite(s, o, route, level)
	ov := override{Service: s.Name, Route: route, Exposure: level, Baseline: s.Routes[route].Exposure, Reason: f.vals["reason"]}
	forStr := d.String()
	if d == 0 {
		forStr = "ever (no expiry)"
	}
	info("%s.%s on %s: %s -> %s for %s", s.Name, route, h, ov.Baseline, level, forStr)
	script := exposeScript(s, ov, int(d.Seconds()), baseline, conf)
	if level != "public" {
		return remote(h, true, script)
	}
	c, err := newEdgeClient()
	if err != nil {
		return err
	}
	return exposePublic(c, s, route, h, d, f.vals["reason"], func() error { return remote(h, true, script) },
		func() error { return remote(h, true, revokeScript(s.Name)) })
}

// exposeSite renders the baseline (service.nix) and the widened site of an
// override of route to level; o is exposeCheck's result.
func exposeSite(s, o Service, route, level string) (baseline, conf string) {
	head := "# managed by containers, service " + s.Name + " (generated from routes)\n"
	baseline = head + routesVhost(s)
	conf = head + fmt.Sprintf("# cnt expose override: route %s %s -> %s (see %s/%s)\n", route, s.Routes[route].Exposure, level, overridesDir, s.Name) + routesVhost(o)
	return baseline, conf
}

// carryOverrideScript is what `cnt move` runs on the target to take the
// source's tailnet/lan override along: same route and level, until the same
// deadline (the time it had left, never longer). "" when there is nothing to
// carry: no override, a public one (move refuses those earlier), or one that
// has expired by now. An override service.nix no longer allows (the route
// changed under it) is an error, so the move can say why it was dropped.
func carryOverrideScript(s Service, ovs []override, now time.Time) (string, *override, error) {
	for _, o := range ovs {
		if o.Service != s.Name || (o.Exposure != "tailnet" && o.Exposure != "lan") {
			continue
		}
		left := o.Until - now.Unix()
		if o.Until == 0 || left <= 0 {
			return "", nil, nil // host-local overrides always expire; past it, nothing to carry
		}
		r, ok := s.Routes[o.Route]
		if !ok || r.Proto != "http" || r.Exposure == "local" {
			return "", &o, fmt.Errorf("%s.%s no longer permits an exposure override", s.Name, o.Route)
		}
		wide := s
		wide.Routes = make(map[string]Route, len(s.Routes))
		for name, route := range s.Routes {
			wide.Routes[name] = route
		}
		r.Exposure = o.Exposure
		r.Via = nil
		wide.Routes[o.Route] = r
		if err := validateRoutes(wide); err != nil {
			return "", &o, err
		}
		baseline, conf := exposeSite(s, wide, o.Route, o.Exposure)
		reason := strings.TrimSpace(o.Reason + " (carried by cnt move from " + o.Host + ")")
		carried := override{Service: s.Name, Route: o.Route, Exposure: o.Exposure, Baseline: s.Routes[o.Route].Exposure, Reason: reason, Until: o.Until}
		return exposeScript(s, carried, int(left), baseline, conf), &o, nil
	}
	return "", nil, nil
}

// carryOverride refuses source cleanup if the target cannot retain the override.
func carryOverride(s Service, ovs []override, to string) error {
	script, o, err := carryOverrideScript(s, ovs, time.Now())
	if err != nil {
		return err
	}
	if script == "" {
		return nil
	}
	info("carrying the expose override %s.%s %s to %s", s.Name, o.Route, o.Exposure, to)
	return remote(to, true, script)
}

// listHostOverrides reads one host's overrides; unlike fetchOverrides an
// unreachable host is an error (reset must not report "clean" for it).
func listHostOverrides(h string) (hostOverrideState, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := remoteOut(ctx, h, false, overridesListScript)
	if err != nil {
		return hostOverrideState{}, err
	}
	return parseHostOverrides(out, h), nil
}

// exposeReset clears every runtime exposure override of svc, wherever it
// is: the public row on h005 (DELETE through the fleet-edge override API:
// o002, then DNS), then the host-local override on every host that reports
// one (tailnet/lan/public; a stale copy after a move or a lost revoke
// included), plus any host h005's row names. A host whose revert of svc
// still owes the nginx reload is revoked again (the revoke retries the
// reload). Each step runs even if an earlier one failed; a final re-read
// proves nothing is left, a pending reload included. Returns an error
// naming whatever could not be cleared or checked.
func exposeReset(api edgeAPI, apiErr error, svc string, hosts []string, list func(string) (hostOverrideState, error), revokeHost func(string) error) error {
	var problems []string
	set := map[string]bool{}
	for _, h := range hosts {
		set[h] = true
	}
	edgeRows := func() []edgeRow {
		rows, _, err := api.list(false)
		if err != nil {
			problems = append(problems, "h005 list: "+err.Error())
			return nil
		}
		var mine []edgeRow
		for _, r := range rows {
			if r.Service == svc {
				mine = append(mine, r)
			}
		}
		return mine
	}
	if api == nil {
		if apiErr == nil {
			apiErr = errNoToken
		}
		problems = append(problems, "h005 not reachable through the override API: "+apiErr.Error())
	} else {
		for _, r := range edgeRows() {
			if r.Host != "" {
				set[r.Host] = true
			}
		}
		info("h005: removing the public override of %s (o002, then DNS)", svc)
		if err := api.revoke(svc); err != nil {
			problems = append(problems, "h005 revoke: "+err.Error())
		}
	}
	sorted := make([]string, 0, len(set))
	for h := range set {
		sorted = append(sorted, h)
	}
	sort.Strings(sorted)
	cleared := 0
	for _, h := range sorted {
		st, err := list(h)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: overrides unknown: %v", h, err))
			continue
		}
		what := ""
		for _, o := range st.Overrides {
			if o.Service == svc {
				what = fmt.Sprintf("%s.%s (%s, baseline %s)", svc, o.Route, o.Exposure, o.Baseline)
				break // one override dir per service per host; revoke clears it
			}
		}
		if what == "" && st.owesReload(svc) {
			what = svc + " (reverted, nginx reload pending)"
		}
		if what == "" {
			continue
		}
		info("%s: reverting %s", h, what)
		if err := revokeHost(h); err != nil {
			problems = append(problems, fmt.Sprintf("%s: revoke: %v", h, err))
		} else {
			cleared++
		}
	}
	// Verify: nothing for svc left on h005 or on any host that answered.
	if api != nil {
		for _, r := range edgeRows() {
			problems = append(problems, fmt.Sprintf("h005 still has %s.%s (%s on %s, %s)", r.Service, r.Route, r.State, r.Host, dash(r.LastError)))
		}
	}
	for _, h := range sorted {
		st, err := list(h)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: final override check: %v", h, err))
			continue
		}
		for _, o := range st.Overrides {
			if o.Service == svc {
				problems = append(problems, fmt.Sprintf("%s still has %s.%s %s", h, svc, o.Route, o.Exposure))
			}
		}
		if st.owesReload(svc) {
			problems = append(problems, fmt.Sprintf("%s: nginx reload still pending after reverting %s (it may still serve the wider vhost; journalctl -u fleet-containers-expose-expire)", h, svc))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("reset %s incomplete:\n  %s", svc, strings.Join(problems, "\n  "))
	}
	fmt.Printf("%s: no runtime exposure overrides left (h005 and %d host(s) checked, %d host override(s) reverted)\n", svc, len(sorted), cleared)
	return nil
}

// exposeFor parses --for. tailnet/lan: required, at most 24h. public:
// default 8h, any duration, or "forever" (0).
func exposeFor(level, v string) (time.Duration, error) {
	if level != "public" {
		d, err := parseFor(v)
		if err == nil && d > exposeMaxFor {
			err = errors.New("--for: at most 24h for tailnet/lan")
		}
		return d, err
	}
	switch v {
	case "":
		return publicDefaultFor, nil
	case "forever":
		return 0, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("--for %q: %v (or forever)", v, err)
	}
	if d < time.Minute {
		return 0, fmt.Errorf("--for %q: at least 1m for public", v)
	}
	return d, nil
}

// ------------------------------------------------- host side: expose-expire

// runCmd runs a host command (var for tests).
var runCmd = func(name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	return c.Run()
}

// reloadPendingFile is set (atomically) before a sweep or revoke touches
// any site file and removed only after a checked nginx -t + reload. While
// it exists nginx may still serve a wider vhost than the files say, so
// every runtime sweep/revoke retries the reload first and fails while it
// is pending. A sibling of the per-service dirs (the */override.json glob
// never sees it). The reverted service's dir stays too, override.json
// renamed to `reverted`, until that reload has succeeded: `cnt expose
// --reset` and the list see which service still owes it.
func reloadPendingFile() string { return filepath.Join(overridesDir, ".reload-pending") }

func reloadPending() bool {
	_, err := os.Stat(reloadPendingFile())
	return err == nil
}

func setReloadPending(why string) error {
	if err := os.MkdirAll(overridesDir, 0o755); err != nil {
		return err
	}
	p := reloadPendingFile()
	if err := os.WriteFile(p+".new", []byte(time.Now().UTC().Format(time.RFC3339)+" "+why+"\n"), 0o644); err != nil {
		return fmt.Errorf("writing reload marker: %w", err)
	}
	if err := os.Rename(p+".new", p); err != nil {
		return fmt.Errorf("writing reload marker: %w", err)
	}
	return nil
}

// flushReload runs the owed, checked reload. Blocking: it must only run
// from the runtime unit (not ordered before nginx) or an ssh revoke, never
// from the boot unit. try-reload-or-restart is a no-op (success) while
// nginx is stopped: then nothing serves the old site.
func flushReload() error {
	if !reloadPending() {
		return nil
	}
	if err := runCmd("nginx", "-t", "-c", "/etc/nginx/nginx.conf"); err != nil {
		return fmt.Errorf("reload pending: nginx -t: %v", err)
	}
	if err := runCmd("systemctl", "try-reload-or-restart", "nginx.service"); err != nil {
		return fmt.Errorf("reload pending: nginx reload: %v", err)
	}
	if err := clearReverted(); err != nil {
		return fmt.Errorf("reload pending: %v", err)
	}
	if err := os.Remove(reloadPendingFile()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("reload pending: clearing marker: %v", err)
	}
	return nil
}

// clearReverted drops the dirs of reverts that are live now (after a
// successful reload). A dir re-exposed meanwhile keeps its new override.
func clearReverted() error {
	m, _ := filepath.Glob(filepath.Join(overridesDir, "*", revertedFile))
	for _, p := range m {
		d := filepath.Dir(p)
		var err error
		if _, serr := os.Stat(filepath.Join(d, "override.json")); serr == nil {
			err = os.Remove(p)
		} else {
			err = os.RemoveAll(d)
		}
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("clearing reverted %s: %v", filepath.Base(d), err)
		}
	}
	return nil
}

// revertedFile marks an override dir whose site is back to the baseline on
// disk while the reload is still owed (override.json renamed to it).
const revertedFile = "reverted"

// cmdExposeExpire runs on the host:
//
//	expose-expire --boot --all       boot unit, Before=nginx: files only, never reloads
//	                                 (nginx starts with them; the marker stays for the runtime sweep)
//	expose-expire --all              runtime sweep (minute timer, transient deadline timer)
//	expose-expire [--now] <svc>      one service; --now = revoke
//
// Runtime mode retries an owed reload first, reverts what is due, then
// reloads (checked, blocking) and fails while the reload is still owed.
func cmdExposeExpire(args []string) error {
	f := parse(args, "all", "now", "boot")
	now := time.Now()
	boot := f.bools["boot"]
	var svcs []string
	if f.bools["all"] {
		m, _ := filepath.Glob(filepath.Join(overridesDir, "*", "override.json"))
		for _, p := range m {
			svcs = append(svcs, filepath.Base(filepath.Dir(p)))
		}
		// Dirs without override.json (interrupted apply) are due too.
		ds, _ := filepath.Glob(filepath.Join(overridesDir, "*"))
		for _, d := range ds {
			if fi, err := os.Stat(d); err == nil && fi.IsDir() && !slices.Contains(svcs, filepath.Base(d)) {
				svcs = append(svcs, filepath.Base(d))
			}
		}
		sort.Strings(svcs)
	} else if len(f.pos) == 1 && svcNameRe.MatchString(f.pos[0]) {
		svcs = f.pos
	} else {
		return errors.New("usage: containers expose-expire [--now] <svc> | [--boot] --all")
	}
	var errs []string
	if !boot {
		if err := flushReload(); err != nil {
			errs = append(errs, err.Error())
		}
	}
	for _, s := range svcs {
		if !svcNameRe.MatchString(s) {
			continue
		}
		if err := expireOne(s, now, f.bools["now"]); err != nil {
			errs = append(errs, s+": "+err.Error())
		}
	}
	if !boot && reloadPending() {
		if err := flushReload(); err != nil && !slices.Contains(errs, err.Error()) {
			errs = append(errs, err.Error())
		}
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// expireOne reverts svc's override files if it is due (or force). A
// missing or unreadable override.json counts as due: the dir only exists
// while an override is being applied or is active, so garbage fails
// closed. It never reloads: it sets the reload marker before touching the
// site, and the caller flushes it (runtime) or leaves it (boot). The dir
// stays, marked reverted, until that reload succeeds (clearReverted).
func expireOne(svc string, now time.Time, force bool) error {
	d := filepath.Join(overridesDir, svc)
	if _, err := os.Stat(d); err != nil {
		return nil
	}
	var o override
	ovFile := filepath.Join(d, "override.json")
	b, rerr := os.ReadFile(ovFile)
	if os.IsNotExist(rerr) {
		if _, err := os.Stat(filepath.Join(d, revertedFile)); err == nil {
			// Reverted on disk already; only the reload is owed.
			if reloadPending() {
				return nil
			}
			return setReloadPending("reverted " + svc)
		}
	}
	// until = 0 is forever, but only for a well-formed public override:
	// anything else without a deadline is garbage and fails closed.
	if rerr == nil && json.Unmarshal(b, &o) == nil && o.Service != "" {
		live := o.Until > 0 && now.Unix() < o.Until || o.Until == 0 && o.Exposure == "public"
		if !force && live {
			return nil
		}
	}
	if err := setReloadPending("revert " + svc); err != nil {
		return err
	}
	site := filepath.Join(nginxDir, svc+".conf")
	base, err := os.ReadFile(filepath.Join(d, "baseline.conf"))
	var ret error
	if err == nil {
		if err := os.WriteFile(site, base, 0o644); err != nil {
			return err
		}
		if runCmd("nginx", "-t", "-c", "/etc/nginx/nginx.conf") != nil {
			// The baseline no longer validates (host config changed?):
			// drop the site rather than keep the wider one.
			_ = os.WriteFile(site+".broken", base, 0o644)
			_ = os.Remove(site)
			ret = errors.New("baseline vhost failed nginx -t; site removed (redeploy the service)")
		}
	} else {
		_ = os.Remove(site)
		ret = errors.New("no baseline.conf; site removed (redeploy the service)")
	}
	if rerr == nil {
		if err := os.Rename(ovFile, filepath.Join(d, revertedFile)); err != nil {
			return err
		}
	} else if err := os.WriteFile(filepath.Join(d, revertedFile), nil, 0o644); err != nil {
		return err
	}
	_ = runCmd("logger", "-t", "cnt-expose", "reverted "+svc+"."+o.Route+" to "+dash(o.Baseline)+" (until "+strconv.FormatInt(o.Until, 10)+"); reload pending")
	fmt.Printf("%s: override reverted to service.nix (%s.%s %s)\n", svc, svc, dash(o.Route), dash(o.Baseline))
	return ret
}
