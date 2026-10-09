// containers: deploy, inspect and move floating services from containers.
//
// Everything runs over ssh against the fleet hosts; nothing has to be
// installed on the hosts besides the containers host module.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
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
}

type Host struct {
	User      string  `json:"user"`
	OverlayIP *string `json:"overlayIp"`
	LanIP     *string `json:"lanIp"`
}

type Inventory struct {
	Services map[string]Service `json:"services"`
	Hosts    map[string]Host    `json:"hosts"`
	// Hosts with the containers host module; all are probed before the CLI
	// trusts the declared host.
	ContainerHosts []string `json:"containerHosts"`
	DataRoot       string   `json:"dataRoot"`
}

var (
	repo    string
	inv     *Inventory
	sshUser string
	dryRun  bool
)

func usage() {
	fmt.Fprint(os.Stderr, `containers - floating services from containers

usage: containers [global flags] <command> [args]

commands:
  ls | status [--all]          where each service runs, declared host vs actual
  watch [--all] [-n secs]      refreshing status view (q / ctrl-c to quit)
  logs <svc> [-n N] [--no-follow] [--host h] [--unit]
                               stream logs (inside the container; --unit = nspawn unit)
  deploy <svc> [--host h] [--local] [--rev REV]
                               deploy or update to the latest pushed definition
  start|stop|restart <svc> [--host h]
                               stop blocks until fully down and keeps it stopped
                               across reboots; start/restart/deploy re-enable it
  attach <svc> [--host h]      open the service console (if it defines one)
  shell <svc> [--host h]       root shell inside the container
  backup <svc> [--host h] [-o file] [--live]
                               hook, stop, tar data to this machine, start again
  restore <svc> <file> --host h [--force]
                               unpack a backup into /srv/containers/<svc> on a host
  move <svc> --to h [--from h] move data and deployment to another host
  destroy <svc> [--host h] [--purge]
                               remove from a host (data kept unless --purge)
  check-idmap <host>           test idmapped mounts on /srv/containers and /nix
  inventory                    print the inventory JSON

global flags (or env):
  --repo URL    flake repo (CONTAINERS_REPO, default `+defaultRepo+`)
                use git+file:///path/to/checkout for local, unpushed work
  --ssh-user U  ssh as this user for every host (CONTAINERS_SSH_USER); default is
                the host's user in hosts/fleet.nix. sudo is skipped for root
  --dry-run     print remote commands instead of running them
`)
}

func main() {
	repo = envOr("CONTAINERS_REPO", defaultRepo)
	sshUser = os.Getenv("CONTAINERS_SSH_USER")
	args := os.Args[1:]
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
	case "ls", "status", "list":
		err = cmdStatus(rest, false)
	case "watch", "tui":
		err = cmdStatus(rest, true)
	case "logs", "log":
		err = cmdLogs(rest)
	case "deploy", "update":
		err = cmdDeploy(rest)
	case "start", "stop", "restart":
		err = cmdUnit(cmd, rest)
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
	case "destroy", "rm":
		err = cmdDestroy(rest)
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

// sshArgs builds the ssh command for host; root wraps the script in sudo.
func sshArgs(host string, tty bool, script string, root bool) []string {
	a := []string{"-o", "ConnectTimeout=8"}
	if tty {
		a = append(a, "-t")
	} else {
		a = append(a, "-o", "BatchMode=yes")
	}
	user := userFor(host)
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

// hostFor picks --host if given (the explicit escape hatch). Otherwise it
// uses the declared host from service.nix, but only after a complete
// discovery shows the service is installed nowhere else: every container
// host must answer. If one is unreachable, or the service is on another
// host or several hosts, it refuses loudly instead of acting on a guess.
func hostFor(s Service, f flags) string {
	if h := f.vals["host"]; h != "" {
		return h
	}
	if s.Host == "" {
		die("%s has no host in service.nix; pass --host", s.Name)
	}
	if dryRun {
		return s.Host
	}
	if err := checkPlacement(s, locate(s, probe)); err != nil {
		die("%v", err)
	}
	return s.Host
}

// placement is the result of probing every container host for a service.
type placement struct {
	found       []string // hosts where it is installed (any state)
	unreachable []string // hosts that could not be probed
}

// containerHosts are the hosts that may run services: inventory
// containerHosts plus every declared host. All of them are probed.
func containerHosts() []string {
	set := map[string]bool{}
	for _, h := range inv.ContainerHosts {
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

// checkPlacement allows implicit use of the declared host only when discovery
// was complete and the service is either nowhere (first deploy) or only there.
func checkPlacement(s Service, p placement) error {
	elsewhere := slices.DeleteFunc(slices.Clone(p.found), func(h string) bool { return h == s.Host })
	switch {
	case len(elsewhere) > 0:
		return fmt.Errorf(`
!!! %[1]s is declared on %[2]s but installed on %[3]s.
!!! service.nix is out of date (was it moved without updating the repo?).
!!! Refusing to guess. Either:
!!!   - set   host = %[4]q;   in containers/%[5]s/service.nix and push, or
!!!   - pass  --host <host>   to act on a specific host this once.`,
			s.Name, s.Host, strings.Join(p.found, ", "), elsewhere[0], s.Dir)
	case len(p.unreachable) > 0:
		return fmt.Errorf(`
!!! cannot confirm where %[1]s is installed: %[2]s did not answer.
!!! It may be running there (e.g. after a move), so acting on the declared
!!! host %[3]s could start a second copy. Refusing. Either bring
!!! %[2]s back, or pass  --host <host>  to act on a specific host.`,
			s.Name, strings.Join(p.unreachable, ", "), s.Host)
	}
	return nil
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
	hostSet := map[string]bool{}
	for _, s := range inv.Services {
		if s.Host != "" {
			hostSet[s.Host] = true
		}
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
	sort.Strings(sorted)
	for _, n := range sorted {
		s, known := inv.Services[n]
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
			switch {
			case !known:
				note = "not in repo"
			case s.Host != "" && r.host != s.Host:
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
	h := hostFor(s, f)
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
	b.WriteString("install -d -m755 /var/lib/fleet-containers/nginx /var/lib/fleet-containers/ports\n")
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
	for _, p := range s.TCPPorts {
		fmt.Fprintf(&ports, "tcp %d\n", p)
	}
	for _, p := range s.UDPPorts {
		fmt.Fprintf(&ports, "udp %d\n", p)
	}
	b.WriteString(fmt.Sprintf("printf %%s %s > /var/lib/fleet-containers/ports/%s\n", q(ports.String()), s.Name))
	b.WriteString("systemctl reload-or-restart fleet-containers-ports.service || true\n")
	// nginx
	if s.Nginx != nil && strings.TrimSpace(*s.Nginx) != "" {
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
		b.WriteString(fmt.Sprintf("if [ -e /var/lib/fleet-containers/nginx/%[1]s.conf ]; then rm -f /var/lib/fleet-containers/nginx/%[1]s.conf /var/lib/fleet-containers/nginx/%[1]s.conf.prev; systemctl reload nginx; fi\n", s.Name))
	}
	return b.String()
}

func cleanupScript(s Service) string {
	return fmt.Sprintf(`rm -f /var/lib/fleet-containers/ports/%[1]s
systemctl restart fleet-containers-ports.service nftables.service 2>/dev/null || true
if [ -e /var/lib/fleet-containers/nginx/%[1]s.conf ]; then rm -f /var/lib/fleet-containers/nginx/%[1]s.conf; systemctl reload nginx || true; fi
`, s.Name)
}

func cmdDeploy(args []string) error {
	f := parse(args, "local")
	s := f.svc()
	h := hostFor(s, f)
	ref := withRev(flakeRef(s.Dir), f.vals["rev"])
	return deploy(s, h, ref, f.bools["local"])
}

func deploy(s Service, h, ref string, local bool) error {
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
			c := exec.Command("nix", "copy", "--to", "ssh-ng://"+target, out)
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
	if s.Kind == "podman" {
		script += `"$out/bin/fleet-install"` + "\n"
	} else {
		script += `"$out/bin/container" create --start` + "\n"
	}
	script += fmt.Sprintf("systemctl is-active %s\n", unitOf(s))
	if err := remote(h, true, script); err != nil {
		return fmt.Errorf("deploy: %w", err)
	}
	info("%s is running on %s", s.Name, h)
	return nil
}

// ---------------------------------------------------------------- lifecycle

func cmdUnit(verb string, args []string) error {
	f := parse(args)
	s := f.svc()
	h := hostFor(s, f)
	u := unitOf(s)
	switch verb {
	case "stop":
		info("stopping %s on %s (waits until fully down; stays stopped across reboots)", s.Name, h)
		return remote(h, true, disableScript(s)+"systemctl stop "+u+" && echo stopped: $(systemctl is-active "+u+")")
	case "restart":
		// systemctl restart on container@ is unreliable (nixpkgs#43652).
		return remote(h, true, enableScript(s)+"systemctl stop "+u+" && systemctl start "+u+" && systemctl is-active "+u)
	default:
		return remote(h, true, enableScript(s)+"systemctl start "+u+" && systemctl is-active "+u)
	}
}

func cmdAttach(args []string, shell bool) error {
	f := parse(args)
	s := f.svc()
	h := hostFor(s, f)
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
	f := parse(args, "live")
	s := f.svc()
	h := hostFor(s, f)
	out := f.vals["o"]
	if out == "" {
		out = fmt.Sprintf("%s-%s-%s.tar.zst", s.Name, h, time.Now().Format("2006-01-02T1504"))
	}
	if !f.bools["live"] {
		pre := hookScript(s) + fmt.Sprintf(`if systemctl is-active -q %[1]s; then touch /var/lib/fleet-containers/%[2]s.was-running; systemctl stop %[1]s; fi
`, unitOf(s), s.Name)
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
		remote(h, true, fmt.Sprintf("if [ -e /var/lib/fleet-containers/%[2]s.was-running ]; then rm -f /var/lib/fleet-containers/%[2]s.was-running; systemctl start %[1]s; fi", unitOf(s), s.Name))
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
	h := hostFor(s, f)
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

// ---------------------------------------------------------------- move

func cmdMove(args []string) error {
	f := parse(args)
	s := f.svc()
	to := f.vals["to"]
	if to == "" {
		return errors.New("usage: containers move <svc> --to <host> [--from <host>]")
	}
	from := f.vals["from"]
	if from == "" && !dryRun {
		var err error
		if from, err = moveSource(s, locate(s, probe)); err != nil {
			return err
		}
	}
	if from == "" {
		from = s.Host
	}
	if !slices.Contains(containerHosts(), to) {
		return fmt.Errorf("%s is not a container host; add it to containerHosts in containers/flake.nix (and import the host module there) so discovery can see it", to)
	}
	if from == to {
		return fmt.Errorf("%s is already on %s", s.Name, to)
	}
	dst := dataDir(s)

	info("1/5 checking %s", to)
	if err := remote(to, true, fmt.Sprintf(`set -e
test -d /etc/systemd-mutable/system || { echo "%[3]s lacks the containers host module"; exit 1; }
if systemctl is-active -q %[1]s; then echo "%[2]s already running on %[3]s"; exit 1; fi
if [ -e %[4]s ] && [ -n "$(ls -A %[4]s)" ]; then echo "%[4]s already exists on %[3]s; move it away first"; exit 1; fi
install -d -m755 %[5]s`, unitOf(s), s.Name, to, q(dst), q(inv.DataRoot))); err != nil {
		return err
	}

	info("2/5 stopping %s on %s (blocking)", s.Name, from)
	if err := remote(from, true, hookScript(s)+disableScript(s)+"systemctl stop "+unitOf(s)); err != nil {
		return err
	}

	info("3/5 copying %s:%s -> %s (numeric owners kept)", from, dst, to)
	if !dryRun {
		src := hostCmd(context.Background(), from, false, true, packScript(inv.DataRoot, s.Name))
		sink := hostCmd(context.Background(), to, false, true, unpackScript("zstd -d -q -c", inv.DataRoot))
		sum := manifestScript(inv.DataRoot, s.Name)
		err := copyVerified(src, sink,
			func() (string, error) { return remoteOut(context.Background(), from, true, sum) },
			func() (string, error) { return remoteOut(context.Background(), to, true, sum) })
		if err != nil {
			return fmt.Errorf("%w\n%s is stopped on %s with its data intact (containers start %s --host %s); partial data may be on %s", err, s.Name, from, s.Name, from, to)
		}
	}

	info("4/5 deploying on %s", to)
	if err := deploy(s, to, flakeRef(s.Dir), false); err != nil {
		return fmt.Errorf("%w\n%s is stopped on %s with data intact; start it again ONLY after checking %s is not running there (the deploy may have started it before failing): containers ls (and, if it is up there, containers stop %s --host %s), then containers start %s --host %s", err, s.Name, from, to, s.Name, to, s.Name, from)
	}

	info("5/5 removing %s from %s (data kept as %s.moved-<date>)", s.Name, from, dst)
	rm := uninstallScript(s) + cleanupScript(s) + fmt.Sprintf("mv %s %s.moved-$(date +%%F)\n", q(dst), q(dst))
	if err := remote(from, true, rm); err != nil {
		return fmt.Errorf("cleanup on %s: %w", from, err)
	}
	fmt.Print(moveWarning(s, to))
	return nil
}

func uninstallScript(s Service) string {
	if s.Kind == "podman" {
		return fmt.Sprintf("if [ -x /nix/var/nix/gcroots/fleet-containers/%[1]s/bin/fleet-uninstall ]; then /nix/var/nix/gcroots/fleet-containers/%[1]s/bin/fleet-uninstall; fi\n", s.Name)
	}
	return fmt.Sprintf("systemctl stop %s || true\nextra-container destroy %s\n", unitOf(s), s.Name)
}

func cmdDestroy(args []string) error {
	f := parse(args, "purge")
	s := f.svc()
	h := hostFor(s, f)
	script := uninstallScript(s) + cleanupScript(s)
	if f.bools["purge"] {
		script += "rm -rf " + q(dataDir(s)) + "\n"
	}
	info("removing %s from %s%s", s.Name, h, map[bool]string{true: " and DELETING its data"}[f.bools["purge"]])
	return remote(h, true, script)
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

// moveWarning is printed after a successful move. Until service.nix is
// updated, commands without --host refuse to run (see checkPlacement).
func moveWarning(s Service, to string) string {
	bar := strings.Repeat("!", 72)
	return fmt.Sprintf(`
%[1]s
!!! %[2]s now runs on %[3]s, but containers/%[4]s/service.nix still says
!!! host = %[5]q.
!!!
!!! Until you change it to   host = %[3]q;   and push, commands for
!!! %[2]s without --host will refuse to run, and a plain
!!! 'containers deploy %[2]s' would need --host %[3]s.
!!!
!!! Also update any route that pointed at %[5]s
!!! (e.g. the o002 nginx proxy, router port-forwards).
%[1]s
`, bar, s.Name, to, s.Dir, s.Host)
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

func wantsLink(s Service) string {
	target := "machines.target"
	if s.Kind == "podman" {
		target = "multi-user.target"
	}
	return mutableUnits + "/" + target + ".wants/" + unitOf(s)
}

func disableScript(s Service) string {
	return "rm -f " + q(wantsLink(s)) + "\n"
}

func enableScript(s Service) string {
	l := wantsLink(s)
	return fmt.Sprintf("if [ -e %[1]s ]; then mkdir -p \"$(dirname %[2]s)\" && ln -sfn ../%[3]s %[2]s; fi\n",
		q(mutableUnits+"/"+unitOf(s)), q(l), unitOf(s))
}
