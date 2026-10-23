package containers

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The fleet-net-nat ruleset (fleet-net-nat.nft) must load, and its
// tailnet chain must keep the iif/source/edge guards (ROUTING-PLAN §2.1:
// LAN packets to the overlay IP and the o002 edge are not tailnet peers).
func natRules(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("fleet-net-nat.nft")
	if err != nil {
		t.Fatal(err)
	}
	s := strings.ReplaceAll(string(b), "@EDGE4@", "100.64.0.5, 0.0.0.0")
	return strings.ReplaceAll(s, "@LAN4@", "10.12.14.0/24, 0.0.0.0/32")
}

func TestNatRulesGuards(t *testing.T) {
	r := natRules(t)
	for _, want := range []string{
		`fib daddr type local jump tailnet`,
		`iifname "tailscale0" ip saddr 100.64.0.0/10 ip saddr != @edge jump tailnet-peer`,
		`iifname . ip daddr . meta l4proto . th dport @uses jump tailnet-guest`,
		`iifname != "ve-*" iifname != "podman*" fib daddr type local dnat ip to meta l4proto . th dport map @routes`,
	} {
		if !strings.Contains(r, want) {
			t.Errorf("missing guard %q", want)
		}
	}
	// routes_at / routes_from are only consulted behind the guards in
	// prerouting (output = the host itself).
	pre := between(r, "chain prerouting {", "}")
	if strings.Contains(pre, "@routes_at") || strings.Contains(pre, "@routes_from") {
		t.Errorf("prerouting reaches tailnet maps without the guard:\n%s", pre)
	}
	guest := between(r, "chain tailnet-guest {", "}")
	if strings.Contains(guest, "@routes_from") {
		t.Errorf("guest callers must not match allow-listed routes")
	}
}

func between(s, a, b string) string {
	i := strings.Index(s, a)
	if i < 0 {
		return ""
	}
	s = s[i+len(a):]
	if j := strings.Index(s, b); j >= 0 {
		return s[:j]
	}
	return s
}

// nft -c in a private user+net namespace: a real parse/type check without root.
func TestNatRulesLoad(t *testing.T) {
	nft, err := exec.LookPath("nft")
	if err != nil {
		t.Skip("nft not in PATH")
	}
	if _, err := exec.LookPath("unshare"); err != nil {
		t.Skip("unshare not in PATH")
	}
	f := filepath.Join(t.TempDir(), "nat.nft")
	body := "table ip fleet-net-nat {\n" + natRules(t) + "\n}\n" +
		// the elements apply-ports adds, with the same types
		"add element ip fleet-net-nat routes_at { 100.64.0.13 . tcp . 8090 : 10.233.12.2 }\n" +
		"add element ip fleet-net-nat routes_from { 100.64.0.1 . 100.64.0.13 . tcp . 5432 : 10.233.15.2 }\n" +
		"add element ip fleet-net-nat routes { tcp . 3032 : 10.233.11.2 }\n" +
		"add element ip fleet-net-nat routes_lan { tcp . 25565 : 10.233.11.2 }\n" +
		"add element ip fleet-net-nat uses { \"ve-x\" . 100.64.0.13 . tcp . 8090 }\n"
	if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("unshare", "-rn", nft, "-c", "-f", f).CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "Operation not permitted") || strings.Contains(string(out), "unshare failed") {
			t.Skipf("no user namespaces: %s", out)
		}
		t.Fatalf("nft -c: %v\n%s", err, out)
	}
}

// A tailnet peer with no tailnet map match must still reach the public
// @routes DNAT that follows (forgejo ssh 3032): prerouting jumps (never
// gotos) to tailnet, before @routes. Inner gotos would return there too,
// but jump-only keeps that from depending on how tailnet is entered.
func TestNatRulesTailnetFallsThrough(t *testing.T) {
	r := natRules(t)
	if regexp.MustCompile(`(?m)^[^#]*\bgoto `).MatchString(r) {
		t.Fatalf("goto in fleet-net-nat; use jump so prerouting continues")
	}
	pre := between(r, "chain prerouting {", "}")
	j, p := strings.Index(pre, "jump tailnet"), strings.Index(pre, "map @routes")
	if j < 0 || p < 0 || j > p {
		t.Fatalf("prerouting must jump tailnet, then fall through to @routes:\n%s", pre)
	}
}

// H4: lan tcp/udp routes are not in the any-interface @routes; they match
// only LAN sources (not tailscale0, not guests) in prerouting, and real
// tailnet peers behind the tailnet guards.
func TestNatRulesLanScoped(t *testing.T) {
	r := natRules(t)
	pre := between(r, "chain prerouting {", "}")
	want := `iifname != "ve-*" iifname != "podman*" iifname != "tailscale0" ip saddr @lan_src fib daddr type local dnat ip to meta l4proto . th dport map @routes_lan`
	if !strings.Contains(pre, want) {
		t.Fatalf("prerouting lacks the scoped lan rule:\n%s", pre)
	}
	if strings.Count(pre, "@routes_lan") != 1 {
		t.Fatalf("@routes_lan must only appear behind the lan_src guard in prerouting:\n%s", pre)
	}
	if !strings.Contains(between(r, "chain tailnet-peer {", "}"), "map @routes_lan") {
		t.Fatalf("tailnet peers should still reach lan routes")
	}
	if strings.Contains(between(r, "chain tailnet-guest {", "}"), "@routes_lan") {
		t.Fatalf("guests must not reach lan routes via the host")
	}
}
