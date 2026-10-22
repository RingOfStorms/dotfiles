// Package state polls each host's status endpoint and merges the results
// with the static inventory into the data the dashboard renders.
//
// Status endpoint contract (to be implemented by the host module,
// ROUTING-PLAN.md §5.4): each host serves, over the tailnet,
//
//	GET <status-url-template with {overlayIp} substituted>
//
//	{
//	  "host": "h001",
//	  "time": "2026-10-17T00:00:00Z",      // RFC3339
//	  "services": {
//	    "<svc>": {
//	      "unit": "container@x",
//	      "active": "active|inactive|failed",
//	      "enabled": true,
//	      "lastBackup": "2026-10-17T03:05:00Z"  // optional: last successful
//	    }                                      // fleet-backup on that host
//	  }
//	}
//
// A host that cannot be reached (timeout, connection refused, non-200,
// bad JSON) is recorded as unreachable; its services simply have no
// entry and the dashboard shows "unknown" for them.
package state

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

// ServiceStatus is one entry of a host status response's "services" map.
type ServiceStatus struct {
	Unit    string `json:"unit"`
	Active  string `json:"active"`
	Enabled bool   `json:"enabled"`
	// LastBackup is RFC3339; empty if the host has no successful
	// fleet-backup of the service (or no backups at all).
	LastBackup string `json:"lastBackup,omitempty"`
}

// BackupStaleAfter: a service whose last successful backup is older than
// this is flagged stale (the nightly job missed at least one run).
const BackupStaleAfter = 36 * time.Hour

// HostStatus is the full JSON document a host's status endpoint returns.
type HostStatus struct {
	Host     string                   `json:"host"`
	Time     string                   `json:"time"`
	Services map[string]ServiceStatus `json:"services"`
}

// HostPoll records the outcome of the most recent poll of one host.
type HostPoll struct {
	Host     string      `json:"host"`
	URL      string      `json:"url"`
	OK       bool        `json:"ok"`
	Error    string      `json:"error,omitempty"`
	PolledAt time.Time   `json:"polledAt"`
	Status   *HostStatus `json:"status,omitempty"`
}

// ServiceView is one row of the merged dashboard state.
type ServiceView struct {
	Name         string            `json:"name"`
	Kind         string            `json:"kind"`
	Description  string            `json:"description"`
	DeclaredHost string            `json:"declaredHost"`
	Active       string            `json:"active"` // "unknown" if no data
	Enabled      *bool             `json:"enabled,omitempty"`
	Unit         string            `json:"unit,omitempty"`
	Routes       []inventory.Route `json:"routes"`
	// Backup: "ok", "stale" (older than BackupStaleAfter), "none" (the host
	// reports the service but no backup) or "unknown" (no data).
	Backup     string     `json:"backup"`
	LastBackup *time.Time `json:"lastBackup,omitempty"`
	BackupAge  string     `json:"backupAge,omitempty"` // e.g. "5h", "2d 3h"
}

// HostView is one row of the /hosts page.
type HostView struct {
	Host      string `json:"host"`
	OverlayIP string `json:"overlayIp"`
	LanIP     string `json:"lanIp"`
	Reachable bool   `json:"reachable"`
	// HasEndpoint is false for hosts not in containerHosts; they are not
	// polled and not counted as reachable or unreachable.
	HasEndpoint bool      `json:"hasEndpoint"`
	Error       string    `json:"error,omitempty"`
	PolledAt    time.Time `json:"polledAt"`
}

// Merged is the full state served by /api/state.json and rendered by the
// templates.
type Merged struct {
	GeneratedAt time.Time     `json:"generatedAt"`
	Services    []ServiceView `json:"services"`
	Hosts       []HostView    `json:"hosts"`
}

// Poller periodically fetches every host's status endpoint and keeps the
// latest Merged view available via Current.
type Poller struct {
	inv        *inventory.Inventory
	urlTmpl    string
	httpClient *http.Client

	mu    sync.RWMutex
	polls map[string]HostPoll // keyed by host name
}

// NewPoller builds a poller for inv, substituting {overlayIp} (and
// {lanIp}, {host} for flexibility) into urlTmpl per host.
func NewPoller(inv *inventory.Inventory, urlTmpl string, timeout time.Duration) *Poller {
	return &Poller{
		inv:        inv,
		urlTmpl:    urlTmpl,
		httpClient: &http.Client{Timeout: timeout},
		polls:      map[string]HostPoll{},
	}
}

func hostURL(tmpl, host string, h inventory.Host) string {
	overlay := ""
	if h.OverlayIP != nil {
		overlay = *h.OverlayIP
	}
	lan := ""
	if h.LanIP != nil {
		lan = *h.LanIP
	}
	r := strings.NewReplacer(
		"{overlayIp}", overlay,
		"{lanIp}", lan,
		"{host}", host,
	)
	return r.Replace(tmpl)
}

// PollOnce fetches every host's status endpoint once and updates state.
func (p *Poller) PollOnce(ctx context.Context) {
	var wg sync.WaitGroup
	for _, name := range p.inv.PolledHosts() {
		name, h := name, p.inv.Hosts[name]
		wg.Add(1)
		go func() {
			defer wg.Done()
			p.pollHost(ctx, name, h)
		}()
	}
	wg.Wait()
}

func (p *Poller) pollHost(ctx context.Context, name string, h inventory.Host) {
	url := hostURL(p.urlTmpl, name, h)
	poll := HostPoll{Host: name, URL: url, PolledAt: time.Now().UTC()}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll)
		return
	}
	resp, err := p.httpClient.Do(req)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		poll.Error = fmt.Sprintf("status %d", resp.StatusCode)
		p.setPoll(name, poll)
		return
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll)
		return
	}
	var st HostStatus
	if err := json.Unmarshal(body, &st); err != nil {
		poll.Error = fmt.Sprintf("bad json: %v", err)
		p.setPoll(name, poll)
		return
	}
	poll.OK = true
	poll.Status = &st
	p.setPoll(name, poll)
}

func (p *Poller) setPoll(name string, poll HostPoll) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.polls[name] = poll
}

// Run polls every interval until ctx is cancelled. It polls once
// immediately before the first sleep.
func (p *Poller) Run(ctx context.Context, interval time.Duration) {
	p.PollOnce(ctx)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.PollOnce(ctx)
		}
	}
}

// Current merges the latest polls with the static inventory into the
// dashboard view. Safe to call concurrently with Run.
func (p *Poller) Current() Merged {
	p.mu.RLock()
	polls := make(map[string]HostPoll, len(p.polls))
	for k, v := range p.polls {
		polls[k] = v
	}
	p.mu.RUnlock()

	return Merge(p.inv, polls)
}

// Merge combines inventory with a set of host polls (keyed by host name)
// into the dashboard view. Exported standalone for testing without a
// running Poller.
func Merge(inv *inventory.Inventory, polls map[string]HostPoll) Merged {
	return MergeAt(inv, polls, time.Now())
}

// MergeAt is Merge with an explicit clock (backup ages).
func MergeAt(inv *inventory.Inventory, polls map[string]HostPoll, now time.Time) Merged {
	m := Merged{GeneratedAt: now.UTC()}

	for name, svc := range inv.Services {
		view := ServiceView{
			Name:         name,
			Kind:         svc.Kind,
			Description:  svc.Description,
			DeclaredHost: svc.Host,
			Active:       "unknown",
			Backup:       "unknown",
		}
		for _, rt := range svc.Routes {
			view.Routes = append(view.Routes, rt)
		}
		if poll, ok := polls[svc.Host]; ok && poll.OK && poll.Status != nil {
			if ss, ok := poll.Status.Services[name]; ok {
				view.Active = ss.Active
				enabled := ss.Enabled
				view.Enabled = &enabled
				view.Unit = ss.Unit
				view.Backup = "none"
				if t, err := time.Parse(time.RFC3339, ss.LastBackup); err == nil {
					t = t.UTC()
					age := now.Sub(t)
					view.LastBackup, view.BackupAge, view.Backup = &t, FormatAge(age), "ok"
					if age > BackupStaleAfter {
						view.Backup = "stale"
					}
				}
			}
		}
		m.Services = append(m.Services, view)
	}

	polled := map[string]bool{}
	for _, n := range inv.PolledHosts() {
		polled[n] = true
	}
	for name, h := range inv.Hosts {
		hv := HostView{Host: name}
		hv.HasEndpoint = polled[name]
		if h.OverlayIP != nil {
			hv.OverlayIP = *h.OverlayIP
		}
		if h.LanIP != nil {
			hv.LanIP = *h.LanIP
		}
		if poll, ok := polls[name]; ok && hv.HasEndpoint {
			hv.Reachable = poll.OK
			hv.Error = poll.Error
			hv.PolledAt = poll.PolledAt
		}
		m.Hosts = append(m.Hosts, hv)
	}

	return m
}

// FormatAge renders a duration coarsely: "<1m", "42m", "5h", "2d 3h".
// Negative ages (clock skew) count as zero.
func FormatAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	days := int(d / (24 * time.Hour))
	h := int((d % (24 * time.Hour)) / time.Hour)
	if h == 0 {
		return fmt.Sprintf("%dd", days)
	}
	return fmt.Sprintf("%dd %dh", days, h)
}
