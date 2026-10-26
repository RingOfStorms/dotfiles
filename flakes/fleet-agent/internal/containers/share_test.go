package containers

import (
	"strings"
	"testing"
	"time"
)

func TestParseShareArgsDefaults(t *testing.T) {
	a, err := parseShareArgs([]string{"3000"})
	if err != nil {
		t.Fatal(err)
	}
	if a.Port != 3000 || a.For != 8*time.Hour || len(a.Name) != 6 {
		t.Fatalf("got %+v", a)
	}
}

func TestParseShareArgsNameAndFor(t *testing.T) {
	a, err := parseShareArgs([]string{"3000", "--name", "dev1", "--for", "1h"})
	if err != nil {
		t.Fatal(err)
	}
	if a.Name != "dev1" || a.For != time.Hour {
		t.Fatalf("got %+v", a)
	}
}

func TestParseShareArgsRefusesBadInput(t *testing.T) {
	cases := [][]string{
		{"0"},
		{"70000"},
		{"3000", "--name", "Bad"},
		{"3000", "--name", "has_underscore"},
		{"3000", "--for", "0s"},
		{"3000", "--for", "48h"},
		{"3000", "--for", "nonsense"},
		{},
		{"3000", "4000"},
	}
	for _, c := range cases {
		if _, err := parseShareArgs(c); err == nil {
			t.Errorf("args %v: accepted", c)
		}
	}
}

func TestGenShareNameMatchesRegex(t *testing.T) {
	name, err := genShareName()
	if err != nil {
		t.Fatal(err)
	}
	if !shareNameRe.MatchString(name) || len(name) != 6 {
		t.Fatalf("bad generated name %q", name)
	}
}

func TestShareDomainAndTargetDefaults(t *testing.T) {
	t.Setenv("FLEET_SHARE_DOMAIN", "")
	t.Setenv("FLEET_DOMAIN", "")
	t.Setenv("FLEET_SHARE_TARGET", "")
	if d := shareDomain(); d != "share.joshuabell.xyz" {
		t.Errorf("domain: %q", d)
	}
	if tg := shareTarget(); tg != "share@o002.joshuabell.xyz" {
		t.Errorf("target: %q", tg)
	}
}

func TestShareDomainOverride(t *testing.T) {
	t.Setenv("FLEET_SHARE_DOMAIN", "share.test.example")
	if d := shareDomain(); d != "share.test.example" {
		t.Errorf("domain override not honored: %q", d)
	}
}

func TestParseShareArgsBadNameEmptyOK(t *testing.T) {
	// An empty --name value is a flag error, not a generated name.
	if _, err := parseShareArgs([]string{"3000", "--name"}); err == nil {
		t.Error("want error: --name needs a value")
	}
	if _, err := parseShareArgs([]string{"3000", "--for"}); err == nil {
		t.Error("want error: --for needs a value")
	}
}

func TestShareForParsing(t *testing.T) {
	if _, err := shareFor("abc"); err == nil {
		t.Error("want parse error")
	}
	d, err := shareFor("")
	if err != nil || d != 8*time.Hour {
		t.Fatalf("default: %v %v", d, err)
	}
}

func TestParseShareArgsUsageMessage(t *testing.T) {
	_, err := parseShareArgs(nil)
	if err == nil || !strings.Contains(err.Error(), "usage: fleet share") {
		t.Fatalf("want usage error, got %v", err)
	}
}
