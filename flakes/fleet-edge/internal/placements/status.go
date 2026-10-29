package placements

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// ServiceState is what a host reports about one service. The two facts must
// stay separate. A move stops the source before it uninstalls it, so an
// installed-but-inactive copy is still a rollback target, and only a confirmed
// uninstall may drop a binding. Health and import ask the other question: a
// stopped copy is not serving, so it must not look like a live placement.
type ServiceState struct {
	Installed bool // the copy exists on the host (its unit is installed)
	Active    bool // the unit is running right now
}

// Running is the predicate for "this host is serving the service": installed
// and active. Commit, health and import all need this one, not either half.
func (s ServiceState) Running() bool { return s.Installed && s.Active }

// HostServices reports the container services a host has installed, with
// whether each is running. A non-nil error means the host could not be asked;
// a caller must then keep what it knows rather than treat the service as
// absent. The map holds installed copies only: a service that is absent was
// confirmed uninstalled.
type HostServices func(ctx context.Context, host string) (map[string]ServiceState, error)

// HTTPHostServices fetches a host's fleet-agent /status.json and keeps the
// container-ish kinds ("" for an old agent, "nixos", "podman"). Host-only
// units live in hostUnits, not services, so they never appear here.
func HTTPHostServices(urlFor func(host string) (string, bool)) HostServices {
	c := &http.Client{Timeout: 10 * time.Second}
	return func(ctx context.Context, host string) (map[string]ServiceState, error) {
		u, ok := urlFor(host)
		if !ok {
			return nil, fmt.Errorf("no status url for %s", host)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		resp, err := c.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil, fmt.Errorf("%s: %s", u, resp.Status)
		}
		var doc struct {
			Host     string `json:"host"`
			Services map[string]struct {
				Kind   string `json:"kind"`
				Active string `json:"active"`
			} `json:"services"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
			return nil, fmt.Errorf("%s: %w", u, err)
		}
		out := make(map[string]ServiceState, len(doc.Services))
		for name, s := range doc.Services {
			switch s.Kind {
			case "", "nixos", "podman":
				// Every entry in the doc is an installed unit; `active` says
				// whether it is running. An old agent without the field
				// reports "" and is read as active, which is what the field
				// meant when it was added: installed implied running.
				out[name] = ServiceState{Installed: true, Active: s.Active == "" || s.Active == "active" || s.Active == "reloading"}
			}
		}
		return out, nil
	}
}
