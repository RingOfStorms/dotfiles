package overrides

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"sync"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/bunny"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgestream"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgevhost"
)

// BunnyDNS adapts bunny.Client to DNS for one zone.
type BunnyDNS struct {
	Client *bunny.Client
	Domain string
}

func (b *BunnyDNS) Zone(ctx context.Context) (*bunny.Zone, error) {
	return b.Client.ZoneByDomain(ctx, b.Domain)
}

func (b *BunnyDNS) Create(ctx context.Context, zoneID int64, name, value string, ttl int) (int64, error) {
	return b.Client.CreateRecord(ctx, zoneID, name, "CNAME", value, ttl)
}

func (b *BunnyDNS) Delete(ctx context.Context, zoneID, id int64) error {
	return b.Client.DeleteRecord(ctx, zoneID, id)
}

// SSHEdge pushes requests to o002's receivers over the restricted key. The
// forced command (fleet-edge-receive) dispatches on the remote command line:
// `fleet-stream-receive` reaches the stream receiver, anything else the vhost
// receiver; the request is on stdin. The expose authority and the placement
// reconciler share one SSHEdge, and it runs one request at a time: each
// receiver's reload-pending marker assumes nobody else is changing its
// directory mid-reload, and one nginx reload serves both.
type SSHEdge struct {
	Target     string // root@o002
	KeyFile    string
	KnownHosts string
	SSH        string // ssh binary
	mu         sync.Mutex
}

// Do sends one vhost request (internal/edgevhost).
func (e *SSHEdge) Do(ctx context.Context, r edgevhost.Request) ([]byte, error) {
	body, _ := json.Marshal(r)
	return e.run(ctx, "fleet-vhost-receive", body)
}

// DoStream sends one stream request (internal/edgestream).
func (e *SSHEdge) DoStream(ctx context.Context, r edgestream.Request) ([]byte, error) {
	body, _ := json.Marshal(r)
	return e.run(ctx, "fleet-stream-receive", body)
}

func (e *SSHEdge) run(ctx context.Context, command string, body []byte) ([]byte, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	ssh := e.SSH
	if ssh == "" {
		ssh = "ssh"
	}
	c := exec.CommandContext(ctx, ssh, "-i", e.KeyFile, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
		"-o", "UserKnownHostsFile="+e.KnownHosts, "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
		e.Target, command)
	c.Stdin = bytes.NewReader(body)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	if err := c.Run(); err != nil {
		return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// HTTPStatus fetches a host's fleet-agent /status.json.
func HTTPStatus(urlFor func(host string) (string, bool)) HostStatus {
	return func(ctx context.Context, host string) ([]HostOverride, error) {
		u, ok := urlFor(host)
		if !ok {
			return nil, fmt.Errorf("no status url for %s", host)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil, fmt.Errorf("%s: %s", u, resp.Status)
		}
		var doc struct {
			Overrides *[]HostOverride `json:"overrides"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
			return nil, err
		}
		if doc.Overrides == nil {
			return nil, nil
		}
		if *doc.Overrides == nil {
			return []HostOverride{}, nil
		}
		return *doc.Overrides, nil
	}
}
