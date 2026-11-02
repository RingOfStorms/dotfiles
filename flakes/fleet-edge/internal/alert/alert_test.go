package alert

import (
	"context"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestAlertThresholdsDeduplicateAndRecover(t *testing.T) {
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	count := 0
	notify := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { count++; w.WriteHeader(200) }))
	defer notify.Close()
	st, err := store.Open(filepath.Join(t.TempDir(), "alerts.db"))
	if err != nil {
		t.Fatal(err)
	}
	expiry := now.Add(13 * 24 * time.Hour)
	cfg := Config{URL: notify.URL, DownAfter: 5 * time.Minute, Store: st, Probe: func(context.Context, string) (time.Time, error) { return expiry, nil }}
	m, err := New(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	u := "https://photos.example.com"
	snapshot := state.Merged{Services: []state.ServiceView{{Name: "photos", BoundHost: "h001", Active: "failed", Backup: "stale", BackupAge: "48h", Routes: []inventory.Route{{URL: &u}}}}}
	check := func(at time.Time) {
		t.Helper()
		if err := m.Check(context.Background(), snapshot, at); err != nil {
			t.Fatal(err)
		}
	}
	check(now)
	if count != 2 {
		t.Fatalf("backup/cert immediate, health delayed: %d", count)
	}
	check(now.Add(4 * time.Minute))
	if count != 2 {
		t.Fatal(count)
	}
	check(now.Add(5 * time.Minute))
	if count != 3 {
		t.Fatal(count)
	}
	m, err = New(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	check(now.Add(6 * time.Minute))
	if count != 3 {
		t.Fatalf("restart duplicated alerts: %d", count)
	}
	if certs := m.Certificates(); len(certs) != 1 || !certs[0].Expiring {
		t.Fatal(certs)
	}
	snapshot.Services[0].Active, snapshot.Services[0].Backup = "active", "ok"
	expiry = now.Add(60 * 24 * time.Hour)
	check(now.Add(7 * time.Minute))
	snapshot.Services[0].Backup = "stale"
	check(now.Add(8 * time.Minute))
	if count != 4 {
		t.Fatal("recurrence did not notify", count)
	}
	snapshot.Services[0].BoundHost = ""
	check(now.Add(9 * time.Minute))
	if len(m.Certificates()) != 0 {
		t.Fatal("unplaced service monitored")
	}
}

func TestHealthEndpointFailureAndNtfyFailureRetry(t *testing.T) {
	now := time.Now()
	status, count := 503, 0
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer endpoint.Close()
	notify := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { count++; w.WriteHeader(status) }))
	defer notify.Close()
	m, err := New(context.Background(), Config{URL: notify.URL, DownAfter: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	health := "/health"
	u := endpoint.URL
	snapshot := state.Merged{Services: []state.ServiceView{{Name: "app", BoundHost: "h", Active: "active", Backup: "ok", Routes: []inventory.Route{{URL: &u, Health: &health}}}}}
	if err := m.Check(context.Background(), snapshot, now); err != nil {
		t.Fatal(err)
	}
	if err := m.Check(context.Background(), snapshot, now.Add(time.Minute)); err == nil {
		t.Fatal("notification error hidden")
	}
	status = 200
	if err := m.Check(context.Background(), snapshot, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatal(count)
	}
}

func TestProbeCertificateReadsServedLeaf(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer srv.Close()
	got, err := probeCertificate(context.Background(), srv.URL)
	if err != nil || !got.Equal(srv.Certificate().NotAfter) {
		t.Fatalf("%v %v", got, err)
	}
}
