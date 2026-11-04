// Package tailnet serves the UI from its own node on a Tailscale/Headscale
// tailnet (tsnet, userspace WireGuard: no tailscaled, no TUN device, no root).
//
// Reaching the listener is the authentication. Only tailnet peers can open a
// connection to the node, and the control server's ACLs decide which ones, so
// requests that arrive here skip the app's own login. The one thing the ACLs
// cannot stop is a page on some other site driving a tailnet browser at this
// node through DNS rebinding; Guard closes that by accepting only Host headers
// that name this node.
package tailnet

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"sync"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// Config describes the node.
type Config struct {
	// Hostname is the node name; MagicDNS serves it as <Hostname>.<base domain>.
	Hostname string
	// Dir holds the node's state (its keys). Keeping it keeps the node's name
	// and tailnet IPs across restarts.
	Dir string
	// ControlURL is the coordination server (Headscale); empty uses Tailscale's.
	ControlURL string
	// AuthKeyFile holds a pre-auth key. It is only read when the node has no
	// state yet; without it tsnet falls back to $TS_AUTHKEY, then logs a login URL.
	AuthKeyFile string
	// Addr is the listen address on the node, e.g. ":80".
	Addr string
	Log  *slog.Logger
}

// Node is a running tsnet node with the UI's listener on it.
type Node struct {
	srv *tsnet.Server
	lc  *local.Client
	log *slog.Logger

	mu    sync.Mutex
	hosts map[string]bool
}

// Listen starts the node and opens cfg.Addr on it. It does not wait for the
// node to log in; Up does.
func Listen(cfg Config) (*Node, net.Listener, error) {
	if cfg.Hostname == "" {
		return nil, nil, errors.New("tailnet: hostname is required")
	}
	if cfg.Dir == "" {
		return nil, nil, errors.New("tailnet: state directory is required")
	}
	var authKey string
	if cfg.AuthKeyFile != "" {
		b, err := os.ReadFile(cfg.AuthKeyFile)
		if err != nil {
			return nil, nil, fmt.Errorf("tailnet: auth key: %w", err)
		}
		authKey = strings.TrimSpace(string(b))
	}
	if err := os.MkdirAll(cfg.Dir, 0o700); err != nil {
		return nil, nil, fmt.Errorf("tailnet: state directory: %w", err)
	}
	log := cfg.Log.With("component", "tsnet")
	srv := &tsnet.Server{
		Hostname:   cfg.Hostname,
		Dir:        cfg.Dir,
		ControlURL: cfg.ControlURL,
		AuthKey:    authKey,
		// Login URLs and state changes; the backend's own chatter (Logf) is
		// dropped.
		UserLogf: func(format string, args ...any) { log.Info(fmt.Sprintf(format, args...)) },
	}
	ln, err := srv.Listen("tcp", cfg.Addr)
	if err != nil {
		_ = srv.Close()
		return nil, nil, fmt.Errorf("tailnet: listen %s: %w", cfg.Addr, err)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		_ = ln.Close()
		_ = srv.Close()
		return nil, nil, fmt.Errorf("tailnet: %w", err)
	}
	return &Node{srv: srv, lc: lc, log: log}, ln, nil
}

// Up waits until the node is logged in and returns its MagicDNS name and IPs.
func (n *Node) Up(ctx context.Context) (string, []netip.Addr, error) {
	st, err := n.srv.Up(ctx)
	if err != nil {
		return "", nil, err
	}
	n.setHosts(allowedHosts(st))
	var name string
	if st.Self != nil {
		name = strings.TrimSuffix(st.Self.DNSName, ".")
	}
	return name, st.TailscaleIPs, nil
}

// Close shuts the node down; its listeners close with it.
func (n *Node) Close() error { return n.srv.Close() }

// Guard refuses requests whose Host does not name this node: its MagicDNS
// name, the short name, or one of its tailnet IPs.
func (n *Node) Guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !n.hostAllowed(r.Context(), r.Host) {
			n.log.Warn("request for a foreign Host refused", "host", r.Host, "remote", r.RemoteAddr, "path", r.URL.Path)
			http.Error(w, "this server does not answer for host "+r.Host, http.StatusMisdirectedRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (n *Node) hostAllowed(ctx context.Context, host string) bool {
	n.mu.Lock()
	hosts := n.hosts
	n.mu.Unlock()
	if hostIn(hosts, host) {
		return true
	}
	// A miss re-reads the node's status: the name or IPs may not have been
	// known yet, or the node was renamed on the control server.
	st, err := n.lc.StatusWithoutPeers(ctx)
	if err != nil {
		return false
	}
	hosts = allowedHosts(st)
	n.setHosts(hosts)
	return hostIn(hosts, host)
}

func (n *Node) setHosts(h map[string]bool) {
	n.mu.Lock()
	n.hosts = h
	n.mu.Unlock()
}

// allowedHosts lists the names a browser can legitimately use for this node.
func allowedHosts(st *ipnstate.Status) map[string]bool {
	hosts := make(map[string]bool)
	if st == nil {
		return hosts
	}
	if st.Self != nil {
		if fqdn := strings.ToLower(strings.TrimSuffix(st.Self.DNSName, ".")); fqdn != "" {
			hosts[fqdn] = true
			short, _, _ := strings.Cut(fqdn, ".")
			hosts[short] = true
		}
		for _, ip := range st.Self.TailscaleIPs {
			hosts[ip.String()] = true
		}
	}
	for _, ip := range st.TailscaleIPs {
		hosts[ip.String()] = true
	}
	return hosts
}

// hostIn reports whether a Host header names one of hosts, ignoring the port,
// case, a trailing dot and the spelling of an IPv6 address.
func hostIn(hosts map[string]bool, host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		host = ip.String()
	}
	return hosts[host]
}
