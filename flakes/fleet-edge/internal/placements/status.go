package placements

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// HostServices reports the container services a host runs right now. A
// non-nil error means the host could not be asked; a caller must then keep
// what it knows rather than treat the service as absent.
type HostServices func(ctx context.Context, host string) (map[string]bool, error)

// HTTPHostServices fetches a host's fleet-agent /status.json and keeps the
// container-ish kinds ("" for an old agent, "nixos", "podman"). Host-only
// units live in hostUnits, not services, so they never appear here.
func HTTPHostServices(urlFor func(host string) (string, bool)) HostServices {
	c := &http.Client{Timeout: 10 * time.Second}
	return func(ctx context.Context, host string) (map[string]bool, error) {
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
				Kind string `json:"kind"`
			} `json:"services"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
			return nil, fmt.Errorf("%s: %w", u, err)
		}
		out := make(map[string]bool, len(doc.Services))
		for name, s := range doc.Services {
			switch s.Kind {
			case "", "nixos", "podman":
				out[name] = true
			}
		}
		return out, nil
	}
}
