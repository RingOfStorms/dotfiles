package tailnet

import (
	"net/netip"
	"testing"

	"tailscale.com/ipn/ipnstate"
)

// The Host check is what stops DNS rebinding: a page on another site that
// resolves its own name to this node's IP reaches it from a tailnet browser
// with that site's name in Host.
func TestHostIn(t *testing.T) {
	v4 := netip.MustParseAddr("100.64.0.7")
	v6 := netip.MustParseAddr("fd7a:115c:a1e0::7")
	hosts := allowedHosts(&ipnstate.Status{
		TailscaleIPs: []netip.Addr{v4, v6},
		Self:         &ipnstate.PeerStatus{DNSName: "Tmux-Mac.net.example.com."},
	})

	for _, tc := range []struct {
		host string
		want bool
	}{
		{"tmux-mac", true},
		{"tmux-mac:80", true},
		{"tmux-mac.net.example.com", true},
		{"TMUX-MAC.net.example.com.:8080", true},
		{"100.64.0.7", true},
		{"100.64.0.7:80", true},
		{"[fd7a:115c:a1e0::7]:80", true},
		{"[fd7a:115c:a1e0:0:0::7]", true},

		{"", false},
		{"evil.example", false},
		{"evil.example:80", false},
		{"tmux-mac.evil.example", false},
		{"net.example.com", false},
		{"100.64.0.8", false},
		{"localhost", false},
	} {
		if got := hostIn(hosts, tc.host); got != tc.want {
			t.Errorf("hostIn(%q) = %v, want %v", tc.host, got, tc.want)
		}
	}
}

func TestHostInBeforeLogin(t *testing.T) {
	// No status yet: nothing is accepted.
	for _, h := range []map[string]bool{nil, allowedHosts(nil), allowedHosts(&ipnstate.Status{})} {
		if hostIn(h, "tmux-mac") || hostIn(h, "") {
			t.Fatalf("empty host set accepted a Host: %v", h)
		}
	}
}
