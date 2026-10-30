// containers: deploy, inspect and move floating services from containers.
//
// Everything runs over ssh against the fleet hosts; nothing has to be
// installed on the hosts besides the containers host module.
package containers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

const defaultRepo = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles"

type Service struct {
	Name        string            `json:"name"`
	Dir         string            `json:"dir"`
	Kind        string            `json:"kind"`
	Host        string            `json:"host"`
	Description string            `json:"description"`
	Persist     map[string]string `json:"persist"`
	TCPPorts    []int             `json:"tcpPorts"`
	UDPPorts    []int             `json:"udpPorts"`
	Nginx       *string           `json:"nginx"`
	BackupHook  string            `json:"backupHook"`
	Attach      string            `json:"attach"`
	Internet    *bool             `json:"internet"`
	Requires    []string          `json:"requires"`
	Routes      map[string]Route  `json:"routes"`
	Net         Net               `json:"net"`
}

// Net is lib.nix normalizeNet (ROUTING-PLAN §8 step 5). IP is the guest
// address when Private: 10.233.<index>.2 for kind = "nixos" (a per-service
// veth), or 10.89.250.<100+index> for kind = "podman" (a static --ip on the
// shared fleet-noinet bridge: .1 is the bridge/gateway and podman's dynamic
// IPAM hands out .2 upward, so static IPs start at .101 to stay clear).
type Net struct {
	Private bool     `json:"private"`
	Index   *int     `json:"index"`
	IP      *string  `json:"ip"`
	Uses    []string `json:"uses"`
	Egress  []string `json:"egress"`
}

// backendAddr is where the host reaches the service: its private IP (guest
// veth for nixos, static bridge IP for podman), or loopback on the host
// network for anything not on net.private.
func backendAddr(s Service) string {
	if s.Net.Private && s.Net.IP != nil {
		return *s.Net.IP
	}
	return "127.0.0.1"
}

type Host struct {
	User      string  `json:"user"`
	OverlayIP *string `json:"overlayIp"`
	LanIP     *string `json:"lanIp"`
	// Optional tailnet v6 (not in fleet.nix today; used by `cnt port --from`).
	OverlayIP6 *string `json:"overlayIp6"`
}

type Inventory struct {
	Services map[string]Service `json:"services"`
	Hosts    map[string]Host    `json:"hosts"`
	// Hosts with the containers host module; all are probed before the CLI
	// trusts the declared host.
	ContainerHosts []string `json:"containerHosts"`
	DataRoot       string   `json:"dataRoot"`
	// LanSubnet is the fleet LAN (fleet.nix global.lanSubnet), for `weblan`.
	LanSubnet string `json:"lanSubnet"`
}

var (
	repo    string
	inv     *Inventory
	sshUser string
	dryRun  bool
)

func usage() {
	fmt.Fprint(os.Stderr, `fleet containers - floating services from containers

usage: fleet containers [global flags] <command> [args]

commands:
  ls [--all]                   where each service runs, declared host vs actual
  status <svc> [--host h]      details: state, ports, nginx site, data dirs (what a backup holds)
| status [--all]          where each service runs, declared host vs actual
  watch [--all] [-n secs]      refreshing status view (q / ctrl-c to quit)
  logs <svc> [-n N] [--no-follow] [--host h] [--unit]
                               stream logs (inside the container; --unit = nspawn unit)
  deploy <svc> [--host h] [--local] [--rev REV] [--vhost-only]
                               deploy or update to the latest pushed definition
                               (--vhost-only: rewrite just the nginx site, no restart)
  start|stop|restart <svc> [--host h]
                               stop blocks until fully down and keeps it stopped
                               across reboots; start/restart/deploy re-enable it
  online <svc> [--for 30m] [--off] [--host h]
                               let an internet = false service reach the network
                               for a while (ends on timeout, restart or fw reload)
  attach <svc> [--host h]      open the service console (if it defines one)
  shell <svc> [--host h]       root shell inside the container
  backup <svc> [--host h] [-o file|dir] [--live] [-y]
                               asks where to save (default ~/backups) and, if the
                               service is running, whether to stop it; then hook,
                               stop, tar data to this machine, start again
  restore <svc> <file> --host h [--force]
                               unpack a backup into /srv/containers/<svc> on a host
  move <svc> --to h [--from h] [--force] [--resume-token T]
                               move through the restic repo: reserve h in the placement
                               registry first (a reservation another client holds stops
                               the move before any host is touched), final backup on the
                               source, restore on h, deploy + route health, restore check,
                               first backup on h, then commit the move and retire the
                               source (<svc>.moved-<date>). A failure before the commit
                               undoes h, drops the reservation and restarts the source,
                               but only while the move still owns the placement; a
                               taken-over or unconfirmable row leaves both hosts alone
                               (settle it with 'place <svc> --recover'). An interrupted
                               run resumes with the token saved under
                               $XDG_STATE_HOME/fleet-containers/moves (or --resume-token).
                               A registry that is configured but unreachable refuses the
                               move unless --force. Needs ringofstorms.containers.backup
                               on both hosts
  restore-check <svc> [--host h] [--snapshot ID]
                               restore a svc:<svc> snapshot (default latest) to a scratch
                               dir: SQLite integrity_check, PG dumps complete
  health <svc> [--host h]      check every route answers on its host (backend and nginx)
  destroy <svc> [--host h] [--purge] [--force]
                               remove from a host (data kept unless --purge). --host on a
                               host the registry does not bind removes that stray copy and
                               leaves the row; the bound copy needs --force (which also
                               removes the row), and so does a row a move still holds
  routes [svc]                 declared routes (fqdn, port, exposure, auth, host)
  audit [host...] [--stdin]    non-loopback listeners on hosts vs declared ports (read-only)
                               --stdin reads 'ss -ltnupH' output from stdin for one host
                               instead of ssh (when sudo there needs a password; plain
                               ssh has no TTY to prompt). Run on the host itself:
                                 sudo ss -ltnupH > /tmp/host.ss && cnt audit host --stdin < /tmp/host.ss
                               or collect with 'ssh -t'. Empty input is an error.
  port open <svc> <port>/<tcp|udp> --for DUR [--from host|cidr]... [--iface tailnet|lan|any]
            [--host h] [--force-backend]
                               open a port for a while (max 24h); nft set elements that the
                               kernel expires (no other state). --iface default tailnet
  port ls [host...]            temporarily open ports, their service and time left
  port close <svc> <port>/<proto> [--from ...] [--iface ...] [--host h]
                               close one early (same --from/--iface as the open)
  expose <svc>[.<route>] --exposure tailnet|lan|public --for DUR|forever [--reason TEXT] [--host h]
                               widen an http route for a while on its host; the host reverts it
                               at expiry (timer + boot/minute sweep). tailnet/lan: --for required,
                               max 24h. public (via fleet-edge on h005 + o002 runtime vhost):
                               default 8h, any duration or forever; signs with this machine's
                               root-only key (/machine-key.json), so: sudo fleet containers expose ...
                               (the cnt alias does not expand under sudo)
  expose --list [host...]      active overrides (also shown by routes and audit)
  expose --revoke <svc>        drop the override now (deploy drops it too)
  agent --listen ADDR [--host NAME]
                               read-only GET /status.json and /logs.json for fleet-edge
  check-idmap <host>           test idmapped mounts on /srv/containers and /nix
  inventory                    print the inventory JSON

status, logs, attach, shell, online and stop use this machine when the service
is installed here (no fleet probe; works on hosts that cannot ssh to the
others). start and restart follow the placement registry instead, so a leftover
copy on this machine cannot be started while the name is bound elsewhere.
Pass --host to act on a specific host.

global flags (or env):
  --repo URL    flake repo (CONTAINERS_REPO, default `+defaultRepo+`)
                use git+file:///path/to/checkout for local, unpushed work
  --ssh-user U  ssh as this user for every host (CONTAINERS_SSH_USER); default is
                the host's user in hosts/fleet.nix. Root work uses root@host
                when its keys work, else that user with sudo
  --dry-run     print remote commands instead of running them
`)
}

// Run executes a `fleet containers` subcommand with the given arguments.
func Run(args []string) {
	repo = envOr("CONTAINERS_REPO", defaultRepo)
	sshUser = os.Getenv("CONTAINERS_SSH_USER")
	for len(args) > 0 && strings.HasPrefix(args[0], "--") {
		switch args[0] {
		case "--repo":
			repo, args = need(args), args[2:]
		case "--ssh-user":
			sshUser, args = need(args), args[2:]
		case "--dry-run":
			dryRun, args = true, args[1:]
		case "--help":
			usage()
			return
		default:
			die("unknown flag %s", args[0])
		}
	}
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	cmd, rest := args[0], args[1:]
	var err error
	switch cmd {
	case "ls", "list":
		err = cmdStatus(rest, false)
	case "status", "info", "show":
		err = cmdDetail(rest)
	case "watch", "tui":
		err = cmdStatus(rest, true)
	case "logs", "log":
		err = cmdLogs(rest)
	case "deploy", "update":
		err = cmdDeploy(rest)
	case "start", "stop", "restart":
		err = cmdUnit(cmd, rest)
	case "online":
		err = cmdOnline(rest)
	case "attach":
		err = cmdAttach(rest, false)
	case "shell":
		err = cmdAttach(rest, true)
	case "backup":
		err = cmdBackup(rest)
	case "restore":
		err = cmdRestore(rest)
	case "move":
		err = cmdMove(rest)
	case "restore-check":
		err = cmdRestoreCheck(rest)
	case "health":
		err = cmdHealth(rest)
	case "destroy", "rm":
		err = cmdDestroy(rest)
	case "routes":
		err = cmdRoutes(rest)
	case "audit":
		err = cmdAudit(rest)
	case "port":
		err = cmdPort(rest)
	case "expose":
		err = cmdExpose(rest)
	case "expose-expire":
		err = cmdExposeExpire(rest)
	case "check-idmap":
		err = cmdCheckIdmap(rest)
	case "inventory":
		loadInventory()
		b, _ := json.MarshalIndent(inv, "", "  ")
		fmt.Println(string(b))
	case "help", "-h":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		die("%v", err)
	}
}

// ---------------------------------------------------------------- helpers

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func need(args []string) string {
	if len(args) < 2 {
		die("%s needs a value", args[0])
	}
	return args[1]
}

func die(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "containers: "+f+"\n", a...)
	os.Exit(1)
}

func info(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "\033[1;34m==>\033[0m "+f+"\n", a...)
}

func q(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func flakeRef(dir string) string {
	sep := "?"
	if strings.Contains(repo, "?") {
		sep = "&"
	}
	return repo + sep + "dir=containers" + func() string {
		if dir == "" {
			return ""
		}
		return "/" + dir
	}()
}

func withRev(ref, rev string) string {
	if rev == "" {
		return ref
	}
	return ref + "&rev=" + rev
}

func loadInventory() {
	if inv != nil {
		return
	}
	c := exec.Command("nix", "eval", "--json", "--refresh", flakeRef("")+"#inventory")
	c.Stderr = os.Stderr
	out, err := c.Output()
	if err != nil {
		die("could not evaluate inventory from %s: %v", flakeRef(""), err)
	}
	inv = &Inventory{}
	if err := json.Unmarshal(out, inv); err != nil {
		die("bad inventory json: %v", err)
	}
	for k, s := range inv.Services {
		if s.Name == "" {
			s.Name = k
		}
		inv.Services[k] = s
	}
}

func service(name string) Service {
	loadInventory()
	s, ok := inv.Services[name]
	if !ok {
		var names []string
		for n := range inv.Services {
			names = append(names, n)
		}
		sort.Strings(names)
		die("unknown service %q (known: %s)", name, strings.Join(names, ", "))
	}
	return s
}

func unitOf(s Service) string {
	if s.Kind == "podman" {
		return "fleet-" + s.Name + ".service"
	}
	return "container@" + s.Name + ".service"
}

func dataDir(s Service) string { return inv.DataRoot + "/" + s.Name }

// userFor is the ssh login for host: --ssh-user / CONTAINERS_SSH_USER if set,
// else the host's `user` in hosts/fleet.nix, else ssh's own default.
func userFor(host string) string {
	if sshUser != "" {
		return sshUser
	}
	if inv != nil {
		return inv.Hosts[host].User
	}
	return ""
}

// rootLogin reports whether `ssh root@host` works with keys alone. Cached per
// host; a var so tests can stub it.
var rootLogin = func(host string) bool {
	rootMu.Lock()
	defer rootMu.Unlock()
	if ok, seen := rootSeen[host]; seen {
		return ok
	}
	err := exec.Command("ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "root@"+host, "true").Run()
	rootSeen[host] = err == nil
	return err == nil
}

var (
	rootMu   sync.Mutex
	rootSeen = map[string]bool{}
)

// sshArgs builds the ssh command for host. Root work logs in as root when
// the keys allow it (no sudo, so it also works without a tty and for users
// whose sudo needs a password); otherwise it wraps the script in sudo.
// --ssh-user always wins.
func sshArgs(host string, tty bool, script string, root bool) []string {
	a := []string{"-o", "ConnectTimeout=8"}
	if tty {
		a = append(a, "-t")
	} else {
		a = append(a, "-o", "BatchMode=yes")
	}
	user := userFor(host)
	if root && sshUser == "" && user != "root" && rootLogin(host) {
		user = "root"
	}
	target := host
	if user != "" {
		target = user + "@" + host
	}
	a = append(a, target)
	if root && user != "root" {
		flag := "-n"
		if tty {
			flag = ""
		}
		a = append(a, "sudo "+flag+" bash -c "+q(script))
	} else {
		a = append(a, "bash -c "+q(script))
	}
	return a
}

// remote runs a script on host with stdio attached to the terminal.
func remote(host string, root bool, script string) error {
	if dryRun {
		fmt.Printf("[%s%s] %s\n", host, map[bool]string{true: " (root)"}[root], script)
		return nil
	}
	c := hostCmd(context.Background(), host, true, root, script)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

// remoteOut runs a script non-interactively and returns stdout.
func remoteOut(ctx context.Context, host string, root bool, script string) (string, error) {
	c := hostCmd(ctx, host, false, root, script)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	err := c.Run()
	if err != nil {
		return out.String(), fmt.Errorf("%v: %s", err, strings.TrimSpace(errb.String()))
	}
	return out.String(), nil
}

type flags struct {
	pos   []string
	vals  map[string]string
	bools map[string]bool
}

// parse handles "--k v", "-k v" and boolean flags in any order.
func parse(args []string, boolFlags ...string) flags {
	f := flags{vals: map[string]string{}, bools: map[string]bool{}}
	isBool := map[string]bool{}
	for _, b := range boolFlags {
		isBool[b] = true
	}
	// Classic loop: the body advances i to consume flag values.
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") && len(a) > 1 {
			k := strings.TrimLeft(a, "-")
			if strings.Contains(k, "=") {
				p := strings.SplitN(k, "=", 2)
				f.vals[p[0]] = p[1]
				continue
			}
			if isBool[k] {
				f.bools[k] = true
				continue
			}
			if i+1 >= len(args) {
				die("flag %s needs a value", a)
			}
			f.vals[k] = args[i+1]
			i++
			continue
		}
		f.pos = append(f.pos, a)
	}
	return f
}

func (f flags) svc() Service {
	if len(f.pos) < 1 {
		die("missing service name")
	}
	return service(f.pos[0])
}

// resolveHost resolves which host a mutating command acts on:
//
//	--host, when given;
//	the placement registry's effective host, when it has a row;
//	discovery, when it has no row.
//
// The second result says the placement still has to be recorded after the
// command succeeds: the operator named the destination (--host) or discovery
// found exactly one copy and it is adopted first. Everything else is either
// already recorded or refused here, because a wrong guess starts a second copy
// of the service somewhere.
//
// Refusals are the point: several copies, no copy, a copy on a host that did
// not answer. A row whose effective host is unreachable is refused too: silence
// is not absence, and acting on the old host could start a second copy. A
// fenced row that names no host at all is refused before anything else: its
// move owns the name, so --host and discovery would both act on a host the
// move may have stranded.
func resolveHost(s Service, f flags) (string, bool, error) {
	v := registry()
	bound := ""
	if v != nil {
		bound = v.Host[s.Name]
		// A token means a move still owns this placement (placements.fenced)
		// and the row names no host to act on: either it is Stale, or it is a
		// first placement that has not served anything yet. Falling through to
		// --host or discovery here is how a deploy or start lands a second copy
		// before any registry write gets the chance to refuse it.
		if r, ok := v.Rows[s.Name]; ok && r.Token != "" && r.effective() == "" {
			return "", false, errFencedPlacement(s, r)
		}
	}
	if h := f.vals["host"]; h != "" {
		switch {
		case bound == h:
			// Already where the operator points: nothing to record (the
			// registry refuses a reserve onto its own binding anyway).
			return h, false, nil
		case bound != "":
			return "", false, fmt.Errorf("%s is placed on %s; `cnt place %s --set %s` records the move first (--host cannot override a live binding)", s.Name, bound, s.Name, h)
		}
		if dryRun {
			return h, false, nil
		}
		return h, true, nil
	}
	if dryRun {
		// No probing and no writes: the declared host keeps the printed
		// script offline, as it always has.
		if s.Host == "" {
			return "", false, fmt.Errorf("%s has no host in service.nix and no --host; nothing to plan against", s.Name)
		}
		return s.Host, false, nil
	}
	if bound != "" {
		p := locate(s, fleetProbe)
		if slices.Contains(p.unreachable, bound) {
			return "", false, fmt.Errorf("%s is placed on %s, which did not answer; refusing to act on another host (a copy may be running there). Bring %s back, or move the binding with `cnt place %s --set <host> --force`; a fenced move is settled with `cnt place %s --recover --force`", s.Name, bound, bound, s.Name, s.Name)
		}
		return bound, false, nil
	}
	p := locate(s, fleetProbe)
	switch {
	case len(p.unreachable) > 0:
		return "", false, fmt.Errorf("cannot confirm where %s is installed: %s did not answer, so a copy there would be missed. Pass --host to act on a specific host", s.Name, joinHosts(p.unreachable))
	case len(p.found) == 0:
		return "", false, fmt.Errorf("%s is placed on no host and installed on no host; pass --host to deploy it somewhere, then `cnt place %s --set <host>`", s.Name, s.Name)
	case len(p.found) > 1:
		return "", false, fmt.Errorf("%s is installed on %s but the registry has no row; `cnt place %s --set <host>` records which copy is authoritative", s.Name, joinHosts(p.found), s.Name)
	}
	return p.found[0], true, nil
}

// resolvedHost is the host a service really runs on: the registry's binding
// when it has one, else the declared `host` (a build-time seed until phase 5).
// Unlike resolveHost it never probes and never refuses: its callers build
// tables and deploy scripts, where a discovery sweep per service would be
// absurd and a refusal would leave a cell blank. Under --dry-run the registry
// is not read either, so a printed plan stays offline.
func resolvedHost(s Service) string {
	if h := boundHost(s.Name); h != "" {
		return h
	}
	return s.Host
}

// hostFor is resolveHost for commands that cannot report an error.
func hostFor(s Service, f flags) (string, bool) {
	h, record, err := resolveHost(s, f)
	if err != nil {
		die("%v", err)
	}
	if record {
		adoptNote(s, h)
	}
	return h, record
}

func adoptNote(s Service, h string) {
	info("%s is installed on %s but the registry has no row; adopting it (cnt place %s --adopt would do the same)", s.Name, h, s.Name)
}

// errLocalCopyPlacedElsewhere refuses to start a service on this machine while
// the registry binds its name to another host: the leftover unit here would
// answer the same name and split the service.
func errLocalCopyPlacedElsewhere(s Service, bound string) error {
	return fmt.Errorf("%s is placed on %s, but a copy is installed here (%s); starting it here would serve the same name from two hosts. Start it there with `cnt start %s --host %s`, or record the move first with `cnt place %s --set %s`", s.Name, bound, localHost, s.Name, bound, s.Name, localHost)
}

// errFencedPlacement refuses to resolve a host for a service a move still owns
// while the row names no host to act on: a stale reservation, or a first
// placement that has not been committed. --host and discovery would both act on
// a host the move may have stranded, and only the holder (or recover, which
// asks the hosts themselves) knows which copy is live.
func errFencedPlacement(s Service, r placementRow) error {
	prev := ""
	if r.Previous != nil {
		prev = fmt.Sprintf(" with a rollback binding on %s", r.Previous.Host)
	}
	return fmt.Errorf("%s is fenced: a move to %s is still open, held by %s (state %s%s). Settle it with `cnt place %s --recover`, which asks both ends; add --force when one does not answer. To take the name over instead, `cnt place %s --set <host> --force` mints a new reservation and invalidates that one", s.Name, r.Host, dash(r.Device), r.State, prev, s.Name, s.Name)
}

// hostForRead is hostFor for commands that only look or connect (status,
// logs, attach, shell, online): if the service is installed on this machine
// and no --host was given, use it without probing the fleet. These cannot
// start a second copy elsewhere, so a full discovery is not needed, and it
// makes the CLI usable on hosts that cannot ssh to the rest (joe).
func hostForRead(s Service, f flags) string {
	if f.vals["host"] == "" && !dryRun && installedHere(s) {
		return localHost
	}
	h, _ := hostFor(s, f)
	return h
}

// gcroots holds the CLI-installed podman services (var for tests).
var gcroots = "/nix/var/nix/gcroots/fleet-containers"

func installedHere(s Service) bool {
	if s.Kind == "podman" {
		_, err := os.Lstat(gcroots + "/" + s.Name)
		return err == nil
	}
	_, err := os.Lstat(mutableUnits + "/" + unitOf(s))
	return err == nil
}

// placement is the result of probing every container host for a service.
type placement struct {
	found       []string // hosts where it is installed (any state)
	running     []string // subset of found where the unit is active
	unreachable []string // hosts that could not be probed
}

// containerHosts are the hosts that may run services, and therefore the hosts
// discovery probes: the inventory's containerHosts, every host the placement
// registry knows about (so a host that only ever held one service is still
// probed), and — while `host` remains a build-time seed — every declared host.
// A host that appears in none of those can still be acted on with --host.
func containerHosts() []string {
	set := map[string]bool{}
	for _, h := range inv.ContainerHosts {
		set[h] = true
	}
	for _, h := range registryHosts() {
		set[h] = true
	}
	for _, s := range inv.Services {
		if s.Host != "" {
			set[s.Host] = true
		}
	}
	hosts := make([]string, 0, len(set))
	for h := range set {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	return hosts
}

// locate probes every container host (never stopping early, so duplicates
// are seen) and reports where s is installed and which hosts did not answer.
func locate(s Service, probe func(context.Context, string) ([]row, error)) placement {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var p placement
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, h := range containerHosts() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rows, err := probe(ctx, h)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				p.unreachable = append(p.unreachable, h)
				return
			}
			for _, r := range rows {
				if r.svc == s.Name {
					p.found = append(p.found, h)
					if r.state == "active" {
						p.running = append(p.running, h)
					}
					return
				}
			}
		}()
	}
	wg.Wait()
	sort.Strings(p.found)
	sort.Strings(p.unreachable)
	return p
}

// ---------------------------------------------------------------- status

type row struct {
	host, svc, kind, state, since, mem string
}

// probeScript lists every service installed on a host, running or not.
// `systemctl list-units --all` only shows units loaded in memory, so a
// stopped/disabled unit can vanish from it after unloading or a reboot.
// Installed units are therefore found on disk too: extra-container writes
// container@<name>.service into the mutable unit dir, and podman services
// keep a gcroot. $R is only set by tests.
const probeScript = `
R=${CONTAINERS_PROBE_ROOT:-}
{
  systemctl list-units --all --plain --no-legend 'container@*.service' 'fleet-*.service' | awk '{print $1}'
  for f in "$R"/etc/systemd-mutable/system/container@?*.service; do [ -e "$f" ] && basename "$f"; done
  for f in "$R"/nix/var/nix/gcroots/fleet-containers/*; do [ -e "$f" ] && echo "fleet-$(basename "$f").service"; done
} | sort -u | while read -r u; do
  case "$u" in
    container@.service|"") continue;;
    # podman services are only those installed by the CLI (they have a gcroot);
    # this skips the host module's own units such as fleet-containers-ports.service
    fleet-*.service) n=${u#fleet-}; n=${n%.service}; [ -e "$R/nix/var/nix/gcroots/fleet-containers/$n" ] || continue;;
  esac
  st=$(systemctl show -p ActiveState --value "$u")
  ts=$(systemctl show -p ActiveEnterTimestamp --value "$u")
  mem=$(systemctl show -p MemoryCurrent --value "$u")
  echo "$u|${st:-inactive}|$ts|$mem"
done
`

func probe(ctx context.Context, host string) ([]row, error) {
	out, err := remoteOut(ctx, host, false, probeScript)
	if err != nil {
		return nil, err
	}
	var rows []row
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		p := strings.Split(l, "|")
		if len(p) != 4 {
			continue
		}
		name, kind := p[0], "nixos"
		if n, ok := strings.CutPrefix(name, "container@"); ok {
			name = strings.TrimSuffix(n, ".service")
		} else {
			name = strings.TrimSuffix(strings.TrimPrefix(name, "fleet-"), ".service")
			kind = "podman"
		}
		rows = append(rows, row{host: host, svc: name, kind: kind, state: p[1], since: ago(p[2]), mem: humanMem(p[3])})
	}
	return rows, nil
}

func ago(ts string) string {
	ts = strings.TrimSpace(ts)
	if ts == "" || ts == "n/a" {
		return "-"
	}
	t, err := time.Parse("Mon 2006-01-02 15:04:05 MST", ts)
	if err != nil {
		return ts
	}
	d := time.Since(t).Round(time.Minute)
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

func humanMem(s string) string {
	var n float64
	if _, err := fmt.Sscan(s, &n); err != nil || n <= 0 || n > 1e18 {
		return "-"
	}
	units := []string{"B", "K", "M", "G", "T"}
	i := 0
	for n >= 1024 && i < len(units)-1 {
		n /= 1024
		i++
	}
	return fmt.Sprintf("%.1f%s", n, units[i])
}

func statusTable(all bool) string {
	loadInventory()
	return renderStatus(all, probe)
}

func renderStatus(all bool, probe func(context.Context, string) ([]row, error)) string {
	hostSet := map[string]bool{}
	// Registered container hosts too, so a service moved to a host with no
	// declarations still shows where it runs.
	for _, h := range containerHosts() {
		hostSet[h] = true
	}
	if all {
		for h := range inv.Hosts {
			hostSet[h] = true
		}
	}
	var hosts []string
	for h := range hostSet {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var mu sync.Mutex
	var wg sync.WaitGroup
	running := map[string][]row{} // svc -> rows
	hostErr := map[string]string{}
	for _, h := range hosts {
		wg.Add(1)
		go func(h string) {
			defer wg.Done()
			rows, err := probe(ctx, h)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				hostErr[h] = err.Error()
				return
			}
			for _, r := range rows {
				running[r.svc] = append(running[r.svc], r)
			}
		}(h)
	}
	wg.Wait()

	var b strings.Builder
	tw := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintf(tw, "SERVICE\tKIND\tDECLARED\tHOST\t%s\tUP\tMEM\tNOTE\n", colorState("STATE"))
	names := map[string]bool{}
	for n := range inv.Services {
		names[n] = true
	}
	for n := range running {
		names[n] = true
	}
	var sorted []string
	for n := range names {
		sorted = append(sorted, n)
	}
	// Repo services first, then installed units the repo does not know,
	// under a separator line.
	sort.Slice(sorted, func(i, j int) bool {
		_, ki := inv.Services[sorted[i]]
		_, kj := inv.Services[sorted[j]]
		if ki != kj {
			return ki
		}
		return sorted[i] < sorted[j]
	})
	sep := false
	for _, n := range sorted {
		s, known := inv.Services[n]
		if !known && !sep {
			sep = true
			fmt.Fprintf(tw, "---\t\t\t\t%s\t\t\t\n", colorState(""))
		}
		rows := running[n]
		if len(rows) == 0 {
			note := ""
			if _, bad := hostErr[s.Host]; bad {
				note = "host unreachable"
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, s.Kind, dash(s.Host), "-", colorState("not installed"), "-", "-", note)
			continue
		}
		for _, r := range rows {
			note := ""
			switch bound := boundHost(n); {
			case !known:
				note = "not in repo"
			case bound != "" && r.host != bound:
				note = "!! placed on " + bound + ": this is a stray copy (cnt place " + n + " --set " + r.host + " to move the binding)"
			case bound == "" && s.Host != "" && r.host != s.Host:
				note = "!! declared " + s.Host + ": set host = \"" + r.host + "\" in service.nix"
			case len(rows) > 1:
				note = "installed on several hosts"
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, r.kind, dash(s.Host), r.host, colorState(r.state), r.since, r.mem, note)
		}
	}
	tw.Flush()
	var errHosts []string
	for h := range hostErr {
		errHosts = append(errHosts, h)
	}
	sort.Strings(errHosts)
	for _, h := range errHosts {
		fmt.Fprintf(&b, "\n! %s: %s", h, hostErr[h])
	}
	return b.String()
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// colorState colours the STATE cell. Every cell, coloured or not, carries
// the same number of invisible escape bytes (5 + 4), so tabwriter (which
// counts bytes) still aligns the columns after it.
func colorState(s string) string {
	if os.Getenv("NO_COLOR") != "" {
		return s
	}
	code := "39" // default colour; same length as the others
	switch s {
	case "active":
		code = "32"
	case "failed":
		code = "31"
	case "activating", "deactivating", "reloading":
		code = "33"
	}
	return "\033[" + code + "m" + s + "\033[0m"
}

func cmdStatus(args []string, watch bool) error {
	f := parse(args, "all", "a")
	all := f.bools["all"] || f.bools["a"]
	if !watch {
		fmt.Println(statusTable(all))
		return nil
	}
	every := 5 * time.Second
	if n := f.vals["n"]; n != "" {
		var secs int
		fmt.Sscan(n, &secs)
		if secs > 0 {
			every = time.Duration(secs) * time.Second
		}
	}
	quit := make(chan struct{})
	if restore := rawTerminal(); restore != nil {
		defer restore()
		go func() {
			buf := make([]byte, 1)
			for {
				if _, err := os.Stdin.Read(buf); err != nil || buf[0] == 'q' || buf[0] == 3 {
					close(quit)
					return
				}
			}
		}()
	}
	for {
		t := statusTable(all)
		fmt.Print("\033[H\033[2J")
		fmt.Printf("containers watch  (every %s, q to quit)  %s\r\n\r\n", every, time.Now().Format("15:04:05"))
		fmt.Print(strings.ReplaceAll(t, "\n", "\r\n") + "\r\n")
		select {
		case <-quit:
			return nil
		case <-time.After(every):
		}
	}
}

// rawTerminal switches stdin to raw mode with stty so single keys work.
func rawTerminal() func() {
	c := exec.Command("stty", "-g")
	c.Stdin = os.Stdin
	old, err := c.Output()
	if err != nil {
		return nil
	}
	s := exec.Command("stty", "raw", "-echo")
	s.Stdin = os.Stdin
	if s.Run() != nil {
		return nil
	}
	return func() {
		r := exec.Command("stty", strings.TrimSpace(string(old)))
		r.Stdin = os.Stdin
		r.Run()
		fmt.Println()
	}
}

// ---------------------------------------------------------------- logs

func cmdLogs(args []string) error {
	f := parse(args, "no-follow", "unit")
	s := f.svc()
	h := hostForRead(s, f)
	n := f.vals["n"]
	if n == "" {
		n = "200"
	}
	follow := " -f"
	if f.bools["no-follow"] {
		follow = ""
	}
	var cmd string
	if s.Kind == "podman" || f.bools["unit"] {
		cmd = fmt.Sprintf("journalctl -u %s -n %s%s", unitOf(s), n, follow)
	} else {
		cmd = fmt.Sprintf("journalctl -M %s -n %s%s", s.Name, n, follow)
	}
	return remote(h, true, cmd)
}

// ---------------------------------------------------------------- deploy

// prepareHost writes data dirs, nginx site and firewall ports.
func prepareScript(s Service, host string) string {
	var b strings.Builder
	b.WriteString("set -euo pipefail\n")
	b.WriteString("test -d /etc/systemd-mutable/system -o -d /var/lib/fleet-containers || { echo 'host is missing the containers host module (inputs.containers.nixosModules.default)'; exit 1; }\n")
	b.WriteString(requiresScript(s, host))
	if s.Net.Private {
		if s.Kind == "podman" {
			// podman net.private rides the always-present fleet-noinet table
			// (cfg.enable), not the nixos-guest veth/NAT side.
			b.WriteString(fmt.Sprintf("nft list table inet fleet-noinet >/dev/null 2>&1 || { echo '%s has net.private but %s lacks the fleet-noinet table (containers host module not enabled)' >&2; exit 1; }\n", s.Name, host))
		} else {
			// ROUTING-PLAN §8 step 5: the host side (NAT, DNAT map, DNS on the veth).
			b.WriteString(fmt.Sprintf("nft list table ip fleet-net-nat >/dev/null 2>&1 || { echo '%s has net.private but %s lacks ringofstorms.containers.privateNetwork.enable' >&2; exit 1; }\n", s.Name, host))
		}
	}
	b.WriteString("install -d -m755 /var/lib/fleet-containers/nginx /var/lib/fleet-containers/ports\n")
	// The cnt expose override is dropped only after the new site is live
	// (end of this script), never before: see dropOverrideScript.
	b.WriteString(fmt.Sprintf("install -d -m755 %s\n", q(dataDir(s))))
	keys := make([]string, 0, len(s.Persist))
	for k := range s.Persist {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		// Only create; never chown existing data.
		b.WriteString(fmt.Sprintf("[ -d %[1]s ] || install -d -m755 %[1]s\n", q(dataDir(s)+"/"+k)))
	}
	// ports
	var ports strings.Builder
	for _, l := range portsFileLines(s, host) {
		ports.WriteString(l + "\n")
	}
	// 80/443 admission (ROUTING-PLAN 8.2) for this service's vhosts on this
	// host, from its own routes. Written before prunePortsScript, which
	// ignores non-`tcp|udp` first words.
	for _, l := range srcPortLines(s, host) {
		ports.WriteString(l + "\n")
	}
	b.WriteString(fmt.Sprintf("old_ports=$(cat /var/lib/fleet-containers/ports/%s 2>/dev/null || true)\n", s.Name))
	b.WriteString(fmt.Sprintf("printf %%s %s > /var/lib/fleet-containers/ports/%s\n", q(ports.String()), s.Name))
	b.WriteString(prunePortsScript)
	b.WriteString("systemctl reload-or-restart fleet-containers-ports.service || true\n")
	b.WriteString(siteScript(s, host))
	b.WriteString(dropOverrideScript(s.Name))
	return b.String()
}

// prunePortsScript closes the temp-ports elements that $old_ports (the
// service's previous ports file) opened and no ports file opens any more.
// applyPorts only adds to that set (it is never flushed: agnos shares it),
// so without this a dropped tcpPorts entry stays open until the next
// firewall reload. cleanupScript's nftables restart would also do it, but is
// too disruptive for every deploy. A missing old file or element is fine.
const prunePortsScript = `while read -r pr po mode _ || [ -n "$pr" ]; do
  case "$pr" in tcp|udp) ;; *) continue ;; esac
  case "$po" in ""|*[!0-9]*) continue ;; esac
  [ -z "$mode" ] || continue
  grep -qxsF -- "$pr $po" /var/lib/fleet-containers/ports/* && continue
  nft delete element inet nixos-fw temp-ports "{ $pr . $po }" 2>/dev/null || true
done <<< "$old_ports"
`

// refreshScript rewrites the 80/443 admission in s's ports file on host
// from srcPortLines, which is what a deploy would have written: the web
// and weblan lines are recomputed and every other line is kept. Only the
// ports file is touched -- the container and its nginx site keep running,
// so a vhost's `allow` list still only changes on a deploy.
func refreshScript(s Service, host string) string {
	p := "/var/lib/fleet-containers/ports/" + s.Name
	var fresh strings.Builder
	for _, l := range srcPortLines(s, host) {
		fresh.WriteString(l + "\n")
	}
	var b strings.Builder
	b.WriteString("set +e\n")
	b.WriteString("p=" + p + "\n")
	b.WriteString("b=$p.bak\n")
	b.WriteString("if [ ! -e \"$p\" ]; then\n")
	b.WriteString(fmt.Sprintf("  printf \"warning: %s has no ports file on %s yet; its net.uses admission is unchanged\\n\" >&2\n", s.Name, host))
	b.WriteString("  exit 0\nfi\n")
	b.WriteString("rm -f \"$b\" \"$p.new\"\n")
	b.WriteString(fmt.Sprintf("cp \"$p\" \"$b\" || { printf \"warning: cannot back up %s on %s; its net.uses admission is stale\\n\" >&2; exit 0; }\n", p, host))
	b.WriteString("if awk \"\\$1 == \\\"web\\\" || \\$1 == \\\"weblan\\\" { next } { print }\" \"$b\" > \"$p.new\"")
	if fresh.Len() > 0 {
		// srcPortLines only emits addresses and CIDRs, so a double-quoted
		// block carries the newlines and needs no shell quoting.
		b.WriteString(" && printf %s \"" + fresh.String() + "\" >> \"$p.new\"")
	}
	b.WriteString(" && mv -f \"$p.new\" \"$p\"; then\n")
	b.WriteString("  rm -f \"$b\"\n")
	b.WriteString("else\n")
	b.WriteString(fmt.Sprintf("  printf \"warning: cannot rewrite %s on %s; kept the previous ports file\\n\" >&2\n", p, host))
	b.WriteString("  mv -f \"$b\" \"$p\"\n")
	b.WriteString("fi\n")
	b.WriteString("rm -f \"$b\" \"$p.new\"\n")
	b.WriteString(fmt.Sprintf("systemctl reload-or-restart fleet-containers-ports.service || printf \"warning: cannot reload the ports sets on %s\\n\" >&2\n", host))
	return b.String()
}

// refreshCallers re-computes the ports file of every callee caller's
// net.uses names, on every host each callee actually runs on: a move or a
// destroy changes where the caller is, which those files encode. Called
// after the change has been made, and after resetFleetPlacement, so the
// placement it reads is the new one. Failures are warnings: the move or
// destroy itself already succeeded.
func refreshCallers(caller Service) {
	var callees []Service
	for _, u := range caller.Net.Uses {
		t, r, ok := usesTarget(u)
		if !ok || r.Proto != "http" || r.Exposure == "local" {
			continue
		}
		callees = append(callees, t)
	}
	if len(callees) == 0 {
		// The common case: nothing to re-admit, so no discovery sweep.
		return
	}
	fp := fleetPlacementNow()
	if fp == nil {
		return
	}
	done := map[string]bool{}
	for _, t := range callees {
		hosts, known := fp.places(t.Name, t.Host)
		if !known {
			fmt.Fprintf(os.Stderr, "warning: %s was not discovered (a host did not answer); refreshing its admission of %s on its declared host %s\n", t.Name, caller.Name, t.Host)
		}
		if len(hosts) == 0 {
			fmt.Fprintf(os.Stderr, "warning: %s is installed on no host; its admission of %s is not refreshed\n", t.Name, caller.Name)
			continue
		}
		for _, th := range hosts {
			key := th + " " + t.Name
			if done[key] {
				continue
			}
			done[key] = true
			info("refreshing the 80/443 admission of %s on %s (net.uses %s)", t.Name, th, caller.Name)
			if err := remote(th, true, refreshScript(t, th)); err != nil {
				fmt.Fprintf(os.Stderr, "warning: refreshing %s on %s: %v\n", t.Name, th, err)
			}
		}
	}
}

// siteScript writes (or removes) the service's nginx site on host, validated
// with nginx -t and rolled back on failure. Used by prepareScript and by
// `deploy --vhost-only`.
func siteScript(s Service, host string) string {
	var b strings.Builder
	// nginx: only when a route needs a vhost on this host (see needsHostVhost);
	// hosts without containers.nginx (joe) must never be asked to run nginx -t.
	if v := routesVhost(s); v != "" && needsHostVhost(s) {
		conf := "# managed by containers, service " + s.Name + " (generated from routes)\n" + v
		b.WriteString(nginxSiteScript(nginxDir, s.Name, conf))
	} else if len(s.Routes) == 0 && s.Nginx != nil && strings.TrimSpace(*s.Nginx) != "" {
		conf := *s.Nginx
		if hh, ok := inv.Hosts[host]; ok {
			if hh.OverlayIP != nil {
				conf = strings.ReplaceAll(conf, "@OVERLAY_IP@", *hh.OverlayIP)
			}
			if hh.LanIP != nil {
				conf = strings.ReplaceAll(conf, "@LAN_IP@", *hh.LanIP)
			}
		}
		conf = "# managed by containers, service " + s.Name + "\n" + conf
		b.WriteString(nginxSiteScript(nginxDir, s.Name, conf))
	} else {
		b.WriteString(fmt.Sprintf("rm -f %s/%s.conf.broken\n", nginxDir, s.Name))
		b.WriteString(fmt.Sprintf("if [ -e %[1]s/%[2]s.conf ]; then rm -f %[1]s/%[2]s.conf %[1]s/%[2]s.conf.prev; systemctl reload nginx; fi\n", nginxDir, s.Name))
	}
	return b.String()
}

// needsHostVhost reports whether some route must be served by nginx on the
// service's own host: an http route that leaves the host (exposure !=
// local). Every container host terminates TLS for its own routes
// (FLOWS-AUDIT target design (a)); tcp/udp routes go through the ports
// file, not nginx.
func needsHostVhost(s Service) bool {
	for _, r := range s.Routes {
		if r.Proto == "http" && r.Exposure != "local" {
			return true
		}
	}
	return false
}

// cleanupScript removes the service's host state. The site goes (and nginx
// reloads) before the expose override is dropped, so an interruption can
// never leave a widened site without its expiry state.
func cleanupScript(s Service) string {
	return fmt.Sprintf(`rm -f /var/lib/fleet-containers/ports/%[1]s
systemctl restart fleet-containers-ports.service nftables.service 2>/dev/null || true
if [ -e %[2]s/%[1]s.conf ]; then rm -f %[2]s/%[1]s.conf; systemctl reload nginx || true; fi
`, s.Name, nginxDir) + dropOverrideScript(s.Name)
}

func cmdDeploy(args []string) error {
	f := parse(args, "local", "vhost-only")
	s := f.svc()
	h, record, err := resolveHost(s, f)
	if err != nil {
		return err
	}
	if record {
		adoptNote(s, h)
	}
	if f.bools["vhost-only"] {
		// Regenerate only the nginx site (e.g. after a routesVhost change);
		// the container and its ports are not touched.
		if err := validateRoutes(s); err != nil {
			return err
		}
		info("rewriting the nginx site of %s on %s", s.Name, h)
		return remote(h, true, "set -euo pipefail\n"+siteScript(s, h)+dropOverrideScript(s.Name))
	}
	ref := withRev(flakeRef(s.Dir), f.vals["rev"])
	if err := deploy(s, h, ref, f.bools["local"]); err != nil {
		return err
	}
	// A deploy is where a new placement first shows up, so the callees this
	// service uses have to admit it from its new host. Not in deploy() itself:
	// a move deploys mid-flight and refreshes once, after the switch.
	resetFleetPlacement()
	refreshCallers(s)
	if record {
		recordAfterDeploy(s.Name, h)
	}
	return nil
}

// recordAfterDeploy adopts the placement of a service this deploy put on h with
// --host (or found on exactly one host), so the next command resolves h from
// the registry instead of guessing. The deploy already succeeded: a registry
// failure is reported and left for the operator, never rolled back by undoing
// the deploy.
//
// The write forces nothing. A reserve is the registry's compare-and-swap, and
// the deploy runs for minutes on end: a row another client reserved in that
// window — a move reserves before it deploys — is refused with a 409 naming the
// move, and that reservation is left exactly as it is. Forcing would mint a new
// token over it, which is how the move still running would be stopped from
// committing what it reserved.
func recordAfterDeploy(svc, h string) {
	if dryRun {
		return
	}
	c, err := edgeClientFor()
	var row placementRow
	if err == nil {
		row, err = recordPlacement(c, svc, h, "cnt deploy --host", false)
	}
	if err == nil {
		resetFleetPlacement()
		info("%s: %s -> %s (revision %d)", row.Service, row.State, dash(row.effective()), row.Revision)
		return
	}
	fmt.Fprintf(os.Stderr, "\033[1;31m==>\033[0m WARNING: %s is running on %s but its placement was not recorded (%v).\n", svc, h, err)
	fmt.Fprintf(os.Stderr, "\033[1;31m==>\033[0m WARNING: record it before anything else starts it: containers place %s --set %s\n", svc, h)
	if holder := foreignHolder(err); holder != "" {
		fmt.Fprintf(os.Stderr, "\033[1;31m==>\033[0m WARNING: %s owns the row now; the deploy left that reservation untouched (nothing forced).\n", holder)
	}
}

// foreignHolder pulls the move out of a refusal. The registry is the only one
// that knows which move owns the row now: the view this command resolved from
// is as old as the deploy, so a name read from it would be the wrong client.
func foreignHolder(err error) string {
	var e *edgeHTTPError
	if !errors.As(err, &e) || e.Code != 409 {
		return ""
	}
	const owns, refused = " owns the reservation", "refused: "
	end := strings.Index(e.Msg, owns)
	if end < 0 {
		return ""
	}
	start := strings.LastIndex(e.Msg[:end], refused)
	if start < 0 {
		return ""
	}
	return e.Msg[start+len(refused) : end]
}

func deploy(s Service, h, ref string, local bool) error {
	if err := validateRoutes(s); err != nil {
		return err
	}
	info("deploying %s (%s) to %s from %s", s.Name, s.Kind, h, ref)
	if err := remote(h, true, prepareScript(s, h)); err != nil {
		return fmt.Errorf("preparing host: %w", err)
	}
	var out string
	if local {
		info("building locally")
		b := exec.Command("nix", "build", "--no-link", "--print-out-paths", "--refresh", ref)
		b.Stderr = os.Stderr
		o, err := b.Output()
		if err != nil {
			return fmt.Errorf("build: %w", err)
		}
		out = strings.TrimSpace(string(o))
		target := h
		if u := userFor(h); u != "" {
			target = u + "@" + h
		}
		if isLocal(h) {
			info("built on %s itself, nothing to copy", h)
		} else if !dryRun {
			info("copying %s to %s", out, h)
			// Locally built paths are unsigned; the target trusts us as root/@wheel
			// over ssh, but the daemon still demands sigs unless told otherwise.
			c := exec.Command("nix", "copy", "--no-check-sigs", "--substitute-on-destination", "--to", "ssh-ng://"+target, out)
			c.Stdout, c.Stderr = os.Stdout, os.Stderr
			if err := c.Run(); err != nil {
				return fmt.Errorf("nix copy: %w", err)
			}
		}
	}
	var script string
	if out != "" {
		script = "set -e\nout=" + q(out) + "\n"
	} else {
		script = "set -e\nout=$(nix build --no-link --print-out-paths --refresh " + q(ref) + ")\n"
	}
	script += installScript(s)
	if err := remote(h, true, script); err != nil {
		return fmt.Errorf("deploy: %w", err)
	}
	info("%s is running on %s", s.Name, h)
	return nil
}

// ---------------------------------------------------------------- lifecycle

// cmdUnit starts, stops or restarts a service. stop keeps the local fast path
// (hostForRead): stopping a copy that is not the bound one only removes a stray.
// start and restart resolve like a mutating command, because enabling a unit
// starts it: on a host that holds a leftover copy while the registry binds
// another host, the fast path would bring the leftover up under the same name
// and split it.
func cmdUnit(verb string, args []string) error {
	f := parse(args)
	s := f.svc()
	u := unitOf(s)
	if verb == "stop" {
		h := hostForRead(s, f)
		info("stopping %s on %s (waits until fully down; stays stopped across reboots)", s.Name, h)
		return remote(h, true, disableScript(s)+"systemctl stop "+u+" && echo stopped: $(systemctl is-active "+u+")")
	}
	h, record, err := resolveHost(s, f)
	if err != nil {
		return err
	}
	if record {
		adoptNote(s, h)
	}
	if !isLocal(h) && installedHere(s) {
		return errLocalCopyPlacedElsewhere(s, h)
	}
	if verb == "restart" {
		// systemctl restart on container@ is unreliable (nixpkgs#43652).
		return remote(h, true, enableScript(s)+"systemctl stop "+u+" && systemctl start "+u+" && systemctl is-active "+u)
	}
	return remote(h, true, enableScript(s)+"systemctl start "+u+" && systemctl is-active "+u)
}

// cmdOnline temporarily gives an `internet = false` podman service network
// access: its container IP goes into the host's fleet-noinet @online nft set
// with a timeout, so access ends by itself. A firewall reload or container
// restart (new IP) also ends it. `--off` removes it now.
func cmdOnline(args []string) error {
	f := parse(args, "off")
	s := f.svc()
	if s.Kind != "podman" || s.Internet == nil || *s.Internet {
		return fmt.Errorf("%s is not a podman service with internet = false; nothing to toggle", s.Name)
	}
	h := hostForRead(s, f)
	d := f.vals["for"]
	if d == "" {
		d = "30m"
	}
	dur, err := time.ParseDuration(d)
	if err != nil || dur < time.Second {
		return fmt.Errorf("--for %q: want a duration like 30m or 2h", d)
	}
	secs := fmt.Sprintf("%ds", int(dur.Seconds()))
	ip := fmt.Sprintf(`ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' %s) && [ -n "$ip" ] || { echo "%s is not running" >&2; exit 1; }
`, q(s.Name), s.Name)
	if f.bools["off"] {
		return remote(h, true, ip+`nft delete element inet fleet-noinet online "{ $ip }" 2>/dev/null; echo "`+s.Name+` offline"`)
	}
	info("%s on %s: internet allowed for %s (containers online %s --off to end early)", s.Name, h, d, s.Name)
	return remote(h, true, ip+`nft add element inet fleet-noinet online "{ $ip timeout `+secs+` }" && nft list set inet fleet-noinet online | grep -o "$ip[^,}]*"`)
}

func cmdAttach(args []string, shell bool) error {
	f := parse(args)
	s := f.svc()
	h := hostForRead(s, f)
	if s.Kind == "podman" {
		cmd := "sh"
		if !shell && s.Attach != "" {
			cmd = s.Attach
		}
		return remote(h, true, "podman exec -it "+s.Name+" "+cmd)
	}
	if shell || s.Attach == "" {
		return remote(h, true, "nixos-container root-login "+s.Name)
	}
	return remote(h, true, "nixos-container run "+s.Name+" -- bash -lc "+q(s.Attach))
}

func hookScript(s Service) string {
	if s.BackupHook == "" {
		return ""
	}
	if s.Kind == "podman" {
		return fmt.Sprintf("if systemctl is-active -q %s; then echo 'running backup hook'; podman exec %s sh -c %s; fi\n", unitOf(s), s.Name, q(s.BackupHook))
	}
	return fmt.Sprintf("if systemctl is-active -q %s; then echo 'running backup hook'; nixos-container run %s -- bash -lc %s; fi\n", unitOf(s), s.Name, q(s.BackupHook))
}

// streamCmd runs a remote script and pipes its stdout to w.
func streamFrom(h, script string, w *os.File) error {
	if dryRun {
		fmt.Printf("[%s (root, stream out)] %s\n", h, script)
		return nil
	}
	c := hostCmd(context.Background(), h, false, true, script)
	c.Stdout, c.Stderr = w, os.Stderr
	return c.Run()
}

func cmdBackup(args []string) error {
	f := parse(args, "live", "yes", "y")
	s := f.svc()
	h, _ := hostFor(s, f)
	yes := f.bools["yes"] || f.bools["y"]
	name := fmt.Sprintf("%s-%s-%s.tar.zst", s.Name, h, time.Now().Format("2006-01-02T1504"))
	out, err := backupDest(f.vals["o"], name, yes)
	if err != nil {
		return err
	}
	running := false
	if !f.bools["live"] {
		st, _ := remoteOut(context.Background(), h, false, "systemctl is-active "+unitOf(s)+" || true")
		running = strings.TrimSpace(st) == "active"
	}
	if running && !yes {
		if !confirm(fmt.Sprintf("%s is running on %s. Stop it for a consistent backup (it is started again afterwards)?", s.Name, h)) {
			return errors.New("backup cancelled; use --live to copy without stopping")
		}
	}
	if !f.bools["live"] && !running {
		// A storage guard may have started it since the status read: hold, then
		// stop whatever is running now (it is started again afterwards).
		if err := remote(h, true, backupStopScript(s)); err != nil {
			return err
		}
		info("%s is not running on %s; backing up as is", s.Name, h)
		if hs := hookScript(s); hs != "" {
			info("note: %s has a backup hook, which needs the service running; skipped", s.Name)
		}
	} else if !f.bools["live"] {
		pre := hookScript(s) + backupStopScript(s)
		info("stopping %s on %s for a consistent copy", s.Name, h)
		if err := remote(h, true, pre); err != nil {
			return err
		}
	} else if hs := hookScript(s); hs != "" {
		remote(h, true, hs)
	}
	info("writing %s", out)
	var tarErr error
	if dryRun {
		fmt.Printf("[%s (root, stream out)] %s\n", h, packScript(inv.DataRoot, s.Name))
	} else {
		tarErr = backupTo(hostCmd(context.Background(), h, false, true, packScript(inv.DataRoot, s.Name)), out)
	}
	if !f.bools["live"] {
		remote(h, true, unholdScript(s)+fmt.Sprintf("if [ -e /var/lib/fleet-containers/%[2]s.was-running ]; then rm -f /var/lib/fleet-containers/%[2]s.was-running; systemctl start %[1]s; fi", unitOf(s), s.Name))
	}
	if tarErr != nil {
		return fmt.Errorf("backup failed, nothing written to %s: %w", out, tarErr)
	}
	st, _ := os.Stat(out)
	if st != nil {
		info("backup done: %s (%s)", out, humanMem(fmt.Sprint(st.Size())))
	}
	return nil
}

func cmdRestore(args []string) error {
	f := parse(args, "force")
	if len(f.pos) < 2 {
		return errors.New("usage: containers restore <svc> <file> --host h [--force]")
	}
	s := service(f.pos[0])
	h, _ := hostFor(s, f)
	file := f.pos[1]
	in, err := os.Open(file)
	if err != nil {
		return err
	}
	defer in.Close()
	dst := dataDir(s)
	check := fmt.Sprintf(`if systemctl is-active -q %s; then echo "%s is running on this host; stop it first"; exit 1; fi
if [ -e %s ]; then
  if [ "%v" = true ]; then mv %s %s.pre-restore-$(date +%%s); else echo "%s exists; use --force (old data is renamed, not deleted)"; exit 1; fi
fi
`, unitOf(s), s.Name, q(dst), f.bools["force"], q(dst), q(dst), dst)
	if err := remote(h, true, check); err != nil {
		return err
	}
	info("restoring %s into %s:%s", file, h, dst)
	if dryRun {
		return nil
	}
	decomp := "zstd -d -q -c"
	if strings.HasSuffix(file, ".gz") || strings.HasSuffix(file, ".tgz") {
		decomp = "gzip -dc"
	}
	c := hostCmd(context.Background(), h, false, true, unpackScript(decomp, inv.DataRoot))
	c.Stdin, c.Stdout, c.Stderr = in, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		return err
	}
	info("restored. deploy with: containers deploy %s --host %s", s.Name, h)
	return nil
}

func uninstallScript(s Service) string {
	if s.Kind == "podman" {
		return fmt.Sprintf("if [ -x /nix/var/nix/gcroots/fleet-containers/%[1]s/bin/fleet-uninstall ]; then /nix/var/nix/gcroots/fleet-containers/%[1]s/bin/fleet-uninstall; fi\n", s.Name)
	}
	return fmt.Sprintf("systemctl stop %s || true\nextra-container destroy %s\n", unitOf(s), s.Name)
}

// cmdDestroy removes the service from one host. Which copy that is decides
// what is allowed:
//
//	a stray (--host names a host the registry does not bind): removed, once a
//	probe confirms that host really has it; the registry row is not touched;
//	the authoritative copy (the bound host): refused without --force, because
//	the name would point at nothing. With --force the row goes too, unforced
//	and guarded by the revision this command read;
//	no row: as before (--host, else the one copy discovery finds).
//
// A fenced row (a move still holds it) is refused unless --force: the move
// may be about to make either copy the live one.
func cmdDestroy(args []string) error {
	f := parse(args, "purge", "force")
	s := f.svc()
	force := f.bools["force"]
	var row placementRow
	hasRow, bound := false, ""
	if v := registry(); v != nil {
		row, hasRow = v.Rows[s.Name]
		bound = v.Host[s.Name]
	}
	if hasRow && row.Token != "" && !force {
		return fmt.Errorf("%w; destroy refuses while a move holds the row (pass --force to remove a copy anyway)", errFencedPlacement(s, row))
	}
	h := f.vals["host"]
	if h == "" {
		var err error
		if h, _, err = resolveHost(s, f); err != nil {
			return err
		}
	}
	stray := bound != "" && h != bound
	authoritative := bound != "" && h == bound
	switch {
	case stray && !dryRun:
		installed, err := installedOn(s, h)
		if err != nil {
			return fmt.Errorf("%s is placed on %s; cannot confirm a stray copy on %s: %w", s.Name, bound, h, err)
		}
		if !installed {
			return fmt.Errorf("%s is placed on %s and is not installed on %s; nothing to remove", s.Name, bound, h)
		}
		info("%s is placed on %s; removing the stray copy on %s (the registry row is left as it is)", s.Name, bound, h)
	case authoritative && !force:
		return fmt.Errorf("%s on %s is the authoritative copy (the placement registry binds it there); move it (`cnt move %s --to <host>`) or rebind it (`cnt place %s --set <host>`) first, or pass --force to remove it and its registry row", s.Name, h, s.Name, s.Name)
	}
	script := uninstallScript(s) + cleanupScript(s)
	if f.bools["purge"] {
		script += "rm -rf " + q(dataDir(s)) + "\n"
	}
	info("removing %s from %s%s", s.Name, h, map[bool]string{true: " and DELETING its data"}[f.bools["purge"]])
	err := remote(h, true, script)
	if err != nil {
		// The removal may have failed, so the service can still be running:
		// leave the callees' admission alone rather than withdraw it.
		return err
	}
	// Whoever used this service's routes has to stop admitting this copy.
	// Its definition stays: another host may still be running it, and that
	// copy has to keep its admission. Only the (service, host) pair is
	// retired, so discovery stops reporting the copy just removed even if the
	// host has not caught up. Only warnings: the removal itself is done.
	retirePlacement(s.Name, h)
	resetFleetPlacement()
	refreshCallers(s)
	if authoritative && !dryRun {
		return dropDestroyedRow(s, h, row.Revision)
	}
	return nil
}

// installedOn asks h alone whether s is installed there (any state).
func installedOn(s Service, h string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	rows, err := fleetProbe(ctx, h)
	if err != nil {
		return false, err
	}
	for _, r := range rows {
		if r.svc == s.Name {
			return true, nil
		}
	}
	return false, nil
}

// dropDestroyedRow removes the row of a service whose authoritative copy a
// forced destroy just removed: unforced, with the revision read before the
// destroy, so a row someone rewrote in the meantime is left to them.
func dropDestroyedRow(s Service, h string, revision int64) error {
	c, err := edgeClientFor()
	if err == nil {
		_, err = c.placementRemove(s.Name, "", revision, false)
	}
	if err != nil {
		return fmt.Errorf("%s was removed from %s, but its registry row was not (%v); it still names %s. Settle it with `cnt place %s --set <host>` or `cnt place %s --recover`", s.Name, h, err, h, s.Name, s.Name)
	}
	registryCache = nil
	info("%s: registry row removed", s.Name)
	return nil
}

// ---------------------------------------------------------------- idmap

const idmapScript = `
set -u
check() {
  base=$1
  d=$(mktemp -d "$base/.containers-idmap.XXXXXX") || { echo "$base: cannot create temp dir"; return 1; }
  mkdir "$d/src" "$d/dst"
  touch "$d/src/f" && chown 1000:100 "$d/src/f"
  if mount --bind -o X-mount.idmap=b:0:1000000:65536 "$d/src" "$d/dst" 2>"$d/err"; then
    got=$(stat -c '%u %g' "$d/dst/f")
    umount "$d/dst"
    if [ "$got" = "1001000 1000100" ]; then
      echo "OK    $base ($(stat -f -c %T "$base")) idmap works"
    else
      echo "FAIL  $base: expected '1001000 1000100', got '$got'"
    fi
  else
    echo "FAIL  $base ($(stat -f -c %T "$base")): $(cat "$d/err")"
  fi
  rm -rf "$d"
}
mkdir -p /srv/containers
check /srv/containers
check /nix/var/nix
echo "kernel $(uname -r)"
`

func cmdCheckIdmap(args []string) error {
	if len(args) < 1 {
		return errors.New("usage: containers check-idmap <host>")
	}
	return remote(args[0], true, idmapScript)
}

// moveSource picks the host to move from when --from is not given. It needs
// complete discovery: an unreachable host might hold another copy.
func moveSource(s Service, p placement) (string, error) {
	switch {
	case len(p.unreachable) > 0:
		return "", fmt.Errorf("cannot confirm where %s is installed: %s did not answer; pass --from", s.Name, strings.Join(p.unreachable, ", "))
	case len(p.found) > 1:
		return "", fmt.Errorf("%s is installed on several hosts (%s); pass --from", s.Name, strings.Join(p.found, ", "))
	case len(p.found) == 0:
		return "", fmt.Errorf("%s is not installed on any host; nothing to move", s.Name)
	}
	return p.found[0], nil
}

// nginxDir is the host nginx include dir (see host-module.nix). A var so
// tests can point it at a temp dir.
var nginxDir = "/var/lib/fleet-containers/nginx"

// nginxSiteScript installs <name>.conf in dir and reloads nginx. The last
// good file is kept as .prev until the new one has passed `nginx -t` and the
// reload; on any failure it is put back, so the next reload (from any other
// deploy, or an nginx restart) still serves the working route. The rejected
// file is kept as .broken for inspection.
func nginxSiteScript(dir, name, conf string) string {
	return fmt.Sprintf(`f=%[1]s/%[2]s.conf
rm -f "$f.new" "$f.broken"
if [ -e "$f" ]; then cp -p "$f" "$f.prev"; else rm -f "$f.prev"; fi
restore_site() {
  cp "$f" "$f.broken" 2>/dev/null || true
  if [ -e "$f.prev" ]; then mv -f "$f.prev" "$f"; else rm -f "$f"; fi
  echo "nginx: new site for %[2]s rejected; kept it as $f.broken and restored the previous one" >&2
}
printf %%s %[3]s > "$f.new"
mv -f "$f.new" "$f"
if ! err=$(nginx -t -c /etc/nginx/nginx.conf 2>&1); then
  echo "$err" >&2
  restore_site
  exit 1
fi
if ! systemctl reload nginx; then
  restore_site
  exit 1
fi
rm -f "$f.prev"
`, dir, name, q(conf))
}

// localHost is the short hostname of this machine; commands aimed at it run
// directly instead of over ssh (no self-ssh keys needed). CONTAINERS_LOCAL_HOST
// overrides it (set it to "-" to always use ssh).
var localHost = func() string {
	if h := os.Getenv("CONTAINERS_LOCAL_HOST"); h != "" {
		return h
	}
	h, _ := os.Hostname()
	return strings.SplitN(h, ".", 2)[0]
}()

func isLocal(host string) bool { return host != "" && host == localHost }

// hostCmd runs script on host as root (if root) or the ssh user: locally via
// bash (sudo when not already root, which may prompt) when host is this
// machine, otherwise over ssh.
func hostCmd(ctx context.Context, host string, tty, root bool, script string) *exec.Cmd {
	if !isLocal(host) {
		return exec.CommandContext(ctx, "ssh", sshArgs(host, tty, script, root)...)
	}
	if root && os.Geteuid() != 0 {
		return exec.CommandContext(ctx, "sudo", "bash", "-c", script)
	}
	return exec.CommandContext(ctx, "bash", "-c", script)
}

// Boot-time start is a symlink in the mutable unit dir's .wants directory
// (extra-container: machines.target, podman: multi-user.target). `stop`
// removes it so a stopped service stays stopped after a reboot; `start`,
// `restart` and `deploy` put it back. A service that crashed is still
// wanted, so it starts again on boot (and Restart=on-failure covers crashes
// in between).
var mutableUnits = "/etc/systemd-mutable/system" // var for tests

// holdDir holds markers that keep a storage guard (host-module.nix
// ringofstorms.containers.guards) from starting a service again. stop, move
// and backup write one before stopping; start/restart/deploy clear it. It is
// in /run, so a reboot clears it (the boot link then decides).
var holdDir = "/run/fleet-containers/hold" // var for tests

// The marker is written under the per-service lock the guard holds while it
// checks and enqueues a start, so a guard start is either queued before the
// hold (and the stop that follows supersedes it) or sees the hold.
func holdScript(s Service) string {
	return fmt.Sprintf("mkdir -p %[1]s && (flock 9 && touch %[2]s) 9>%[3]s\n",
		q(holdDir), q(holdDir+"/"+s.Name), q(holdDir+"/"+s.Name+".lock"))
}

func unholdScript(s Service) string {
	return "rm -f " + q(holdDir+"/"+s.Name) + "\n"
}

func wantsLink(s Service) string {
	target := "machines.target"
	if s.Kind == "podman" {
		target = "multi-user.target"
	}
	return mutableUnits + "/" + target + ".wants/" + unitOf(s)
}

func disableScript(s Service) string {
	return holdScript(s) + "rm -f " + q(wantsLink(s)) + "\n"
}

func enableScript(s Service) string {
	l := wantsLink(s)
	return unholdScript(s) + fmt.Sprintf("if [ -e %[1]s ]; then mkdir -p \"$(dirname %[2]s)\" && ln -sfn ../%[3]s %[2]s; fi\n",
		q(mutableUnits+"/"+unitOf(s)), q(l), unitOf(s))
}

// installScript installs/starts $out (already built) and makes sure it also
// starts on boot. extra-container skips recreating the machines.target.wants
// link when the build is unchanged, so `stop` then a same-build `deploy`
// would run now but not after a reboot; enableScript restores it.
func installScript(s Service) string {
	var b string
	if s.Kind == "podman" {
		b = `"$out/bin/fleet-install"` + "\n"
	} else {
		b = `"$out/bin/container" create --start` + "\n"
	}
	return b + enableScript(s) + fmt.Sprintf("systemctl is-active %s\n", unitOf(s))
}

// ------------------------------------------------------------------ prompts

var stdin = bufio.NewReader(os.Stdin)

// interactive reports whether stdin is a terminal we can ask questions on.
func interactive() bool {
	st, err := os.Stdin.Stat()
	if err != nil || st.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	// /dev/null is a character device too
	if dn, err := os.Stat(os.DevNull); err == nil && os.SameFile(st, dn) {
		return false
	}
	return true
}

func prompt(q, def string) string {
	if def != "" {
		fmt.Fprintf(os.Stderr, "%s [%s]: ", q, def)
	} else {
		fmt.Fprintf(os.Stderr, "%s: ", q)
	}
	l, _ := stdin.ReadString('\n')
	if l = strings.TrimSpace(l); l == "" {
		return def
	}
	return l
}

// confirm asks a yes/no question (default no). Without a terminal it
// answers no, so scripts must pass --yes.
func confirm(q string) bool {
	if !interactive() {
		fmt.Fprintf(os.Stderr, "%s [y/N]: no terminal, assuming no (pass --yes)\n", q)
		return false
	}
	a := strings.ToLower(prompt(q+" [y/N]", ""))
	return a == "y" || a == "yes"
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return h + p[1:]
		}
	}
	return p
}

// backupDest picks the backup file. -o wins (a directory or a file);
// otherwise ask for a directory, defaulting to ~/backups. The directory is
// created if missing.
func backupDest(o, name string, yes bool) (string, error) {
	dir := ""
	if o != "" {
		o = expandHome(o)
		if st, err := os.Stat(o); (err == nil && st.IsDir()) || strings.HasSuffix(o, "/") {
			dir = o
		} else {
			if err := os.MkdirAll(filepath.Dir(o), 0o755); err != nil {
				return "", err
			}
			return o, nil
		}
	} else {
		dir = "~/backups"
		if !yes && interactive() {
			dir = prompt("Save backup in directory", dir)
		}
		dir = expandHome(dir)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(dir, name), nil
}

// ------------------------------------------------------------------ status

// detailScript prints KEY<TAB>value lines about one service on a host:
// statusScript (needs no privileges) followed by dataScript (du/stat on the
// data dirs, which may need root).
func detailScript(s Service) string { return statusScript(s) + dataScript(s) }

// statusScript reads unit state, ports and the nginx site. All of it is
// world-readable, so it runs as the login user without sudo.
func statusScript(s Service) string {
	u := unitOf(s)
	var b strings.Builder
	fmt.Fprintf(&b, "u=%s; m=%s; wl=%s\n", q(u), q(mutableUnits+"/"+u), q(wantsLink(s)))
	b.WriteString(`for p in ActiveState SubState ActiveEnterTimestamp MemoryCurrent NRestarts Restart; do printf '%s\t%s\n' "$p" "$(systemctl show -p $p --value "$u" 2>/dev/null)"; done
printf 'Installed\t%s\n' "$( [ -e "$m" ] && echo yes || echo no)"
printf 'BootStart\t%s\n' "$( [ -e "$wl" ] && echo yes || echo no)"
`)
	fmt.Fprintf(&b, "ports=/var/lib/fleet-containers/ports/%s\n", s.Name)
	b.WriteString(`[ -r "$ports" ] && while read -r pr po _; do case "$pr" in tcp|udp) ;; *) continue ;; esac; [ -n "$po" ] && printf 'Port\t%s/%s\n' "$po" "$pr"; done < "$ports"
`)
	fmt.Fprintf(&b, "n=%s/%s.conf\n", q(nginxDir), s.Name)
	b.WriteString(`if [ -r "$n" ]; then while IFS= read -r l; do printf 'Nginx\t%s\n' "$l"; done < "$n"; fi
[ -e "$n.broken" ] && printf 'NginxBroken\t%s\n' "$n.broken"
true
`)
	return b.String()
}

// dataScript sizes the persisted data dirs. These are often owned by the
// container's uid, so cmdDetail tries it under sudo -n first.
func dataScript(s Service) string {
	var b strings.Builder
	keys := make([]string, 0, len(s.Persist))
	for k := range s.Persist {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		d := dataDir(s) + "/" + k
		fmt.Fprintf(&b, "d=%s; if [ -d \"$d\" ]; then printf 'Data\\t%%s\\t%%s\\t%%s\\t%%s\\n' %s %s \"$(du -sb \"$d\" 2>/dev/null | cut -f1)\" \"$(stat -c '%%u:%%g' \"$d\")\"; else printf 'Data\\t%%s\\t%%s\\t-\\tmissing\\n' %s %s; fi\n",
			q(d), q(k), q(s.Persist[k]), q(k), q(s.Persist[k]))
	}
	return b.String()
}

func cmdDetail(args []string) error {
	f := parse(args)
	if len(f.pos) == 0 {
		return errors.New("usage: containers status <svc> [--host h]   (containers ls for all services)")
	}
	s := f.svc()
	h := hostForRead(s, f)
	ctx := context.Background()
	// Status needs no privileges, so it never depends on passwordless sudo.
	out, err := remoteOut(ctx, h, false, statusScript(s))
	if err != nil {
		return err
	}
	// Data dirs are often owned by the container uid: try sudo -n, and if
	// that is refused fall back to an unprivileged du (sizes may be partial).
	partial := false
	if ds := dataScript(s); ds != "" {
		data, derr := remoteOut(ctx, h, true, ds)
		if derr != nil {
			partial = true
			var ferr error
			if data, ferr = remoteOut(ctx, h, false, ds); ferr != nil {
				partial = false
				data = "DataUnavailable\t" + oneLine(ferr.Error()) + "\n"
			}
		}
		out += data
	}
	fmt.Print(renderDetail(s, h, out))
	if partial {
		fmt.Println("  (sizes read without root: sudo -n was refused, so unreadable dirs are undercounted)")
	}
	return nil
}

func renderDetail(s Service, h, out string) string {
	kv := map[string]string{}
	var ports, nginx, data []string
	broken := ""
	dataErr := ""
	for _, l := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(l, "\t")
		if !ok {
			continue
		}
		switch k {
		case "Port":
			ports = append(ports, v)
		case "Nginx":
			nginx = append(nginx, v)
		case "NginxBroken":
			broken = v
		case "DataUnavailable":
			dataErr = v
		case "Data":
			data = append(data, v)
		default:
			kv[k] = v
		}
	}
	var b strings.Builder
	declared := s.Host
	if declared == "" {
		declared = "(none)"
	}
	fmt.Fprintf(&b, "%s  (%s)  %s\n", s.Name, s.Kind, s.Description)
	fmt.Fprintf(&b, "  host        %s  (declared: %s)\n", h, declared)
	fmt.Fprintf(&b, "  unit        %s\n", unitOf(s))
	if kv["Installed"] != "yes" {
		b.WriteString("  state       not installed on this host\n")
	} else {
		st := kv["ActiveState"]
		if sub := kv["SubState"]; sub != "" && sub != st {
			st += " (" + sub + ")"
		}
		if kv["ActiveState"] == "active" && kv["ActiveEnterTimestamp"] != "" {
			st += "  since " + kv["ActiveEnterTimestamp"]
		}
		fmt.Fprintf(&b, "  state       %s\n", st)
		if m := humanMem(kv["MemoryCurrent"]); m != "" && kv["ActiveState"] == "active" {
			fmt.Fprintf(&b, "  memory      %s\n", m)
		}
		boot := "yes"
		if kv["BootStart"] != "yes" {
			boot = "no (stopped with `containers stop`; start/deploy re-enable)"
		}
		fmt.Fprintf(&b, "  on boot     %s\n", boot)
		if r := kv["NRestarts"]; r != "" && r != "0" {
			fmt.Fprintf(&b, "  restarts    %s (Restart=%s)\n", r, kv["Restart"])
		}
	}
	b.WriteString("\nports opened in the host firewall\n")
	if len(ports) == 0 {
		b.WriteString("  (none)\n")
	}
	for _, p := range ports {
		fmt.Fprintf(&b, "  %s\n", p)
	}
	fmt.Fprintf(&b, "\nnginx site on the host (%s/%s.conf)\n", nginxDir, s.Name)
	if len(nginx) == 0 {
		b.WriteString("  (none)\n")
	}
	for _, l := range nginx {
		fmt.Fprintf(&b, "  %s\n", l)
	}
	if broken != "" {
		fmt.Fprintf(&b, "  ! last rejected update kept at %s\n", broken)
	}
	fmt.Fprintf(&b, "\ndata (bind mounts; this is what backup/move copy): %s\n", dataDir(s))
	if dataErr != "" {
		fmt.Fprintf(&b, "  (unavailable: %s)\n", dataErr)
		return b.String()
	}
	if len(data) == 0 {
		b.WriteString("  (no persisted dirs; nothing to back up)\n")
	}
	tw := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "  KEY\tIN CONTAINER\tSIZE\tOWNER")
	for _, d := range data {
		p := strings.Split(d, "\t")
		for len(p) < 4 {
			p = append(p, "")
		}
		size := p[2]
		if size != "-" {
			size = humanMem(size)
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\n", p[0], p[1], size, p[3])
	}
	tw.Flush()
	return b.String()
}

// capDir lists what a host offers (host-module.nix capabilities).
var capDir = "/etc/fleet-containers/capabilities" // var for tests

// requiresScript fails unless the host offers everything the service
// requires. Runs before anything is stopped or installed.
func requiresScript(s Service, host string) string {
	if len(s.Requires) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("missing=\n")
	for _, r := range s.Requires {
		fmt.Fprintf(&b, "[ -e %s ] || missing=\"$missing %s\"\n", q(capDir+"/"+r), r)
	}
	fmt.Fprintf(&b, "if [ -n \"$missing\" ]; then echo \"%s requires:$missing, which %s does not offer (ringofstorms.containers.capabilities)\" >&2; exit 1; fi\n", s.Name, host)
	return b.String()
}

// backupStopScript holds the service, then stops it with a blocking stop no
// matter what is-active says: a guard start may be queued (--no-block) or the
// unit still activating, and a stop job replaces a pending start. It remembers
// to start it again if it was active, activating or had a start queued.
func backupStopScript(s Service) string {
	return holdScript(s) + fmt.Sprintf(`st=$(systemctl is-active %[1]s || true)
if [ "$st" != inactive ] && [ "$st" != failed ] || [ -n "$(systemctl list-jobs --no-legend %[1]s 2>/dev/null || true)" ]; then
  touch /var/lib/fleet-containers/%[2]s.was-running
fi
systemctl stop %[1]s
`, unitOf(s), s.Name)
}

// oneLine collapses an error message so it fits one KEY<TAB>value line.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }
