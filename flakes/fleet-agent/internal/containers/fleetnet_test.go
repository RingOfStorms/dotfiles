package containers

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func fleetNetRules(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("fleet-net.nft")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Routed traffic TO a guest (a LAN/tailnet host using this host as next hop
// for 10.233.0.0/16 or podman0) must be filtered, not only traffic from
// guests: otherwise it bypasses nginx ACLs and the DNAT guards.
func TestFleetNetIngressGuard(t *testing.T) {
	r := fleetNetRules(t)
	fwd := between(r, "chain forward {", "}")
	for _, want := range []string{
		`oifname @guests jump guest-ingress`,
		`ip daddr 10.233.0.0/16 jump guest-ingress`,
		`oifname "podman0" jump guest-ingress`,
	} {
		if !strings.Contains(fwd, want) {
			t.Errorf("forward lacks %q:\n%s", want, fwd)
		}
	}
	in := between(r, "chain guest-ingress {", "}")
	lines := []string{}
	for _, l := range strings.Split(in, "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			lines = append(lines, l)
		}
	}
	if len(lines) == 0 || !strings.HasPrefix(lines[len(lines)-1], "counter drop") {
		t.Fatalf("guest-ingress must end in an unconditional drop:\n%s", in)
	}
	for _, l := range lines[:len(lines)-1] {
		if !strings.HasSuffix(strings.Split(l, " comment ")[0], "return") {
			t.Errorf("guest-ingress may only return early or drop, got %q", l)
		}
		if strings.Contains(l, "accept") {
			t.Errorf("accept in guest-ingress skips nixos-fw: %q", l)
		}
	}
	for _, want := range []string{"ct state established,related return", "ct status dnat return", "@egress return"} {
		if !strings.Contains(in, want) {
			t.Errorf("guest-ingress lacks %q", want)
		}
	}
}

func TestFleetNetLoad(t *testing.T) {
	nft, err := exec.LookPath("nft")
	if err != nil {
		t.Skip("nft not in PATH")
	}
	if _, err := exec.LookPath("unshare"); err != nil {
		t.Skip("unshare not in PATH")
	}
	f := filepath.Join(t.TempDir(), "net.nft")
	body := "table inet fleet-net {\n" + fleetNetRules(t) + "\n}\n" +
		"add element inet fleet-net guests { \"ve-arr\" }\n" +
		"add element inet fleet-net egress { \"ve-x\" . 10.233.7.2 . tcp . 8094 }\n"
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
