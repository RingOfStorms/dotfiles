package bunny

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func ddns(t *testing.T, f *fakeBunny, spec *Spec, ip string) (string, error) {
	t.Helper()
	srv := httptest.NewServer(f)
	defer srv.Close()
	var out bytes.Buffer
	err := DDNS(context.Background(), &Client{Key: "k", Base: srv.URL}, spec, ip, filepath.Join(t.TempDir(), "lock"), &out)
	return out.String(), err
}

// DDNS writes only the dynamic record: the TTL update, create and retires
// that dns-plan --apply would do stay untouched.
func TestDDNSWritesOnlyDynamic(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	out, err := ddns(t, f, applySpec(), "203.0.113.7")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(f.log, ",") != "GET /dnszone,POST /dnszone/7/records/5" {
		t.Fatalf("calls %v", f.log)
	}
	got := map[string]Record{}
	for _, r := range f.zone.Records {
		got[r.Name] = r
	}
	if got["home"].Value != "203.0.113.7" || got["home"].TTL != 300 || got["home"].Type != 0 ||
		got["photos"].TTL != 3600 || got["docs"].ID != 2 || got["kura"].ID != 3 || len(got) != 5 {
		t.Fatalf("zone after ddns: %+v", f.zone.Records)
	}
	if !strings.Contains(out, "update home A: 9.9.9.9 ttl=60 -> 203.0.113.7 ttl=300") {
		t.Errorf("output %q", out)
	}
	// Same address again: one read, no write.
	f.log = nil
	out, err = ddns(t, f, applySpec(), "203.0.113.7")
	if err != nil || len(f.log) != 1 || !strings.Contains(out, "unchanged") {
		t.Fatalf("second run: err=%v log=%v out=%q", err, f.log, out)
	}
}

func TestDDNSCreatesMissing(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	f.zone.Records = f.zone.Records[:4]
	if _, err := ddns(t, f, applySpec(), "203.0.113.7"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(f.log, ",") != "GET /dnszone,PUT /dnszone/7/records" {
		t.Fatalf("calls %v", f.log)
	}
	if r := f.zone.Records[4]; r.Name != "home" || r.Type != 0 || r.Value != "203.0.113.7" {
		t.Fatalf("created %+v", r)
	}
}

func TestDDNSRefusesConflict(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	f.zone.Records[4] = Record{ID: 5, Type: 2, Name: "home", Value: "o002.example.com", TTL: 300}
	if _, err := ddns(t, f, applySpec(), "203.0.113.7"); err == nil || len(f.log) != 1 {
		t.Fatalf("conflict must block the write: err=%v log=%v", err, f.log)
	}
}

func TestDDNSNeedsDynamicRecord(t *testing.T) {
	s := applySpec()
	s.Records = s.Records[:2]
	f := &fakeBunny{zone: liveZone(), next: 100}
	if _, err := ddns(t, f, s, "203.0.113.7"); err == nil || len(f.log) != 0 {
		t.Fatalf("want refusal before any call: err=%v log=%v", err, f.log)
	}
}

// dns-plan reports a missing dynamic record and leaves it to DDNS.
func TestPlanDynamicMissing(t *testing.T) {
	z := liveZone()
	z.Records = z.Records[:4]
	plan := Plan(applySpec(), &z)
	if c := byName(plan)["home/A"]; c.Action != Dynamic || c.Old != "missing" {
		t.Fatalf("home: %+v", c)
	}
	ops, err := Ops(z.ID, plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range ops {
		if op.Change.Name == "home" {
			t.Fatalf("dns-plan wrote the dynamic record: %+v", op)
		}
	}
}

func TestResolveDynamic(t *testing.T) {
	s := applySpec()
	r := s.ResolveDynamic(WANIPv4, "203.0.113.7")
	if len(r.Records) != 1 || r.Records[0].Value != "203.0.113.7" || len(r.Retire) != 0 || r.Zone != s.Zone {
		t.Fatalf("resolved %+v", r)
	}
	if s.Records[2].Value != "" {
		t.Fatal("input spec changed")
	}
}

func TestPublicIPv4(t *testing.T) {
	echo := func(code int, body string) string {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(code)
			w.Write([]byte(body))
		}))
		t.Cleanup(srv.Close)
		return srv.URL
	}
	bad := []string{
		echo(500, "203.0.113.7"),
		echo(200, "garbage"),
		echo(200, "10.0.0.1"),     // private
		echo(200, "100.64.0.5"),   // CGNAT / tailnet
		echo(200, "127.0.0.1"),    // loopback
		echo(200, "2001:db8::1"),  // IPv6
		"http://127.0.0.1:1/down", // unreachable
	}
	hc := IPv4Client(5 * time.Second)
	ip, err := PublicIPv4(context.Background(), hc, append(bad, echo(200, " 203.0.113.7\n")))
	if err != nil || ip != "203.0.113.7" {
		t.Fatalf("ip=%q err=%v", ip, err)
	}
	if _, err := PublicIPv4(context.Background(), hc, bad); err == nil {
		t.Fatal("no good answer must fail")
	}
}
