// Package wanforward makes h005's WAN port forwards follow the placement
// registry (containers/PLACEMENT-PLAN.md §5, phase 4a): one DNAT per public
// `via = router` tcp/udp route of a placed service, WAN <port> -> the placed
// host's LAN IP.
//
// Two halves, split at a privilege boundary:
//   - the capability-free fleet-edge-overrides unit (internal/reconcile)
//     writes the wanted set as JSON data (File) into a group-writable dir;
//   - root's `fleet-edge forwards-apply` (hosts/h005/router-forwards.nix)
//     re-checks every entry against the build-time inventory (the route must
//     be a public router route with that proto/port/source; the address is
//     the inventory's lanIp for the host, never taken from the file),
//     renders `table ip fleet-wan-forwards` and swaps it in with one
//     `nft -f` transaction. A missing file is an empty table (closed); an
//     invalid one leaves the table as it is.
//
// The applier records what it applied (Status) for `cnt audit`.
package wanforward

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// Table is the nft table the applier owns (family ip: IPv4 only, like the
// router's forwards always were).
const Table = "fleet-wan-forwards"

// Forward is one wanted forward. Source is "<service>.<route>".
type Forward struct {
	Proto  string `json:"proto"`
	Port   int    `json:"port"`
	Host   string `json:"host"`
	Source string `json:"source"`
}

// Key is "proto/port", unique per forward.
func (f Forward) Key() string { return f.Proto + "/" + strconv.Itoa(f.Port) }

// File is what the reconciler writes.
type File struct {
	Forwards []Forward `json:"forwards"`
}

// Applied is one forward the applier installed.
type Applied struct {
	Forward
	IP string `json:"ip"`
}

// Status is the applier's record of its last run.
type Status struct {
	At       int64     `json:"at"`
	Forwards []Applied `json:"forwards"`
	// Error is the last run's failure; Forwards then still lists what the
	// table held before it (the table was left as it was).
	Error string `json:"error,omitempty"`
}

// IsRouter reports whether rt is forwarded by the router: public, non-http,
// via router.
func IsRouter(rt inventory.Route) bool {
	return rt.Exposure == "public" && rt.Proto != "http" && slices.Contains(rt.Via, "router")
}

// Routes maps every router route's Key to its Source, from the inventory
// (placement-free: every declared route, placed or not).
func Routes(inv *inventory.Inventory) map[string]string {
	out := map[string]string{}
	for svc, s := range inv.Services {
		for rn, rt := range s.Routes {
			if IsRouter(rt) {
				key := Forward{Proto: rt.Proto, Port: rt.Port}.Key()
				if _, duplicate := out[key]; duplicate {
					out[key] = "" // ambiguous inventory claims authorize neither source
				} else {
					out[key] = svc + "." + rn
				}
			}
		}
	}
	return out
}

// LanIP is h's inventory LAN IPv4 ("" if none).
func LanIP(inv *inventory.Inventory, h string) string {
	hi, ok := inv.Hosts[h]
	if !ok || hi.LanIP == nil {
		return ""
	}
	if ip, err := netip.ParseAddr(*hi.LanIP); err != nil || !ip.Is4() {
		return ""
	}
	return *hi.LanIP
}

// Resolve checks f against the inventory and returns the forwards to install,
// sorted by key. Any bad entry rejects the whole file.
func Resolve(inv *inventory.Inventory, f File) ([]Applied, error) {
	routes := Routes(inv)
	seen := map[string]bool{}
	out := make([]Applied, 0, len(f.Forwards))
	for _, fw := range f.Forwards {
		if fw.Port < 1 || fw.Port > 65535 {
			return nil, fmt.Errorf("%s: port out of range", fw.Key())
		}
		if fw.Proto != "tcp" && fw.Proto != "udp" {
			return nil, fmt.Errorf("%s: proto must be tcp or udp", fw.Key())
		}
		src, ok := routes[fw.Key()]
		if !ok || src == "" || src != fw.Source {
			return nil, fmt.Errorf("%s (%s): not a public router route in the inventory", fw.Key(), fw.Source)
		}
		if seen[fw.Key()] {
			return nil, fmt.Errorf("%s: listed twice", fw.Key())
		}
		seen[fw.Key()] = true
		ip := LanIP(inv, fw.Host)
		if ip == "" {
			return nil, fmt.Errorf("%s: host %q has no LAN IP in the inventory", fw.Key(), fw.Host)
		}
		out = append(out, Applied{Forward: fw, IP: ip})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key() < out[j].Key() })
	return out, nil
}

// Render is the nft script that replaces Table atomically (one transaction).
func Render(wan string, fs []Applied) string {
	var b strings.Builder
	fmt.Fprintf(&b, "table ip %s {}\ndelete table ip %s\n", Table, Table)
	fmt.Fprintf(&b, "table ip %s {\n  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;\n", Table)
	for _, f := range fs {
		fmt.Fprintf(&b, "    iifname %q %s dport %d dnat to %s:%d comment %q\n", wan, f.Proto, f.Port, f.IP, f.Port, f.Source)
	}
	b.WriteString("  }\n}\n")
	return b.String()
}

// Read loads a forwards file; a missing file is an empty set.
func Read(path string) (File, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return File{Forwards: []Forward{}}, nil
	}
	if err != nil {
		return File{}, err
	}
	var f File
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return File{}, fmt.Errorf("%s: %v", path, err)
	}
	if f.Forwards == nil {
		return File{}, fmt.Errorf("%s: forwards array is required", path)
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return File{}, fmt.Errorf("%s: trailing JSON data", path)
	}
	return f, nil
}

// Marshal renders f the way it is written (sorted, one stable encoding), so
// an unchanged set is byte-identical.
func Marshal(f File) []byte {
	fs := slices.Clone(f.Forwards)
	if fs == nil {
		fs = []Forward{}
	}
	sort.Slice(fs, func(i, j int) bool { return fs[i].Key() < fs[j].Key() })
	b, _ := json.MarshalIndent(File{Forwards: fs}, "", "  ")
	return append(b, '\n')
}

// WriteAtomic replaces path with b, mode 0644 whatever the umask.
func WriteAtomic(path string, b []byte) error {
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ReadStatus loads the applier's status file.
func ReadStatus(path string) (Status, error) {
	var s Status
	b, err := os.ReadFile(path)
	if err != nil {
		return s, err
	}
	return s, json.Unmarshal(b, &s)
}

// Runner runs `nft -f -` with script on stdin (var for tests).
var Runner = func(script string) error {
	c := exec.Command("nft", "-f", "-")
	c.Stdin = strings.NewReader(script)
	var errb bytes.Buffer
	c.Stdout, c.Stderr = io.Discard, &errb
	if err := c.Run(); err != nil {
		return fmt.Errorf("nft: %v: %s", err, strings.TrimSpace(errb.String()))
	}
	return nil
}

// ApplyConfig wires one forwards-apply run.
type ApplyConfig struct {
	Inventory *inventory.Inventory
	File      string // the reconciler's forwards file
	Status    string // where the applied set is recorded (its dir holds the lock)
	WAN       string // WAN interface name
	LAN       string // LAN interface name (router-isolation constrains forwarding to it)
	Logf      func(format string, args ...any)
}

// Apply validates the file, swaps the table in and records it, under a flock
// beside the status file (the path unit and nftables' reload hook may run it
// at the same time). On any failure the table is left as it is.
func Apply(c ApplyConfig) error {
	logf := c.Logf
	if logf == nil {
		logf = log.Printf
	}
	if c.WAN == "" || c.LAN == "" || c.WAN == c.LAN || c.File == "" || c.Status == "" || c.Inventory == nil {
		return errors.New("forwards-apply: inventory, file, status and distinct wan/lan are required")
	}
	if err := os.MkdirAll(filepath.Dir(c.Status), 0o755); err != nil {
		return err
	}
	lf, err := os.OpenFile(filepath.Join(filepath.Dir(c.Status), ".lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer lf.Close()
	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	prev, _ := ReadStatus(c.Status)
	fail := func(err error) error {
		logf("forwards-apply: %v; table left as it is", err)
		prev.At, prev.Error = time.Now().Unix(), err.Error()
		if prev.Forwards == nil {
			prev.Forwards = []Applied{}
		}
		b, _ := json.MarshalIndent(prev, "", "  ")
		_ = WriteAtomic(c.Status, append(b, '\n'))
		return err
	}
	f, err := Read(c.File)
	if err != nil {
		return fail(err)
	}
	fs, err := Resolve(c.Inventory, f)
	if err != nil {
		return fail(err)
	}
	if err := Runner(Render(c.WAN, fs)); err != nil {
		return fail(err)
	}
	if len(fs) == 0 {
		logf("forwards-apply: applied table ip %s: no forwards", Table)
	}
	for _, a := range fs {
		logf("forwards-apply: applied %s on %s -> %s %s:%d (%s), LAN %s", a.Key(), c.WAN, a.Host, a.IP, a.Port, a.Source, c.LAN)
	}
	b, _ := json.MarshalIndent(Status{At: time.Now().Unix(), Forwards: fs}, "", "  ")
	return WriteAtomic(c.Status, append(b, '\n'))
}
