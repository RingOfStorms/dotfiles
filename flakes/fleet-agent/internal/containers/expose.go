package containers

// `cnt expose` (ROUTING-PLAN.md §5.3, §8 step 7): change one http route's
// exposure on its host for a while, without a commit or a rebuild.
//
// Host-local, so only what the host itself enforces can change: the
// generated vhost (ACL include, edge server). Targets are tailnet and lan.
// public is refused until fleet-edge on h005 can add the public CNAME and
// o002 its vhost at runtime (both are build-time today); see the plan.
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
//   - fleet-containers-expose-expire.service (host module) runs
//     `containers expose-expire --all` at boot, before nginx, and every
//     minute from a timer, so a reboot or a lost transient timer can delay
//     a revert by at most a minute.
//
// expose-expire puts baseline.conf back (nginx -t; on failure the site is
// removed: fail closed), reloads nginx and deletes the override. `cnt
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
var exposeLevels = map[string]bool{"tailnet": true, "lan": true}

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
// unless publicWithoutAuth (kept here although public is refused for now,
// so lifting that refusal can't skip it).
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
	if str(r.Zone) == "private" {
		return s, fmt.Errorf("%s is in the private zone (served by h005), not by its host", where)
	}
	if level == "public" {
		if str(r.Auth) == "none" && !r.PublicWithoutAuth {
			return s, fmt.Errorf("%s: public with auth none needs publicWithoutAuth in service.nix", where)
		}
		return s, errors.New("expose to public needs fleet-edge (public DNS on h005) and o002 (edge vhost) at runtime; not built yet (ROUTING-PLAN §8 step 7). Use tailnet or lan")
	}
	if !exposeLevels[level] {
		return s, fmt.Errorf("exposure %q: want tailnet or lan", level)
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
	b.WriteString("[ -e /etc/systemd/system/fleet-containers-expose-expire.service ] || { echo 'this host lacks cnt expose support (rebuild with the current containers host module)' >&2; exit 1; }\n")
	fmt.Fprintf(&b, "d=%s\n", q(d))
	fmt.Fprintf(&b, "if [ -e \"$d/override.json\" ] && ! grep -q %s \"$d/override.json\"; then echo %s >&2; exit 1; fi\n",
		q(`"route":"`+o.Route+`"`), q(s.Name+" already has an override on another route; cnt expose --revoke "+s.Name+" first"))
	b.WriteString("install -d -m755 " + q(overridesDir) + " \"$d\"\n")
	fmt.Fprintf(&b, "now=$(date +%%s); until=$((now + %d)); by=${SUDO_USER:-$(id -un)}\n", secs)
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
	fmt.Fprintf(&b, "systemd-run --quiet --unit=%s --on-active=%ds --timer-property=AccuracySec=1s /run/current-system/sw/bin/systemctl start fleet-containers-expose-expire.service\n", u, secs+1)
	fmt.Fprintf(&b, "logger -t cnt-expose \"expose %s.%s %s (baseline %s) for %ds by=$by\"\n", s.Name, o.Route, o.Exposure, o.Baseline, secs)
	fmt.Fprintf(&b, "echo \"%s.%s is %s until $(date -d @$until '+%%F %%T %%Z') (baseline %s)\"\n", s.Name, o.Route, o.Exposure, o.Baseline)
	return b.String()
}

// revokeScript runs expose-expire now (it ignores the deadline with --now).
func revokeScript(svc string) string {
	return fmt.Sprintf("set -eu\n[ -e %s ] || { echo 'no override for %s'; exit 0; }\n/run/current-system/sw/bin/containers expose-expire --now %s\n",
		q(overridesDir+"/"+svc+"/override.json"), svc, svc)
}

// dropOverrideScript is used by deploy/destroy: service.nix wins. It must
// run only AFTER the site from service.nix is live (deploy) or the site is
// gone (destroy): dropped earlier, a failed or interrupted site step would
// leave the widened site behind with nothing left to expire it.
func dropOverrideScript(svc string) string {
	return fmt.Sprintf(`! [ -d %[1]s ] || { echo 'dropping the cnt expose override of %[2]s (service.nix wins)' >&2; rm -rf %[1]s; systemctl stop %[3]s.timer 2>/dev/null || true; }
`, q(overridesDir+"/"+svc), svc, overrideUnit(svc))
}

const overridesListScript = `for f in /var/lib/fleet-containers/overrides/*/override.json; do [ -e "$f" ] && { cat "$f"; echo; }; done; true`

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
			time.Unix(o.Until, 0).Local().Format("2006-01-02 15:04:05"), o.left(now), dash(o.By), dash(o.Reason))
	}
	w.Flush()
	return b.String()
}

// fetchOverrides reads active overrides from hosts (best effort: an
// unreachable host is reported on stderr and skipped).
func fetchOverrides(hosts []string) []override {
	var all []override
	for _, h := range hosts {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		out, err := remoteOut(ctx, h, false, overridesListScript)
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: overrides unknown: %v\n", h, err)
			continue
		}
		all = append(all, parseOverrides(out, h)...)
	}
	return all
}

func cmdExpose(args []string) error {
	f := parse(args, "list", "yes")
	loadInventory()
	if f.bools["list"] {
		hosts := f.pos
		if len(hosts) == 0 {
			hosts = containerHosts()
		}
		ovs := fetchOverrides(hosts)
		if len(ovs) == 0 {
			fmt.Println("no active overrides")
			return nil
		}
		fmt.Print(overridesTable(ovs, time.Now()))
		return nil
	}
	if v := f.vals["revoke"]; v != "" {
		s := service(v)
		return remote(hostFor(s, f), true, revokeScript(s.Name))
	}
	if len(f.pos) < 1 {
		return errors.New("usage: cnt expose <svc>[.<route>] --exposure tailnet|lan --for DUR [--reason TEXT] | --list [host...] | --revoke <svc>")
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
		return errors.New("--exposure tailnet|lan is required")
	}
	d, err := parseFor(f.vals["for"])
	if err != nil {
		return err
	}
	if d > exposeMaxFor {
		return errors.New("--for: at most 24h")
	}
	o, err := exposeCheck(s, route, level)
	if err != nil {
		return err
	}
	if !needsHostVhost(s) {
		return fmt.Errorf("%s has no host vhost to override", s.Name)
	}
	h := hostFor(s, f)
	head := "# managed by containers, service " + s.Name + " (generated from routes)\n"
	baseline := head + routesVhost(s)
	conf := head + fmt.Sprintf("# cnt expose override: route %s %s -> %s (see %s/%s)\n", route, s.Routes[route].Exposure, level, overridesDir, s.Name) + routesVhost(o)
	ov := override{Service: s.Name, Route: route, Exposure: level, Baseline: s.Routes[route].Exposure, Reason: f.vals["reason"]}
	if level == "lan" {
		fmt.Fprintln(os.Stderr, "note: LAN DNS (h005) is build-time; LAN clients without tailnet DNS need the host's LAN IP for this name")
	}
	info("%s.%s on %s: %s -> %s for %s", s.Name, route, h, ov.Baseline, level, d)
	return remote(h, true, exposeScript(s, ov, int(d.Seconds()), baseline, conf))
}

// ------------------------------------------------- host side: expose-expire

// runCmd runs a host command (var for tests).
var runCmd = func(name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	return c.Run()
}

// cmdExposeExpire runs on the host (timer, boot/minute sweep, revoke):
// `expose-expire [--now] <svc>` or `expose-expire --all`.
func cmdExposeExpire(args []string) error {
	f := parse(args, "all", "now")
	now := time.Now()
	var svcs []string
	if f.bools["all"] {
		m, _ := filepath.Glob(filepath.Join(overridesDir, "*", "override.json"))
		for _, p := range m {
			svcs = append(svcs, filepath.Base(filepath.Dir(p)))
		}
	} else if len(f.pos) == 1 && svcNameRe.MatchString(f.pos[0]) {
		svcs = f.pos
	} else {
		return errors.New("usage: containers expose-expire [--now] <svc> | --all")
	}
	var errs []string
	for _, s := range svcs {
		if err := expireOne(s, now, f.bools["now"]); err != nil {
			errs = append(errs, s+": "+err.Error())
		}
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// expireOne reverts svc's override if it is due (or force). A missing or
// unreadable override.json counts as due: the dir only exists while an
// override is being applied or is active, so garbage fails closed.
func expireOne(svc string, now time.Time, force bool) error {
	d := filepath.Join(overridesDir, svc)
	if _, err := os.Stat(d); err != nil {
		return nil
	}
	var o override
	if b, err := os.ReadFile(filepath.Join(d, "override.json")); err == nil && json.Unmarshal(b, &o) == nil && o.Until > 0 {
		if !force && now.Unix() < o.Until {
			return nil
		}
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
	if err := os.RemoveAll(d); err != nil {
		return err
	}
	// --no-block: this runs inside fleet-containers-expose-expire.service,
	// which is ordered Before=nginx (boot), so a blocking reload would wait
	// on a job that waits for us (deadlock, seen on h001 2026-10-22). Queued,
	// the reload runs right after; at boot try-reload is a no-op and nginx
	// starts with the reverted file.
	_ = runCmd("systemctl", "--no-block", "try-reload-or-restart", "nginx.service")
	_ = runCmd("logger", "-t", "cnt-expose", "reverted "+svc+"."+o.Route+" to "+dash(o.Baseline)+" (until "+strconv.FormatInt(o.Until, 10)+")")
	fmt.Printf("%s: override reverted to service.nix (%s.%s %s)\n", svc, svc, dash(o.Route), dash(o.Baseline))
	return ret
}
