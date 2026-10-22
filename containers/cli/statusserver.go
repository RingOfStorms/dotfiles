package main

// `containers status-server --listen ADDR`: the per-host read-only status
// endpoint (ROUTING-PLAN.md §5.4). fleet-edge on h005 polls it, so h005
// never needs ssh access to the fleet.
//
// Contract (GET /status.json, consumed by flakes/fleet-edge):
//
//	{"host":"h001","time":"<RFC3339>","services":{
//	  "<svc>":{"unit":"container@x.service","active":"active|inactive|failed","enabled":true,
//	           "lastBackup":"<RFC3339>"}}}   // omitted if never backed up here
//
// lastBackup is the last successful fleet-backup of the service on this host
// (ROUTING-PLAN §9.1), from the stamp fleet-backup writes on success
// (backupStampDir/<svc>); restic is never run here.
//
// Requests have no input: the handler takes no query, body or path
// parameters, and only reads the filesystem and `systemctl show`. Unit
// names come from the filesystem, are checked against a strict pattern and
// are passed to systemctl as argv (no shell).

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var gcrootDir = "/nix/var/nix/gcroots/fleet-containers" // var for tests

type statusService struct {
	Unit    string `json:"unit"`
	Active  string `json:"active"`
	Enabled bool   `json:"enabled"`
	// LastBackup: RFC3339 UTC of the last successful fleet-backup here.
	LastBackup string `json:"lastBackup,omitempty"`
}

type statusDoc struct {
	Host     string                   `json:"host"`
	Time     string                   `json:"time"`
	Services map[string]statusService `json:"services"`
}

var svcNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)

// installedUnits finds the services the CLI installed, from disk only (as
// probeScript does): nixos kind = container@<n>.service in the mutable unit
// dir, podman kind = a gcroot in gcrootDir (fleet-<n>.service). Returns
// service name -> unit.
func installedUnits() map[string]string {
	out := map[string]string{}
	if m, _ := filepath.Glob(filepath.Join(mutableUnits, "container@*.service")); m != nil {
		for _, f := range m {
			n := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "container@"), ".service")
			if svcNameRe.MatchString(n) {
				out[n] = "container@" + n + ".service"
			}
		}
	}
	if es, err := os.ReadDir(gcrootDir); err == nil {
		for _, e := range es {
			if n := e.Name(); svcNameRe.MatchString(n) {
				if _, dup := out[n]; !dup {
					out[n] = "fleet-" + n + ".service"
				}
			}
		}
	}
	return out
}

// bootLink: the wants link `start`/`stop` add and remove (see wantsLink).
func bootLink(unit string) string {
	target := "machines.target"
	if strings.HasPrefix(unit, "fleet-") {
		target = "multi-user.target"
	}
	return mutableUnits + "/" + target + ".wants/" + unit
}

// normActive folds systemd's ActiveState into the contract's three values:
// active/reloading -> active, failed -> failed, everything else
// (inactive, activating, deactivating, unknown) -> inactive.
func normActive(s string) string {
	switch s {
	case "active", "reloading":
		return "active"
	case "failed":
		return "failed"
	}
	return "inactive"
}

// parseShow parses `systemctl show -p Id,ActiveState u1 u2 ...`: blocks of
// key=value lines separated by blank lines. Returns unit -> ActiveState.
func parseShow(out string) map[string]string {
	res := map[string]string{}
	id, st := "", ""
	flush := func() {
		if id != "" {
			res[id] = st
		}
		id, st = "", ""
	}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		l := sc.Text()
		if l == "" {
			flush()
			continue
		}
		k, v, _ := strings.Cut(l, "=")
		switch k {
		case "Id":
			id = v
		case "ActiveState":
			st = v
		}
	}
	flush()
	return res
}

// buildStatus is the pure part: units + systemd states + link check -> doc.
func buildStatus(host string, now time.Time, units map[string]string, states map[string]string, linked func(string) bool, backups map[string]time.Time) statusDoc {
	d := statusDoc{Host: host, Time: now.UTC().Format(time.RFC3339), Services: map[string]statusService{}}
	for n, u := range units {
		ss := statusService{Unit: u, Active: normActive(states[u]), Enabled: linked(bootLink(u))}
		if t, ok := backups[n]; ok {
			ss.LastBackup = t.UTC().Format(time.RFC3339)
		}
		d.Services[n] = ss
	}
	return d
}

// readBackupStamps reads dir/<svc> for the given services. Missing,
// unreadable, oversized or malformed stamps are skipped (reported as never).
func readBackupStamps(dir string, names map[string]string) map[string]time.Time {
	out := map[string]time.Time{}
	for n := range names {
		if !svcNameRe.MatchString(n) {
			continue
		}
		f, err := os.Open(filepath.Join(dir, n))
		if err != nil {
			continue
		}
		b := make([]byte, 512)
		k, _ := f.Read(b)
		f.Close()
		if st, err := parseStamp(string(b[:k])); err == nil {
			out[n] = st.Time
		}
	}
	return out
}

var systemctlShow = func(ctx context.Context, units []string) (string, error) {
	args := append([]string{"show", "--no-pager", "-p", "Id,ActiveState", "--"}, units...)
	var out bytes.Buffer
	c := exec.CommandContext(ctx, "systemctl", args...)
	c.Stdout = &out
	err := c.Run()
	return out.String(), err
}

func currentStatus(ctx context.Context, host string) (statusDoc, error) {
	units := installedUnits()
	names := make([]string, 0, len(units))
	for _, u := range units {
		names = append(names, u)
	}
	sort.Strings(names)
	states := map[string]string{}
	if len(names) > 0 {
		out, err := systemctlShow(ctx, names)
		if err != nil {
			return statusDoc{}, fmt.Errorf("systemctl show: %w", err)
		}
		states = parseShow(out)
	}
	linked := func(p string) bool { _, err := os.Lstat(p); return err == nil }
	return buildStatus(host, time.Now(), units, states, linked, readBackupStamps(backupStampDir, units)), nil
}

func statusHandler(host string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/status.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		d, err := currentStatus(ctx, host)
		if err != nil {
			http.Error(w, "status unavailable", http.StatusServiceUnavailable)
			fmt.Fprintln(os.Stderr, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(d)
	})
	return mux
}

func cmdStatusServer(args []string) error {
	f := parse(args)
	addr := f.vals["listen"]
	if addr == "" {
		return fmt.Errorf("status-server needs --listen ADDR:PORT")
	}
	host := f.vals["host"]
	if host == "" {
		h, err := os.Hostname()
		if err != nil {
			return err
		}
		host = h
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           statusHandler(host),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	fmt.Fprintf(os.Stderr, "status-server: %s on http://%s/status.json\n", host, addr)
	return srv.ListenAndServe()
}
