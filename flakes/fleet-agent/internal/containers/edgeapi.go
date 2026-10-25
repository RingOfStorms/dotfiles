package containers

// Client for h005's fleet-edge-overrides API (public `cnt expose`,
// ROUTING-PLAN §8 step 7, "Public expose design" items 1 and 5).
//
// Auth is per device: a bearer token from $FLEET_EDGE_TOKEN_FILE (default
// below) that h005 only accepts from that device's overlay IPs.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"
	"time"
)

const defaultEdgeTokenFile = "/var/lib/secrets_manager_hydrated/fleet_edge_expose"

var errNoToken = errors.New("no fleet-edge token")

type edgeClient struct {
	base  string
	token string
	http  *http.Client
}

// edgeRow mirrors overrides.Row (the fields the CLI shows).
type edgeRow struct {
	Service   string `json:"service"`
	Route     string `json:"route"`
	Host      string `json:"host"`
	FQDN      string `json:"fqdn"`
	Until     int64  `json:"until"`
	State     string `json:"state"`
	DNS       string `json:"dns"`
	Edge      bool   `json:"edge"`
	Device    string `json:"device"`
	User      string `json:"user"`
	LastError string `json:"lastError"`
}

type edgeVerify struct {
	DNS       map[string]string `json:"dns"`
	Edge      map[string]string `json:"edge"`
	EdgeExtra []string          `json:"edgeExtra"`
	Error     string            `json:"error"`
	// o002's nginx owes a reload: a removed site may still be served.
	EdgeReloadPending bool `json:"edgeReloadPending"`
}

// newEdgeClient reads the device token; errNoToken if the file is missing.
func newEdgeClient() (*edgeClient, error) {
	tf := os.Getenv("FLEET_EDGE_TOKEN_FILE")
	if tf == "" {
		tf = defaultEdgeTokenFile
	}
	b, err := os.ReadFile(tf)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w (%s): public expose needs this device registered on h005 (services.fleet-edge.overrides.devices)", errNoToken, tf)
		}
		return nil, err
	}
	base := os.Getenv("FLEET_EDGE_URL")
	if base == "" {
		base = "https://fleet." + fleetDomain()
	}
	return &edgeClient{base: strings.TrimRight(base, "/"), token: strings.TrimSpace(string(b)),
		http: &http.Client{Timeout: 3 * time.Minute}}, nil
}

func fleetDomain() string {
	if d := os.Getenv("FLEET_DOMAIN"); d != "" {
		return d
	}
	return "joshuabell.xyz"
}

func exposeUser() string {
	if u := os.Getenv("SUDO_USER"); u != "" {
		return u
	}
	return os.Getenv("USER")
}

// edgeHTTPError carries the API's status code.
type edgeHTTPError struct {
	Code int
	Msg  string
}

func (e *edgeHTTPError) Error() string { return fmt.Sprintf("h005 %d: %s", e.Code, e.Msg) }

func (c *edgeClient) do(method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		var e struct {
			Error string `json:"error"`
		}
		msg := strings.TrimSpace(string(raw))
		if json.Unmarshal(raw, &e) == nil && e.Error != "" {
			msg = e.Error
		}
		if ra := resp.Header.Get("Retry-After"); ra != "" {
			msg += " (retry after " + ra + "s)"
		}
		return &edgeHTTPError{resp.StatusCode, msg}
	}
	if out != nil {
		return json.Unmarshal(raw, out)
	}
	return nil
}

type edgeReq struct {
	Service string `json:"service"`
	Route   string `json:"route"`
	Host    string `json:"host"`
	Until   int64  `json:"until"`
	Reason  string `json:"reason,omitempty"`
	User    string `json:"user,omitempty"`
}

func (c *edgeClient) prepare(r edgeReq) error { return c.do("POST", "/api/overrides/prepare", r, nil) }

func (c *edgeClient) commit(r edgeReq) (edgeRow, error) {
	var out struct {
		Row edgeRow `json:"row"`
	}
	err := c.do("POST", "/api/overrides/commit", r, &out)
	return out.Row, err
}

func (c *edgeClient) revoke(svc string) error {
	return c.do("DELETE", "/api/overrides/"+svc+"?user="+exposeUser(), nil, nil)
}

func (c *edgeClient) list(verify bool) ([]edgeRow, *edgeVerify, error) {
	var out struct {
		Rows   []edgeRow   `json:"rows"`
		Verify *edgeVerify `json:"verify"`
	}
	p := "/api/overrides"
	if verify {
		p += "?verify=1"
	}
	err := c.do("GET", p, nil, &out)
	return out.Rows, out.Verify, err
}

// edgeAPI is what exposePublic needs (interface for tests).
type edgeAPI interface {
	prepare(edgeReq) error
	commit(edgeReq) (edgeRow, error)
	revoke(string) error
}

// exposePublic runs the add order: prepare on h005 (validate + reserve, no
// external writes), the host vhost, then commit (h005 checks the host
// reports it, creates the CNAME, pushes o002). A commit failure revokes the
// host side, then revokes on h005: a failed o002 push leaves the h005 row
// Removing (o002 may have applied it) and DELETE drives that cleanup; if it
// still fails, h005's sweep retries. d == 0 is forever.
func exposePublic(c edgeAPI, s Service, route, host string, d time.Duration, reason string, applyHost, revokeHost func() error) error {
	var until int64
	if d > 0 {
		until = time.Now().Add(d).Unix()
	}
	r := edgeReq{Service: s.Name, Route: route, Host: host, Until: until, Reason: reason, User: exposeUser()}
	if err := c.prepare(r); err != nil {
		return fmt.Errorf("h005 refused (nothing changed): %w", err)
	}
	if err := applyHost(); err != nil {
		_ = c.revoke(s.Name) // drop the reservation
		return fmt.Errorf("host vhost on %s: %w", host, err)
	}
	row, err := c.commit(r)
	if err != nil {
		herr := revokeHost()
		_ = c.revoke(s.Name)
		if herr != nil {
			return fmt.Errorf("h005 commit failed: %v; revoking the host side ALSO failed: %v (host expiry still closes it; run cnt expose --revoke %s)", err, herr, s.Name)
		}
		return fmt.Errorf("h005 commit failed, host side revoked: %w", err)
	}
	fmt.Printf("public: https://%s (dns %s, edge %v, ttl 60s; new clients may see NXDOMAIN for a few minutes)\n", row.FQDN, dash(row.DNS), row.Edge)
	return nil
}

// mergeEdge prints h005's view next to the hosts' overrides and returns
// the leftovers (for cnt audit). Host public overrides missing on h005,
// h005 rows missing on their host, o002 files without a row, and rows
// whose DNS/edge isn't live.
func edgeLeftovers(host []override, rows []edgeRow, v *edgeVerify) []string {
	var out []string
	onHost := map[string]bool{}
	for _, o := range host {
		onHost[o.Service+"."+o.Route] = true
	}
	inEdge := map[string]bool{}
	for _, r := range rows {
		inEdge[r.Service+"."+r.Route] = true
		k := r.Service + "." + r.Route
		if r.State == "committed" && !onHost[k] {
			out = append(out, fmt.Sprintf("%s: h005 row (%s) but %s doesn't report the override", k, r.FQDN, r.Host))
		}
		if r.State != "committed" {
			out = append(out, fmt.Sprintf("%s: h005 row in state %s (%s)", k, r.State, dash(r.LastError)))
		}
		if v != nil {
			if st := v.DNS[r.Service]; st != "" && st != "ok" {
				out = append(out, fmt.Sprintf("%s: DNS %s", k, st))
			}
			if st := v.Edge[r.Service]; st != "" && st != "ok" {
				out = append(out, fmt.Sprintf("%s: o002 vhost %s", k, st))
			}
		}
	}
	for _, o := range host {
		if o.Exposure == "public" && !inEdge[o.Service+"."+o.Route] {
			out = append(out, fmt.Sprintf("%s.%s: public on %s but no h005 row (no DNS/edge; closes at host expiry or --revoke)", o.Service, o.Route, o.Host))
		}
	}
	if v != nil {
		if v.EdgeReloadPending {
			out = append(out, "o002: reload pending (nginx may still serve removed sites; the receiver retries on every call and minute)")
		}
		for _, f := range v.EdgeExtra {
			out = append(out, fmt.Sprintf("o002: runtime vhost %s without an h005 row", f))
		}
		if v.Error != "" {
			out = append(out, "verify incomplete: "+v.Error)
		}
	}
	return out
}

func edgeTable(rows []edgeRow, v *edgeVerify, now time.Time) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "H005\tSERVICE\tROUTE\tFQDN\tHOST\tSTATE\tLEFT\tDNS\tEDGE\tDEVICE")
	for _, r := range rows {
		dns, edge := dash(r.DNS), fmt.Sprint(r.Edge)
		if v != nil {
			if x := v.DNS[r.Service]; x != "" {
				dns = x
			}
			if x := v.Edge[r.Service]; x != "" {
				edge = x
			}
		}
		if dns == "mismatch" || edge == "missing" || edge == "reload pending" {
			dns += " MISMATCH"
		}
		fmt.Fprintf(w, "h005\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", r.Service, r.Route, r.FQDN, r.Host, r.State,
			override{Until: r.Until}.left(now), dns, edge, dash(r.Device))
	}
	w.Flush()
	return b.String()
}
