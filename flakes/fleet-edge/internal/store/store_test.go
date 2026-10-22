package store

import (
	"context"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreRecordQueryRollupAndBeszelImport(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not in PATH")
	}
	ctx := context.Background()
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "metrics.db")

	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	old8d := now.Add(-8 * 24 * time.Hour).Unix()

	// 1. Record an old 30s sample (>7d ago) and a current 30s sample
	err = st.RecordPoll(ctx, Sample{
		Host:         "h004",
		RecordedHost: "h004",
		TS:           old8d,
		Tier:         "30s",
		CPUPct:       20.0,
		CPUMax:       35.0,
		Load1:        0.5,
		MemUsed:      8_000_000_000,
		MemTotal:     64_000_000_000,
		TempMaxC:     42.0,
	}, []FSSample{
		{
			Host:         "h004",
			Mount:        "/data",
			FSType:       "bcachefs",
			TS:           old8d,
			Tier:         "30s",
			UsedBytes:    10_000_000_000_000,
			TotalBytes:   25_000_000_000_000,
			RawUsedBytes: 20_000_000_000_000,
			RawCapBytes:  50_000_000_000_000,
		},
	}, []byte(`{"host":"h004","time":"2026-10-14T12:00:00Z"}`))
	if err != nil {
		t.Fatalf("RecordPoll old: %v", err)
	}

	err = st.RecordPoll(ctx, Sample{
		Host:         "h004",
		RecordedHost: "h004",
		TS:           now.Unix(),
		Tier:         "30s",
		CPUPct:       12.5,
		CPUMax:       15.0,
		Load1:        0.4,
		MemUsed:      12_000_000_000,
		MemTotal:     64_000_000_000,
		TempMaxC:     38.5,
	}, nil, []byte(`{"host":"h004","time":"2026-10-22T12:00:00Z"}`))
	if err != nil {
		t.Fatalf("RecordPoll current: %v", err)
	}

	// 2. Rollup should compact the 8d-old 30s sample into 5m tier
	if err := st.Rollup(ctx, now); err != nil {
		t.Fatalf("Rollup: %v", err)
	}

	samples, err := st.QuerySamples(ctx, "h004", []string{"h002"}, old8d-3600, now.Unix()+60)
	if err != nil {
		t.Fatalf("QuerySamples: %v", err)
	}
	if len(samples) != 2 {
		t.Fatalf("expected 2 samples after rollup, got %d: %+v", len(samples), samples)
	}
	if samples[0].Tier != "5m" || samples[1].Tier != "30s" {
		t.Fatalf("unexpected tiers after rollup: %+v", samples)
	}

	// 3. Check persisted last state
	lastStates, err := st.LoadAllLastStates(ctx)
	if err != nil {
		t.Fatalf("LoadAllLastStates: %v", err)
	}
	ls, ok := lastStates["h004"]
	if !ok || ls.LastSeen.Unix() != now.Unix() {
		t.Fatalf("unexpected last state: %+v", ls)
	}

	// 4. Test Beszel import with h002 -> h004 mapping
	beszelDB := filepath.Join(tmp, "beszel.db")
	setupCmd := exec.Command("sqlite3", beszelDB, `
CREATE TABLE systems (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE system_stats (id TEXT PRIMARY KEY, system TEXT, type TEXT, created TEXT, stats TEXT);
INSERT INTO systems VALUES ('sys1', 'h002');
INSERT INTO systems VALUES ('sys2', 'h004');
INSERT INTO system_stats VALUES ('st1', 'sys1', '10m', '2026-10-01 10:00:00.000Z', '{"cpu":14.2,"cpum":28.0,"mem":32,"mu":16,"d":1000,"du":400,"dr":1.5,"dw":2.5,"ns":0.5,"nr":1.2,"la":[0.3,0.2,0.1],"t":{"coretemp":45}}');
INSERT INTO system_stats VALUES ('st2', 'sys2', '1m', '2026-10-20 10:00:00.000Z', '{"cpu":8.4,"cpum":12.0,"mem":64,"mu":10,"d":25000,"du":10000}');
`)
	if out, err := setupCmd.CombinedOutput(); err != nil {
		t.Fatalf("create synthetic beszel db: %v (%s)", err, string(out))
	}

	n, err := st.ImportBeszel(ctx, beszelDB, map[string]string{"h002": "h004"})
	if err != nil {
		t.Fatalf("ImportBeszel: %v", err)
	}
	if n != 2 {
		t.Fatalf("expected 2 imported rows, got %d", n)
	}

	allSamples, err := st.QuerySamples(ctx, "h004", []string{"h002"}, 0, now.Unix()+60)
	if err != nil {
		t.Fatalf("QuerySamples after import: %v", err)
	}
	if len(allSamples) != 4 {
		t.Fatalf("expected 4 total samples on h004 timeline, got %d", len(allSamples))
	}
	if allSamples[0].RecordedHost != "h002" || allSamples[0].Host != "h004" {
		t.Fatalf("expected first sample to be h002 merged into h004, got %+v", allSamples[0])
	}

	events, err := st.QueryEvents(ctx, "h004", []string{"h002"})
	if err != nil {
		t.Fatalf("QueryEvents: %v", err)
	}
	if len(events) != 1 || events[0].Kind != "host_replaced" {
		t.Fatalf("expected host_replaced event, got %+v", events)
	}
}
