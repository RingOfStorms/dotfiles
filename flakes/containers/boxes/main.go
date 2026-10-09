// boxes: deploy, inspect and move floating services from flakes/containers.
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
	DataRoot string             `json:"dataRoot"`
}

var (
	repo    string
	inv     *Inventory
	sshUser string
	dryRun  bool
)

func usage() {
	fmt.Fprint(os.Stderr, `boxes - floating services from flakes/containers

usage: boxes [global flags] <command> [args]

commands:
  ls | status [--all]          where each service runs, declared host vs actual
  watch [--all] [-n secs]      refreshing status view (q / ctrl-c to quit)
  logs <svc> [-n N] [--no-follow] [--host h] [--unit]
                               stream logs (inside the container; --unit = nspawn unit)
  deploy <svc> [--host h] [--local] [--rev REV]
                               deploy or update to the latest pushed definition
  start|stop|restart <svc> [--host h]
                               stop blocks until the container is fully down
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
  --repo URL    flake repo (BOXES_REPO, default `+defaultRepo+`)
                use git+file:///path/to/checkout for local, unpushed work
  --ssh-user U  ssh as this user for every host (BOXES_SSH_USER); default is
                the host's user in hosts/fleet.nix. sudo is skipped for root
  --dry-run     print remote commands instead of running them
`)
}

func main() {
	repo = envOr("BOXES_REPO", defaultRepo)
	sshUser = os.Getenv("BOXES_SSH_USER")
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
	fmt.Fprintf(os.Stderr, "boxes: "+f+"\n", a...)
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
	return repo + sep + "dir=flakes/containers" + func() string {
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
		return "boxes-" + s.Name + ".service"
	}
	return "container@" + s.Name + ".service"
}

func dataDir(s Service) string { return inv.DataRoot + "/" + s.Name }

// userFor is the ssh login for host: --ssh-user / BOXES_SSH_USER if set,
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
	c := exec.Command("ssh", sshArgs(host, true, script, root)...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

// remoteOut runs a script non-interactively and returns stdout.
func remoteOut(ctx context.Context, host string, root bool, script string) (string, error) {
	c := exec.CommandContext(ctx, "ssh", sshArgs(host, false, script, root)...)
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

// hostFor picks --host, else the host where it's running, else the declared host.
func hostFor(s Service, f flags) string {
	if h := f.vals["host"]; h != "" {
		return h
	}
	if s.Host == "" {
		die("%s has no host in service.nix; pass --host", s.Name)
	}
	return s.Host
}

// ---------------------------------------------------------------- status

type row struct {
	host, svc, kind, state, since, mem string
}

const probeScript = `
for u in $(systemctl list-units --all --plain --no-legend 'container@*.service' 'boxes-*.service' | awk '{print $1}'); do
  case "$u" in
    container@.service) continue;;
    # podman services are only those installed by boxes (they have a gcroot);
    # this skips the host module's own units such as boxes-ports.service
    boxes-*.service) n=${u#boxes-}; n=${n%.service}; [ -e "/nix/var/nix/gcroots/boxes/$n" ] || continue;;
  esac
  st=$(systemctl show -p ActiveState --value "$u")
  ts=$(systemctl show -p ActiveEnterTimestamp --value "$u")
  mem=$(systemctl show -p MemoryCurrent --value "$u")
  echo "$u|$st|$ts|$mem"
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
			name = strings.TrimSuffix(strings.TrimPrefix(name, "boxes-"), ".service")
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
	fmt.Fprintln(tw, "SERVICE\tKIND\tDECLARED\tHOST\tSTATE\tUP\tMEM\tNOTE")
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
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, s.Kind, dash(s.Host), "-", "not installed", "-", "-", note)
			continue
		}
		for _, r := range rows {
			note := ""
			switch {
			case !known:
				note = "not in repo"
			case s.Host != "" && r.host != s.Host:
				note = "not on declared host"
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

func colorState(s string) string {
	if os.Getenv("NO_COLOR") != "" {
		return s
	}
	switch s {
	case "active":
		return "\033[32m" + s + "\033[0m"
	case "failed":
		return "\033[31m" + s + "\033[0m"
	case "activating", "deactivating", "reloading":
		return "\033[33m" + s + "\033[0m"
	}
	return s
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
		fmt.Printf("boxes watch  (every %s, q to quit)  %s\r\n\r\n", every, time.Now().Format("15:04:05"))
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
	b.WriteString("test -d /etc/systemd-mutable/system -o -d /var/lib/boxes || { echo 'host is missing the containers host module (inputs.containers.nixosModules.default)'; exit 1; }\n")
	b.WriteString("install -d -m755 /var/lib/boxes/nginx /var/lib/boxes/ports\n")
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
	b.WriteString(fmt.Sprintf("printf %%s %s > /var/lib/boxes/ports/%s\n", q(ports.String()), s.Name))
	b.WriteString("systemctl reload-or-restart boxes-ports.service || true\n")
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
		conf = "# managed by boxes, service " + s.Name + "\n" + conf
		dst := "/var/lib/boxes/nginx/" + s.Name + ".conf"
		b.WriteString(fmt.Sprintf("printf %%s %s > %s.new\n", q(conf), dst))
		b.WriteString(fmt.Sprintf("mv %[1]s.new %[1]s\n", dst))
		b.WriteString(fmt.Sprintf(`if ! nginx -t -c /etc/nginx/nginx.conf 2>/tmp/boxes-nginx.err; then cat /tmp/boxes-nginx.err; mv %[1]s %[1]s.broken; echo "nginx config rejected, kept as %[1]s.broken"; exit 1; fi
systemctl reload nginx
`, dst))
	} else {
		b.WriteString(fmt.Sprintf("if [ -e /var/lib/boxes/nginx/%[1]s.conf ]; then rm -f /var/lib/boxes/nginx/%[1]s.conf; systemctl reload nginx; fi\n", s.Name))
	}
	return b.String()
}

func cleanupScript(s Service) string {
	return fmt.Sprintf(`rm -f /var/lib/boxes/ports/%[1]s
systemctl restart boxes-ports.service nftables.service 2>/dev/null || true
if [ -e /var/lib/boxes/nginx/%[1]s.conf ]; then rm -f /var/lib/boxes/nginx/%[1]s.conf; systemctl reload nginx || true; fi
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
		info("copying %s to %s", out, h)
		if !dryRun {
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
		script += `"$out/bin/boxes-install"` + "\n"
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
	switch verb {
	case "stop":
		info("stopping %s on %s (waits until fully down)", s.Name, h)
		return remote(h, true, "systemctl stop "+unitOf(s)+" && echo stopped: $(systemctl is-active "+unitOf(s)+")")
	case "restart":
		// systemctl restart on container@ is unreliable (nixpkgs#43652).
		return remote(h, true, "systemctl stop "+unitOf(s)+" && systemctl start "+unitOf(s)+" && systemctl is-active "+unitOf(s))
	default:
		return remote(h, true, "systemctl start "+unitOf(s)+" && systemctl is-active "+unitOf(s))
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
	c := exec.Command("ssh", sshArgs(h, false, script, true)...)
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
		pre := hookScript(s) + fmt.Sprintf(`if systemctl is-active -q %[1]s; then touch /var/lib/boxes/%[2]s.was-running; systemctl stop %[1]s; fi
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
		tarErr = backupTo(exec.Command("ssh", sshArgs(h, false, packScript(inv.DataRoot, s.Name), true)...), out)
	}
	if !f.bools["live"] {
		remote(h, true, fmt.Sprintf("if [ -e /var/lib/boxes/%[2]s.was-running ]; then rm -f /var/lib/boxes/%[2]s.was-running; systemctl start %[1]s; fi", unitOf(s), s.Name))
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
		return errors.New("usage: boxes restore <svc> <file> --host h [--force]")
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
	c := exec.Command("ssh", sshArgs(h, false, unpackScript(decomp, inv.DataRoot), true)...)
	c.Stdin, c.Stdout, c.Stderr = in, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		return err
	}
	info("restored. deploy with: boxes deploy %s --host %s", s.Name, h)
	return nil
}

// ---------------------------------------------------------------- move

func cmdMove(args []string) error {
	f := parse(args)
	s := f.svc()
	to := f.vals["to"]
	if to == "" {
		return errors.New("usage: boxes move <svc> --to <host> [--from <host>]")
	}
	from := f.vals["from"]
	if from == "" {
		from = s.Host
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
	if err := remote(from, true, hookScript(s)+"systemctl stop "+unitOf(s)); err != nil {
		return err
	}

	info("3/5 copying %s:%s -> %s (numeric owners kept)", from, dst, to)
	if !dryRun {
		src := exec.Command("ssh", sshArgs(from, false, packScript(inv.DataRoot, s.Name), true)...)
		sink := exec.Command("ssh", sshArgs(to, false, unpackScript("zstd -d -q -c", inv.DataRoot), true)...)
		sum := manifestScript(inv.DataRoot, s.Name)
		err := copyVerified(src, sink,
			func() (string, error) { return remoteOut(context.Background(), from, true, sum) },
			func() (string, error) { return remoteOut(context.Background(), to, true, sum) })
		if err != nil {
			return fmt.Errorf("%w\n%s is stopped on %s with its data intact (boxes start %s --host %s); partial data may be on %s", err, s.Name, from, s.Name, from, to)
		}
	}

	info("4/5 deploying on %s", to)
	if err := deploy(s, to, flakeRef(s.Dir), false); err != nil {
		return fmt.Errorf("%w\n%s is stopped on %s with data intact; start it again with: boxes start %s --host %s", err, s.Name, from, s.Name, from)
	}

	info("5/5 removing %s from %s (data kept as %s.moved-<date>)", s.Name, from, dst)
	rm := uninstallScript(s) + cleanupScript(s) + fmt.Sprintf("mv %s %s.moved-$(date +%%F)\n", q(dst), q(dst))
	if err := remote(from, true, rm); err != nil {
		return fmt.Errorf("cleanup on %s: %w", from, err)
	}
	fmt.Printf("\nDone. Now set host = %q; in flakes/containers/%s/service.nix and push.\n", to, s.Dir)
	fmt.Printf("If the move involves a public route (e.g. the o002 nginx), update it too.\n")
	return nil
}

func uninstallScript(s Service) string {
	if s.Kind == "podman" {
		return fmt.Sprintf("if [ -x /nix/var/nix/gcroots/boxes/%[1]s/bin/boxes-uninstall ]; then /nix/var/nix/gcroots/boxes/%[1]s/bin/boxes-uninstall; fi\n", s.Name)
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
  d=$(mktemp -d "$base/.boxes-idmap.XXXXXX") || { echo "$base: cannot create temp dir"; return 1; }
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
		return errors.New("usage: boxes check-idmap <host>")
	}
	return remote(args[0], true, idmapScript)
}
