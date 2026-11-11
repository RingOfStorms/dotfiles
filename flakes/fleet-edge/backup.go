package main

import (
	"encoding/json"
	"fmt"
	"os"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/authority"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
)

// backupSpec is the overrides --backup file (hosts/h005/fleet-edge.nix).
type backupSpec struct {
	// Writers names override writers that may also write backup policy.
	Writers      []string                    `json:"writers"`
	Readers      map[string]authority.Writer `json:"readers"`
	Targets      map[string]authority.Writer `json:"targets"`
	HostSubjects map[string][]string         `json:"hostSubjects"`
}

// newBackup builds the backup authority with its three allowlists.
func newBackup(path string, overrideWriters map[string]authority.Writer, v authority.TokenVerifier, inv *inventory.Inventory,
	stateDir string, snap func() placements.Export) (*backup.Service, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var spec backupSpec
	if err := json.Unmarshal(b, &spec); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	ws := map[string]authority.Writer{}
	for _, h := range spec.Writers {
		w, ok := overrideWriters[h]
		if !ok {
			return nil, fmt.Errorf("backup writer %s is not an override writer", h)
		}
		ws[h] = w
	}
	mk := func(m map[string]authority.Writer) (*authority.Auth, error) {
		if m == nil {
			m = map[string]authority.Writer{}
		}
		return authority.New(m, v, nil)
	}
	wa, err := mk(ws)
	if err != nil {
		return nil, err
	}
	ta, err := mk(spec.Targets)
	if err != nil {
		return nil, err
	}
	ra, err := mk(spec.Readers)
	if err != nil {
		return nil, err
	}
	owner := map[string]string{}
	for h, names := range spec.HostSubjects {
		for _, n := range names {
			if _, clash := inv.Services[n]; clash {
				return nil, fmt.Errorf("host subject %s collides with a service", n)
			}
			owner[n] = h
		}
	}
	subjects := func() []string {
		var out []string
		for n := range inv.Services {
			out = append(out, n)
		}
		for n := range owner {
			out = append(out, n)
		}
		return out
	}
	owns := func(host, subject string) bool { return ownsSubject(owner, snap(), host, subject) }
	return backup.New(backup.Config{StateDir: stateDir, Writers: wa, Targets: ta, Readers: ra, Subjects: subjects, Owns: owns,
		Placement: func(subject string) (string, string) {
			if h, ok := owner[subject]; ok {
				return h, ""
			}
			return placementOf(snap(), subject)
		}})
}

// ownsSubject: host may read subject's backup policy. Same rule as credential
// fetches (§2.7): the host subject's owner, else the committed host or the
// destination of an in-flight move (its preflight resolves the policy).
func ownsSubject(owner map[string]string, e placements.Export, host, subject string) bool {
	if h, ok := owner[subject]; ok {
		return h == host
	}
	h, pending := placementOf(e, subject)
	return host != "" && (host == h || host == pending)
}

// placementOf is subject's committed host and in-flight move destination
// (BACKUP-PLAN.md §2.7). While a move is prepared (or fenced stale) the
// source stays the committed host and the reserved destination is pending;
// once committed (or retiring) the destination is the host.
func placementOf(e placements.Export, subject string) (host, pending string) {
	for _, r := range e.Rows {
		if r.Service != subject {
			continue
		}
		switch r.State {
		case placements.Prepared, placements.Stale:
			if r.Previous != nil {
				host = r.Previous.Host
			}
			if r.Host != host {
				pending = r.Host
			}
		default:
			host = r.Host
		}
		return host, pending
	}
	return "", ""
}
