package bunny

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

// WANIPv4 is the dynamic kind for the router's public IPv4 address.
const WANIPv4 = "wan-ipv4"

// dynamicTypes is the record type each dynamic kind resolves to.
var dynamicTypes = map[string]string{WANIPv4: "A"}

// DefaultIPEchoURLs answer a plain-text request with the caller's address.
var DefaultIPEchoURLs = []string{"https://api.ipify.org", "https://ifconfig.me/ip"}

// cgnat is the shared address space (RFC 6598); the tailnet lives here too.
var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// ResolveDynamic is the spec reduced to the records of one dynamic kind,
// with value filled in: no static records and no retire list, so a plan of
// it can only create or update those records. The receiver is not modified.
func (s *Spec) ResolveDynamic(kind, value string) *Spec {
	out := &Spec{Zone: s.Zone}
	for _, d := range s.Records {
		if d.Dynamic == kind {
			d.Value = value
			out.Records = append(out.Records, d)
		}
	}
	return out
}

// PublicIPv4 asks each echo URL in turn and returns the first answer that
// is a public IPv4 address. hc should dial tcp4 (IPv4Client) so the echo
// service sees the WAN IPv4 address, not an IPv6 one.
func PublicIPv4(ctx context.Context, hc *http.Client, urls []string) (string, error) {
	var errs []string
	for _, u := range urls {
		ip, err := echoIPv4(ctx, hc, u)
		if err == nil {
			return ip, nil
		}
		errs = append(errs, err.Error())
	}
	return "", fmt.Errorf("no public IPv4 address: %s", strings.Join(errs, "; "))
}

func echoIPv4(ctx context.Context, hc *http.Client, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s: %s", url, resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return "", fmt.Errorf("%s: %w", url, err)
	}
	s := strings.TrimSpace(string(b))
	ip := net.ParseIP(s).To4()
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || cgnat.Contains(ip) {
		return "", fmt.Errorf("%s: %q is not a public IPv4 address", url, s)
	}
	return ip.String(), nil
}

// IPv4Client is an HTTP client that only dials IPv4.
func IPv4Client(timeout time.Duration) *http.Client {
	d := &net.Dialer{Timeout: timeout}
	return &http.Client{Timeout: timeout, Transport: &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			return d.DialContext(ctx, "tcp4", addr)
		},
		TLSHandshakeTimeout: timeout,
	}}
}

// DDNS writes the spec's WANIPv4 records with value ip: create or update
// only, nothing else in the zone is planned. It holds the zone lock from
// the read to the last write, so dns-plan --apply and the overrides service
// never interleave, and refuses on a conflict (another record under the
// name). An unchanged zone makes no write.
func DDNS(ctx context.Context, c *Client, spec *Spec, ip, lockPath string, w io.Writer) error {
	r := spec.ResolveDynamic(WANIPv4, ip)
	if len(r.Records) == 0 {
		return fmt.Errorf("spec declares no %s record", WANIPv4)
	}
	unlock, err := Lock(lockPath)
	if err != nil {
		return fmt.Errorf("lock %s: %w", lockPath, err)
	}
	defer unlock()
	z, err := c.ZoneByDomain(ctx, r.Zone)
	if err != nil {
		return err
	}
	ops, err := Ops(z.ID, Plan(r, z))
	if err != nil {
		return err
	}
	if len(ops) == 0 {
		fmt.Fprintf(w, "%s records unchanged (%s)\n", WANIPv4, ip)
		return nil
	}
	return c.Apply(ctx, ops, func(op Op) {
		fmt.Fprintf(w, "%s %s %s: %s -> %s\n", op.Change.Action, op.Change.Name, op.Change.Type, op.Change.Old, op.Change.New)
	})
}

// RunDDNS is `fleet-edge ddns --spec f --key-file f`: one DDNS pass (the
// h005 ddns-update timer runs it).
func RunDDNS(args []string) {
	fs := flag.NewFlagSet("ddns", flag.ExitOnError)
	specFile := fs.String("spec", "", "public DNS spec JSON (dns-records.nix publicSpec)")
	keyFile := fs.String("key-file", "", "file holding the bunny API key")
	lockPath := fs.String("lock", "/run/fleet-edge-bunny/lock", "flock shared with dns-plan --apply and fleet-edge overrides")
	echo := fs.String("ip-urls", strings.Join(DefaultIPEchoURLs, ","), "comma-separated plain-text IP echo URLs, tried in order")
	_ = fs.Parse(args)
	spec, err := LoadSpec(*specFile)
	if err != nil {
		log.Fatal(err)
	}
	key, err := os.ReadFile(*keyFile)
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	ip, err := PublicIPv4(ctx, IPv4Client(15*time.Second), strings.Split(*echo, ","))
	if err != nil {
		log.Fatal(err)
	}
	c := &Client{Key: strings.TrimSpace(string(key))}
	if err := DDNS(ctx, c, spec, ip, *lockPath, os.Stdout); err != nil {
		log.Fatal(err)
	}
}
