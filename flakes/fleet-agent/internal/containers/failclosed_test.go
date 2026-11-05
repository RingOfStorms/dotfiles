package containers

import (
	"errors"
	"strings"
	"testing"
)

func mustPrepare(t *testing.T, s Service, host string) string {
	t.Helper()
	ps, err := prepareScript(s, host)
	if err != nil {
		t.Fatalf("prepareScript(%s): %v", s.Name, err)
	}
	return ps
}

func mustPorts(t *testing.T, s Service, host string) []string {
	t.Helper()
	l, err := portsFileLines(s, host)
	if err != nil {
		t.Fatalf("portsFileLines(%s): %v", s.Name, err)
	}
	return l
}

func mustExceptions(t *testing.T, s Service, host string) []string {
	t.Helper()
	l, err := netExceptions(s, host)
	if err != nil {
		t.Fatalf("netExceptions(%s): %v", s.Name, err)
	}
	return l
}

// usesRig is a private caller "sec" whose net.uses names sso.web, with the
// registry answering via view (nil: unreadable).
func usesRig(t *testing.T, view *placementView, why error) Service {
	t.Helper()
	oldInv, oldNow, oldCache, oldDry := inv, placementNow, registryCache, dryRun
	registryMu.Lock()
	oldSkip, oldWarned, oldOut := registrySkipped, registryWarned, registryWarnOut
	registrySkipped, registryWarned, registryWarnOut = why, true, &strings.Builder{}
	registryMu.Unlock()
	t.Cleanup(func() {
		inv, placementNow, registryCache, dryRun = oldInv, oldNow, oldCache, oldDry
		registryMu.Lock()
		registrySkipped, registryWarned, registryWarnOut = oldSkip, oldWarned, oldOut
		registryMu.Unlock()
	})
	sso := Service{Name: "sso", Routes: map[string]Route{"web": httpRoute("sso", 1, "tailnet", "native")}}
	sec := privSvc("sec", 5)
	sec.Net.Uses = []string{"sso.web"}
	ov := "100.64.0.13"
	inv = &Inventory{
		Services: map[string]Service{"sso": sso, "sec": sec},
		Hosts:    map[string]Host{"h001": {OverlayIP: &ov}, "h003": {OverlayIP: sp("100.64.0.33")}},
	}
	placementNow = func(bool) *placementView { return view }
	registryCache, dryRun = nil, false
	return sec
}

func TestNetUsesRegistryUnreadableFailsClosed(t *testing.T) {
	sec := usesRig(t, nil, errors.New("cannot read the machine key: permission denied"))
	ps, err := prepareScript(sec, "h001")
	if err == nil {
		t.Fatalf("prepareScript succeeded without the registry:\n%s", ps)
	}
	if ps != "" || strings.Contains(ps, "/ports/") {
		t.Fatalf("a ports file was produced: %q", ps)
	}
	if !errors.Is(err, errRegistryUnread) {
		t.Errorf("error does not say the registry was unreadable: %v", err)
	}
	for _, want := range []string{"sso.web", "sso", "sudo", "permission denied"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q: %v", want, err)
		}
	}
	if l, err := portsFileLines(sec, "h001"); err == nil || l != nil {
		t.Errorf("portsFileLines = %v, %v; want nil and an error", l, err)
	}
}

func TestNetUsesTargetNotPlacedFails(t *testing.T) {
	sec := usesRig(t, &placementView{Host: map[string]string{"sec": "h001"}}, nil)
	ps, err := prepareScript(sec, "h001")
	if err == nil || ps != "" {
		t.Fatalf("prepareScript = %q, %v; want an error", ps, err)
	}
	if errors.Is(err, errRegistryUnread) {
		t.Errorf("unplaced target reported as unreadable registry: %v", err)
	}
	if !strings.Contains(err.Error(), "sso is not placed") {
		t.Errorf("error does not name the unplaced target: %v", err)
	}
}

func TestNetUsesPlacedTargetAdmitted(t *testing.T) {
	sec := usesRig(t, &placementView{Host: map[string]string{"sec": "h001", "sso": "h003"}}, nil)
	ps := mustPrepare(t, sec, "h001")
	for _, want := range []string{"allow ve-sec 100.64.0.33 tcp 80", "allow ve-sec 100.64.0.33 tcp 443"} {
		if !strings.Contains(ps, want) {
			t.Errorf("ports lack %q:\n%s", want, ps)
		}
	}
}

func TestNetUsesDryRunSkipsWithoutError(t *testing.T) {
	sec := usesRig(t, nil, nil)
	dryRun = true
	if _, err := prepareScript(sec, "h001"); err != nil {
		t.Fatalf("dry run failed: %v", err)
	}
}
