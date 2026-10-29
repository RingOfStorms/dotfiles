package timeline

import (
	"context"
	"fmt"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

var base = time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)

func merged(online int) state.Merged {
	m := state.Merged{}
	for i := range online {
		m.Hosts = append(m.Hosts, state.HostView{
			Host: fmt.Sprintf("h%03d", i), StateBadge: "online", AlwaysOn: true,
		})
	}
	return m
}

// record at an explicit instant, bypassing the wall clock so boundaries are
// exact.
func record(t *testing.T, r *Recorder, at time.Time, online int) {
	t.Helper()
	if err := r.Record(context.Background(), merged(online), at); err != nil {
		t.Fatal(err)
	}
}

func TestRecordIsImmutablePerInstant(t *testing.T) {
	r := NewRecorder(nil)
	record(t, r, base, 1)
	record(t, r, base, 3) // same instant again: the first capture stands
	snap, ok, err := r.At(context.Background(), base)
	if err != nil || !ok {
		t.Fatalf("At: ok=%v err=%v", ok, err)
	}
	if snap.Summary.Online != 1 {
		t.Errorf("online = %d, want the first capture (1)", snap.Summary.Online)
	}
	if r.n != 1 {
		t.Fatalf("recorded %d snapshots, want 1", r.n)
	}
}

func TestAtCoverageIsHalfOpen(t *testing.T) {
	r := NewRecorder(nil)
	record(t, r, base, 2)
	ctx := context.Background()

	for _, tc := range []struct {
		at   time.Time
		want bool
	}{
		{base, true},
		{base.Add(Step - time.Second), true},
		{base.Add(Step), false}, // first instant of the gap
		{base.Add(Step + time.Second), false},
	} {
		if _, ok, err := r.At(ctx, tc.at); err != nil || ok != tc.want {
			t.Errorf("At(%s) = %v,%v want %v", tc.at.Format(time.RFC3339), ok, err, tc.want)
		}
	}
	if _, ok, _ := r.At(ctx, base.Add(-time.Second)); ok {
		t.Error("instant before recording began was answered")
	}
}

func TestAtNeverFloorsAcrossAGap(t *testing.T) {
	r := NewRecorder(nil)
	record(t, r, base, 1)
	record(t, r, base.Add(10*time.Minute), 2)
	ctx := context.Background()

	snap, ok, err := r.At(ctx, base.Add(5*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatalf("gap answered with snapshot at %d", snap.TS)
	}
	// The resumed capture is reachable again.
	snap, ok, err = r.At(ctx, base.Add(10*time.Minute+Step-time.Second))
	if err != nil || !ok {
		t.Fatalf("resumed capture: ok=%v err=%v", ok, err)
	}
	if snap.Summary.Online != 2 {
		t.Errorf("online = %d, want 2", snap.Summary.Online)
	}
}

func TestOldSamplesAreForgotten(t *testing.T) {
	r := NewRecorder(nil)
	record(t, r, base, 1)                          // ages out of the 24 h window
	record(t, r, base.Add(Retention+time.Hour), 2) // recording prunes it
	if r.n != 1 {
		t.Fatalf("ring holds %d snapshots, want 1", r.n)
	}
	if _, ok, _ := r.At(context.Background(), base.Add(Step-time.Second)); ok {
		t.Error("a snapshot older than the retention window is still served")
	}
}

func TestBoundsAndSummaries(t *testing.T) {
	r := NewRecorder(nil)
	ctx := context.Background()
	if _, _, ok, err := r.Bounds(ctx); err != nil || ok {
		t.Fatalf("empty bounds ok=%v err=%v", ok, err)
	}
	if got, err := r.Summaries(ctx, base, base.Add(time.Hour)); err != nil || len(got) != 0 {
		t.Fatalf("empty summaries = %v, %v", got, err)
	}
	record(t, r, base, 1)
	record(t, r, base.Add(Step), 2)
	first, last, ok, err := r.Bounds(ctx)
	if err != nil || !ok {
		t.Fatalf("bounds: %v %v", ok, err)
	}
	if !first.Equal(base) || !last.Equal(base.Add(Step)) {
		t.Errorf("bounds = %s..%s", first, last)
	}
	samples, err := r.Summaries(ctx, base.Add(Step), base.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(samples) != 1 || samples[0].Summary.Online != 2 {
		t.Errorf("summaries = %+v, want just the later capture", samples)
	}
}

func TestLatest(t *testing.T) {
	r := NewRecorder(nil)
	ctx := context.Background()
	if _, ok, err := r.Latest(ctx); err != nil || ok {
		t.Fatalf("empty latest ok=%v err=%v", ok, err)
	}
	record(t, r, base, 1)
	record(t, r, base.Add(Step), 2)
	snap, ok, err := r.Latest(ctx)
	if err != nil || !ok {
		t.Fatalf("latest: %v %v", ok, err)
	}
	if snap.TS != base.Add(Step).Unix() {
		t.Errorf("latest ts = %d, want the newest", snap.TS)
	}
}

func TestRunRecordsImmediately(t *testing.T) {
	r := NewRecorder(nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		r.Run(ctx, func() state.Merged { return merged(2) }, nil)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, ok, _ := r.Latest(context.Background()); ok {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			<-done
			t.Fatal("Run did not record before its first tick")
		}
		time.Sleep(5 * time.Millisecond)
	}
	snap, _, _ := r.Latest(context.Background())
	if snap.Summary.Online != 2 {
		t.Errorf("online = %d, want 2", snap.Summary.Online)
	}
	// The capture time is the real instant, not a synthetic bucket start.
	if d := time.Since(time.Unix(snap.TS, 0)); d > time.Minute || d < -time.Minute {
		t.Errorf("capture ts is %s away from now", d)
	}
	cancel()
	<-done
}

func TestSummarizeCountsSeverity(t *testing.T) {
	m := state.Merged{
		Hosts: []state.HostView{
			{Host: "a", StateBadge: "online", AlwaysOn: true},
			{Host: "b", StateBadge: "down", AlwaysOn: true},
			{Host: "c", StateBadge: "sleeping"},
			{Host: "d", StateBadge: "online", AlwaysOn: true, BannedCount: 3},
			{Host: "e", StateBadge: "online", AlwaysOn: true,
				Status: &state.HostStatus{
					Smart:    []state.SmartDrive{{Healthy: false}},
					Fail2ban: &state.Fail2banSummary{RecentBans: []state.Fail2banBanEvent{{IP: "8.8.8.8"}}},
				}},
		},
		Services: []state.ServiceView{{Name: "s", Active: "active"}},
	}
	got := Summarize(m)
	if got.Online != 3 || got.Down != 1 || got.Sleeping != 1 {
		t.Errorf("counts = %+v", got)
	}
	if got.DriveWarnings != 1 {
		t.Errorf("driveWarnings = %d, want 1", got.DriveWarnings)
	}
	if got.BannedCount != 3 || got.BannedRecent != 1 {
		t.Errorf("banned = %d/%d, want 3/1", got.BannedCount, got.BannedRecent)
	}
	// The chart must agree with the per-host predicate the diagram uses.
	for _, h := range m.Hosts {
		if state.DriveWarnings(h) > 0 && got.DriveWarnings == 0 {
			t.Errorf("%s warns but the summary says 0", h.Host)
		}
	}
}
