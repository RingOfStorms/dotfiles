// Package reconcile makes h005's routing follow the placement registry
// (containers/PLACEMENT-PLAN.md §5, phase 3). It runs in the
// fleet-edge-overrides unit next to the registry and, every pass:
//
//   - writes one hosts file per name into two dnsmasq `hostsdir`s: tailnet
//     (every non-local route -> the placed host's overlay IP) and lan (lan and
//     public routes -> its LAN IP, only for hosts that have one);
//   - pushes the public `via = edge` http routes of placed services to o002's
//     runtime vhost receiver (internal/edgevhost, Kind "placement").
//
// Fail closed, in this order: every add and update lands before anything is
// removed, and a failed add skips that layer's removals for the pass. A fenced
// (stale) row, a host the inventory cannot address, an unreadable registry and
// an unreachable o002 all leave the current answer exactly as it is. Removal
// happens only for a name whose service the registry no longer places (or
// whose route left the inventory), and on o002 only for files this package
// wrote (Kind "placement"), never an expose override.
package reconcile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgevhost"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
)

// Layers.
const (
	Tailnet = "tailnet"
	LAN     = "lan"
	Edge    = "edge"
)

// Check statuses.
const (
	OK      = "ok"
	Missing = "missing" // wanted, not there
	Wrong   = "wrong"   // there, with another address/host (or not ours)
	Extra   = "wrong"   // an unwanted name still exists
	Kept    = "kept"    // left as it is on purpose (stale row, unaddressable host)
	Pending = "pending" // an unreachable receiver or an owed reload
)

// EdgeClient is o002's receiver (overrides.SSHEdge).
type EdgeClient interface {
	Do(ctx context.Context, r edgevhost.Request) ([]byte, error)
}

// Authenticator admits callers of the audit endpoint (authority.Auth).
type Authenticator interface {
	Authenticate(r *http.Request) (authority.Caller, error)
}

// Config wires a Reconciler.
type Config struct {
	Inventory *inventory.Inventory
	// Source is the registry's current export (placements.Service.Snapshot).
	// An error leaves every answer as it is.
	Source func() (placements.Export, error)
	// TailnetDir and LANDir are the dnsmasq hostsdirs; "" skips that layer.
	// They must exist (dnsmasq only watches a hostsdir present at its start),
	// so a missing one is an error, never created here.
	TailnetDir, LANDir string
	// Edge is o002's receiver; nil skips the vhost layer.
	Edge EdgeClient
	// TailnetServer and LANServer ("ip:port") are the dnsmasq instances the
	// audit asks, so it sees what is served rather than what was written.
	// "" checks the files only.
	TailnetServer, LANServer string
	// Lookup resolves fqdn's A records at server (a test seam; nil = net).
	Lookup func(ctx context.Context, server, fqdn string) ([]string, error)
}

// Reconciler is the running loop.
type Reconciler struct {
	cfg  Config
	kick chan struct{}
	mu   sync.Mutex
	// pushedAll: every wanted vhost was pushed once by this process, so later
	// passes only push what o002 is missing or has bound elsewhere. The first
	// pass pushes them all because route settings (body size, timeouts) only
	// change with a rebuild, i.e. a restart; the receiver skips identical files.
	pushedAll bool
	last      Report
}

// Report is one pass.
type Report struct {
	At      int64    `json:"at"`
	Changes []string `json:"changes"`
	Errors  []string `json:"errors"`
}

// New checks the config.
func New(cfg Config) (*Reconciler, error) {
	if cfg.Inventory == nil || cfg.Source == nil {
		return nil, errors.New("reconcile: an inventory and a registry source are required")
	}
	if cfg.Lookup == nil {
		cfg.Lookup = lookupA
	}
	return &Reconciler{cfg: cfg, kick: make(chan struct{}, 1)}, nil
}

// Kick asks for a pass now (after a registry write). Never blocks.
func (r *Reconciler) Kick() {
	select {
	case r.kick <- struct{}{}:
	default:
	}
}

// Run passes at start, every interval and on every Kick until ctx ends.
func (r *Reconciler) Run(ctx context.Context, every time.Duration) {
	r.Pass(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-r.kick:
		}
		r.Pass(ctx)
	}
}

// want is what the registry asks for right now.
type want struct {
	dns     map[string]map[string]string // layer -> fqdn -> ip
	vhosts  map[string]edgevhost.Request // fqdn -> add request
	keep    map[string]map[string]bool   // layer -> fqdn left as it is
	service map[string]string            // fqdn -> service (every inventory route name)
	host    map[string]string            // fqdn -> placed host
	errs    []string
}

func isEdge(rt inventory.Route) bool {
	if rt.Proto != "http" || rt.Exposure != "public" {
		return false
	}
	for _, v := range rt.Via {
		if v == "edge" {
			return true
		}
	}
	return false
}

func (r *Reconciler) desired(exp placements.Export) *want {
	w := &want{
		dns:     map[string]map[string]string{Tailnet: {}, LAN: {}},
		vhosts:  map[string]edgevhost.Request{},
		keep:    map[string]map[string]bool{Tailnet: {}, LAN: {}, Edge: {}},
		service: map[string]string{},
		host:    map[string]string{},
	}
	keepAll := func(fq string, rt inventory.Route) {
		w.keep[Tailnet][fq], w.keep[LAN][fq] = true, true
		if isEdge(rt) {
			w.keep[Edge][fq] = true
		}
	}
	inv := r.cfg.Inventory
	names := make([]string, 0, len(inv.Services))
	for n := range inv.Services {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, svc := range names {
		s := inv.Services[svc]
		routes := make([]string, 0, len(s.Routes))
		for n := range s.Routes {
			routes = append(routes, n)
		}
		sort.Strings(routes)
		for _, rn := range routes {
			rt := s.Routes[rn]
			if rt.Exposure == "local" || rt.FQDN == nil || *rt.FQDN == "" {
				continue
			}
			fq := strings.ToLower(*rt.FQDN)
			if other, dup := w.service[fq]; dup {
				w.errs = append(w.errs, fmt.Sprintf("%s: declared by %s and %s; left as it is", fq, other, svc))
				keepAll(fq, rt)
				continue
			}
			w.service[fq] = svc
			if exp.Stale(svc) {
				keepAll(fq, rt) // fenced: nobody knows who answers, the last answer stands
				continue
			}
			h := exp.Host[svc]
			if h == "" {
				continue // unplaced: no name
			}
			w.host[fq] = h
			hi, ok := inv.Hosts[h]
			if !ok || hi.OverlayIP == nil || *hi.OverlayIP == "" {
				w.errs = append(w.errs, fmt.Sprintf("%s.%s: host %s has no overlay IP in h005's inventory; left as it is", svc, rn, h))
				keepAll(fq, rt)
				continue
			}
			w.dns[Tailnet][fq] = *hi.OverlayIP
			if (rt.Exposure == "lan" || rt.Exposure == "public") && hi.LanIP != nil && *hi.LanIP != "" {
				w.dns[LAN][fq] = *hi.LanIP
			}
			if (rt.Exposure == "lan" || rt.Exposure == "public") && (hi.LanIP == nil || *hi.LanIP == "") {
				w.keep[LAN][fq] = true
				w.errs = append(w.errs, fmt.Sprintf("%s.%s: host %s has no LAN IP; last LAN file kept", svc, rn, h))
			}
			if isEdge(rt) {
				if rt.MaxBody == "" || rt.Timeouts == "" {
					w.errs = append(w.errs, fmt.Sprintf("%s.%s: no maxBody/timeouts in h005's inventory; vhost left as it is", svc, rn))
					w.keep[Edge][fq] = true
					continue
				}
				rb := true
				if rt.RequestBuffering != nil {
					rb = *rt.RequestBuffering
				}
				w.vhosts[fq] = edgevhost.Request{Op: "add", Kind: edgevhost.KindPlacement, FQDN: fq, Host: h,
					MaxBody: rt.MaxBody, Websockets: rt.Websockets, Buffering: rt.Buffering,
					RequestBuffering: rb, Timeouts: rt.Timeouts}
			}
		}
	}
	return w
}

// Pass reconciles once and returns (and keeps, for the audit) what it did.
func (r *Reconciler) Pass(ctx context.Context) Report {
	r.mu.Lock()
	defer r.mu.Unlock()
	rep := Report{At: time.Now().Unix(), Changes: []string{}, Errors: []string{}}
	exp, err := r.cfg.Source()
	if err != nil {
		rep.Errors = append(rep.Errors, "registry: "+err.Error()+"; nothing changed")
	} else {
		w := r.desired(exp)
		rep.Errors = append(rep.Errors, w.errs...)
		for _, l := range []struct{ layer, dir string }{{Tailnet, r.cfg.TailnetDir}, {LAN, r.cfg.LANDir}} {
			if l.dir != "" {
				r.applyDNS(l.layer, l.dir, w, &rep)
			}
		}
		if r.cfg.Edge != nil {
			r.applyEdge(ctx, w, &rep)
		}
	}
	for _, c := range rep.Changes {
		log.Printf("reconcile: %s", c)
	}
	for _, e := range rep.Errors {
		log.Printf("reconcile: error: %s", e)
	}
	r.last = rep
	return rep
}

func hostsLine(ip, fq string) []byte { return []byte(ip + " " + fq + "\n") }

// writeFile replaces path atomically with mode 0644 whatever the umask:
// dnsmasq runs as another user and must read it.
func writeFile(path string, b []byte) error {
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// applyDNS: one file per name, adds and updates first, then removals.
func (r *Reconciler) applyDNS(layer, dir string, w *want, rep *Report) {
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		rep.Errors = append(rep.Errors, fmt.Sprintf("%s: hostsdir %s is missing (dnsmasq watches it only if it exists at start); nothing changed", layer, dir))
		return
	}
	failed := false
	for _, fq := range sortedKeys(w.dns[layer]) {
		ip := w.dns[layer][fq]
		p := filepath.Join(dir, fq)
		line := hostsLine(ip, fq)
		if old, err := os.ReadFile(p); err == nil && bytes.Equal(old, line) {
			continue
		}
		if err := writeFile(p, line); err != nil {
			rep.Errors = append(rep.Errors, fmt.Sprintf("%s: %s: %v", layer, fq, err))
			failed = true
			continue
		}
		rep.Changes = append(rep.Changes, fmt.Sprintf("%s: %s -> %s", layer, fq, ip))
	}
	if failed {
		rep.Errors = append(rep.Errors, layer+": an add failed; removals wait for the next pass")
		return
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		rep.Errors = append(rep.Errors, fmt.Sprintf("%s: %v", layer, err))
		return
	}
	for _, e := range ents {
		name := e.Name()
		if e.IsDir() {
			continue
		}
		// A crashed write's temp file is read by dnsmasq too; ours are never
		// in flight here, so any left is stale.
		if !strings.HasSuffix(name, ".new") {
			if _, ok := w.dns[layer][name]; ok || w.keep[layer][name] {
				continue
			}
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
			rep.Errors = append(rep.Errors, fmt.Sprintf("%s: removing %s: %v", layer, name, err))
			continue
		}
		rep.Changes = append(rep.Changes, fmt.Sprintf("%s: %s removed", layer, name))
	}
}

func (r *Reconciler) list(ctx context.Context) ([]edgevhost.Entry, error) {
	c, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := r.cfg.Edge.Do(c, edgevhost.Request{Op: "list"})
	if err != nil {
		return nil, err
	}
	var live []edgevhost.Entry
	if err := json.Unmarshal(out, &live); err != nil {
		return nil, fmt.Errorf("list: %v", err)
	}
	return live, nil
}

func (r *Reconciler) do(ctx context.Context, req edgevhost.Request) ([]byte, error) {
	c, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	return r.cfg.Edge.Do(c, req)
}

// applyEdge: o002's runtime vhosts, adds before removals, own files only.
// A live expose override owns its name until it expires: the placement add
// is skipped (and refused by the receiver if the expose landed after the
// list), then pushed by the first pass after the expose file is gone.
func (r *Reconciler) applyEdge(ctx context.Context, w *want, rep *Report) {
	live, err := r.list(ctx)
	if err != nil {
		rep.Errors = append(rep.Errors, "o002: "+err.Error()+"; nothing changed")
		return
	}
	have := map[string]edgevhost.Entry{}
	for _, e := range live {
		have[e.FQDN] = e
	}
	now := time.Now()
	failed := false
	for _, fq := range sortedKeys(w.vhosts) {
		req := w.vhosts[fq]
		e, ok := have[fq]
		if ok && e.LiveExpose(now) {
			rep.Changes = append(rep.Changes, fmt.Sprintf("o002: %s kept: expose on %s", fq, e.Host))
			continue
		}
		if r.pushedAll && ok && e.Kind == edgevhost.KindPlacement && e.Host == req.Host && e.Until == 0 {
			continue
		}
		out, err := r.do(ctx, req)
		if err != nil {
			rep.Errors = append(rep.Errors, fmt.Sprintf("o002: %s -> %s: %v", fq, req.Host, err))
			failed = true
			continue
		}
		if kept, cut := bytes.CutPrefix(out, []byte(edgevhost.KeptPrefix)); cut {
			line, _, _ := bytes.Cut(kept, []byte("\n"))
			rep.Changes = append(rep.Changes, fmt.Sprintf("o002: %s kept: %s", fq, line))
			continue
		}
		if !ok || e.Host != req.Host || e.Kind != edgevhost.KindPlacement {
			rep.Changes = append(rep.Changes, fmt.Sprintf("o002: %s -> %s", fq, req.Host))
		}
	}
	if failed {
		rep.Errors = append(rep.Errors, "o002: an add failed; removals wait for the next pass")
		return
	}
	r.pushedAll = true
	for _, e := range live {
		if e.Kind != edgevhost.KindPlacement {
			continue // an expose override, not ours
		}
		if _, ok := w.vhosts[e.FQDN]; ok || w.keep[Edge][e.FQDN] {
			continue
		}
		// Fenced to the placement file this pass listed: an expose added
		// since the list (or a re-pointed file) is kept by the receiver.
		out, err := r.do(ctx, edgevhost.Request{Op: "remove", Kind: edgevhost.KindPlacement, FQDN: e.FQDN, Host: e.Host})
		if err != nil {
			rep.Errors = append(rep.Errors, fmt.Sprintf("o002: removing %s: %v", e.FQDN, err))
			continue
		}
		if bytes.HasPrefix(out, []byte(edgevhost.KeptPrefix)) {
			continue // another owner's file now; not ours to remove
		}
		rep.Changes = append(rep.Changes, fmt.Sprintf("o002: %s removed", e.FQDN))
	}
}

// Check is one name on one layer, for `cnt audit`.
type Check struct {
	Layer   string `json:"layer"`
	FQDN    string `json:"fqdn"`
	Service string `json:"service,omitempty"`
	Host    string `json:"host,omitempty"` // registry's host ("" unplaced)
	Want    string `json:"want,omitempty"` // ip or host; "" = no name
	Got     string `json:"got,omitempty"`
	Status  string `json:"status"`
	Detail  string `json:"detail,omitempty"`
}

// Verify is a fresh comparison of what is served with what the registry
// asks for. It changes nothing.
type Verify struct {
	Checks   []Check  `json:"checks"`
	Errors   []string `json:"errors"`
	LastPass Report   `json:"lastPass"`
}

// Verify reads the hostsdirs, asks both dnsmasq instances and lists o002.
func (r *Reconciler) Verify(ctx context.Context) Verify {
	r.mu.Lock()
	defer r.mu.Unlock()
	v := Verify{Checks: []Check{}, Errors: []string{}, LastPass: r.last}
	exp, err := r.cfg.Source()
	if err != nil {
		v.Errors = append(v.Errors, "registry: "+err.Error())
		return v
	}
	w := r.desired(exp)
	v.Errors = append(v.Errors, w.errs...)
	for _, l := range []struct{ layer, dir, server string }{
		{Tailnet, r.cfg.TailnetDir, r.cfg.TailnetServer},
		{LAN, r.cfg.LANDir, r.cfg.LANServer},
	} {
		if l.dir != "" {
			r.verifyDNS(ctx, l.layer, l.dir, l.server, w, &v)
		}
	}
	if r.cfg.Edge != nil {
		r.verifyEdge(ctx, w, &v)
	}
	sort.SliceStable(v.Checks, func(i, j int) bool {
		if v.Checks[i].Layer != v.Checks[j].Layer {
			return v.Checks[i].Layer < v.Checks[j].Layer
		}
		return v.Checks[i].FQDN < v.Checks[j].FQDN
	})
	return v
}

func (r *Reconciler) verifyDNS(ctx context.Context, layer, dir, server string, w *want, v *Verify) {
	files := map[string]string{}
	ents, err := os.ReadDir(dir)
	if err != nil {
		v.Errors = append(v.Errors, fmt.Sprintf("%s: %v", layer, err))
		return
	}
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			v.Errors = append(v.Errors, fmt.Sprintf("%s: %v", layer, err))
			continue
		}
		files[e.Name()] = strings.TrimSpace(string(b))
	}
	for _, fq := range sortedKeys(w.dns[layer]) {
		ip := w.dns[layer][fq]
		c := Check{Layer: layer, FQDN: fq, Service: w.service[fq], Host: w.host[fq], Want: ip, Got: files[fq], Status: OK}
		switch {
		case files[fq] == "":
			c.Status, c.Detail = Missing, "no hosts file"
		case files[fq] != strings.TrimSpace(string(hostsLine(ip, fq))):
			c.Status, c.Detail = Wrong, "hosts file differs"
		}
		if server != "" {
			got, err := r.cfg.Lookup(ctx, server, fq)
			if err != nil {
				c.Status, c.Detail = Pending, fmt.Sprintf("dnsmasq %s: %v", server, err)
			} else if len(got) != 1 || got[0] != ip {
				c.Status, c.Detail = Wrong, fmt.Sprintf("dnsmasq %s answers %v", server, got)
			}
		}
		v.Checks = append(v.Checks, c)
	}
	for _, fq := range sortedKeys(w.service) {
		if _, wanted := w.dns[layer][fq]; wanted || files[fq] != "" {
			continue
		}
		c := Check{Layer: layer, FQDN: fq, Service: w.service[fq], Host: w.host[fq], Status: OK}
		if w.keep[layer][fq] {
			c.Status, c.Detail = Kept, "fenced row or unaddressable host: last answer stands"
		} else if server != "" {
			got, err := r.cfg.Lookup(ctx, server, fq)
			var dnsErr *net.DNSError
			if err != nil && !(errors.As(err, &dnsErr) && dnsErr.IsNotFound) {
				c.Status, c.Detail = Pending, err.Error()
			} else if len(got) != 0 {
				c.Status, c.Got, c.Detail = Wrong, strings.Join(got, ","), "unwanted dnsmasq answer"
			}
		}
		v.Checks = append(v.Checks, c)
	}
	for _, name := range sortedKeys(files) {
		if _, ok := w.dns[layer][name]; ok {
			continue
		}
		c := Check{Layer: layer, FQDN: name, Service: w.service[name], Host: w.host[name], Got: files[name], Status: Extra}
		if w.keep[layer][name] {
			c.Status, c.Detail = Kept, "fenced row or unaddressable host: last answer stands"
		} else if strings.HasSuffix(name, ".new") {
			c.Detail = "leftover temp file"
		}
		v.Checks = append(v.Checks, c)
	}
}

func (r *Reconciler) verifyEdge(ctx context.Context, w *want, v *Verify) {
	live, err := r.list(ctx)
	if err != nil {
		v.Errors = append(v.Errors, "o002: "+err.Error())
		for _, fq := range sortedKeys(w.vhosts) {
			v.Checks = append(v.Checks, Check{Layer: Edge, FQDN: fq, Service: w.service[fq], Host: w.host[fq], Want: w.host[fq], Status: Pending, Detail: err.Error()})
		}
		return
	}
	have := map[string]edgevhost.Entry{}
	for _, e := range live {
		have[e.FQDN] = e
	}
	now := time.Now()
	for _, fq := range sortedKeys(w.vhosts) {
		req := w.vhosts[fq]
		e, ok := have[fq]
		c := Check{Layer: Edge, FQDN: fq, Service: w.service[fq], Host: req.Host, Want: req.Host, Got: e.Host, Status: OK}
		switch {
		case !ok:
			c.Status, c.Detail = Missing, "no vhost on o002"
		case e.LiveExpose(now):
			c.Status, c.Detail = Kept, "live expose override owns the name until it expires"
		case e.Kind != edgevhost.KindPlacement:
			c.Status, c.Detail = Wrong, "o002 file is an expired or unreadable expose override"
		case e.Host != req.Host:
			c.Status, c.Detail = Wrong, "o002 proxies to another host"
		}
		v.Checks = append(v.Checks, c)
	}
	for _, e := range live {
		if e.Kind != edgevhost.KindPlacement {
			continue
		}
		if _, ok := w.vhosts[e.FQDN]; ok {
			continue
		}
		c := Check{Layer: Edge, FQDN: e.FQDN, Service: w.service[e.FQDN], Host: w.host[e.FQDN], Got: e.Host, Status: Extra}
		if w.keep[Edge][e.FQDN] {
			c.Status, c.Detail = Kept, "fenced row or unaddressable host: last answer stands"
		}
		v.Checks = append(v.Checks, c)
	}
}

// lookupA asks one DNS server for fqdn's A records.
func lookupA(ctx context.Context, server, fqdn string) ([]string, error) {
	res := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "udp", server)
	}}
	c, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ips, err := res.LookupIP(c, "ip4", fqdn+".")
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		out = append(out, ip.String())
	}
	sort.Strings(out)
	return out, nil
}

// Handler serves GET /api/placements/routing (behind h005 nginx, same
// writers as the registry): the Verify above, for `cnt audit`.
func (r *Reconciler) Handler(a Authenticator) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		c, err := a.Authenticate(req)
		if err != nil {
			log.Printf("reconcile: audit denied host=%q sub=%q peer=%q: %v", c.Host, c.Sub, c.Peer, err)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if req.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(r.Verify(req.Context()))
	})
}
