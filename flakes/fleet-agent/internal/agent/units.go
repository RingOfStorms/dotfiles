// Package agent implements `fleet agent`, the per-host read-only status,
// system metrics, bcachefs, SMART, fail2ban, and journald log server polled by
// fleet-edge over the tailnet.
package agent

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var (
	mutableUnits   = "/etc/systemd-mutable/system"
	gcrootDir      = "/nix/var/nix/gcroots/fleet-containers"
	backupStampDir = "/var/lib/fleet-containers/backup-last"
)

var (
	svcNameRe  = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)
	unitNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,120}\.service$`)
	snapIDRe   = regexp.MustCompile(`^[0-9a-f]{6,64}$`)
)

// StatusService describes one floating container or monitored host unit.
type StatusService struct {
	Unit       string `json:"unit"`
	Active     string `json:"active"`
	Enabled    bool   `json:"enabled"`
	LastBackup string `json:"lastBackup,omitempty"`
	Kind       string `json:"kind,omitempty"` // "nixos" | "podman" | "host"
}

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

func bootLink(unit string) string {
	target := "machines.target"
	if strings.HasPrefix(unit, "fleet-") {
		target = "multi-user.target"
	}
	return mutableUnits + "/" + target + ".wants/" + unit
}

func normActive(s string) string {
	switch s {
	case "active", "reloading":
		return "active"
	case "failed":
		return "failed"
	}
	return "inactive"
}

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

func parseBackupStamp(s string) (time.Time, bool) {
	var t time.Time
	var snapOK bool
	for _, kv := range strings.Fields(s) {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		switch k {
		case "time":
			parsed, err := time.Parse(time.RFC3339, v)
			if err != nil {
				return time.Time{}, false
			}
			t = parsed
		case "snapshot":
			if !snapIDRe.MatchString(v) {
				return time.Time{}, false
			}
			snapOK = true
		}
	}
	if t.IsZero() || !snapOK {
		return time.Time{}, false
	}
	return t, true
}

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
		if ts, ok := parseBackupStamp(string(b[:k])); ok {
			out[n] = ts
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

func collectUnits(ctx context.Context, extraUnits []string) (map[string]StatusService, map[string]StatusService, error) {
	units := installedUnits()
	allSet := map[string]bool{}
	for _, u := range units {
		allSet[u] = true
	}
	validExtra := make([]string, 0, len(extraUnits))
	for _, u := range extraUnits {
		if !strings.HasSuffix(u, ".service") {
			u += ".service"
		}
		if unitNameRe.MatchString(u) {
			validExtra = append(validExtra, u)
			allSet[u] = true
		}
	}
	names := make([]string, 0, len(allSet))
	for u := range allSet {
		names = append(names, u)
	}
	sort.Strings(names)
	states := map[string]string{}
	if len(names) > 0 {
		out, err := systemctlShow(ctx, names)
		if err != nil {
			return nil, nil, err
		}
		states = parseShow(out)
	}
	linked := func(p string) bool { _, err := os.Lstat(p); return err == nil }
	backups := readBackupStamps(backupStampDir, units)

	svcs := map[string]StatusService{}
	for n, u := range units {
		ss := StatusService{
			Unit:    u,
			Active:  normActive(states[u]),
			Enabled: linked(bootLink(u)),
		}
		if t, ok := backups[n]; ok {
			ss.LastBackup = t.UTC().Format(time.RFC3339)
		}
		svcs[n] = ss
	}

	hostUnits := map[string]StatusService{}
	for _, u := range validExtra {
		short := strings.TrimSuffix(u, ".service")
		hostUnits[short] = StatusService{
			Unit:    u,
			Active:  normActive(states[u]),
			Enabled: true,
			Kind:    "host",
		}
	}
	for k, v := range collectSupervisorUnits(ctx) {
		if _, exists := hostUnits[k]; !exists {
			hostUnits[k] = v
		}
	}
	return svcs, hostUnits, nil
}
