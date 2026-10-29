package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func open(t *testing.T, dir string) *Store {
	t.Helper()
	st, err := Open(filepath.Join(dir, "atlas.db"))
	if err != nil {
		t.Skipf("store unavailable (needs sqlite3 on PATH): %v", err)
	}
	return st
}

func TestAtlasRetentionPrunesOldRows(t *testing.T) {
	st := open(t, t.TempDir())
	ctx := context.Background()

	now := time.Now().UTC().Truncate(time.Second)
	old := now.Add(-25 * time.Hour)  // past the 24 h window
	edge := now.Add(-AtlasRetention) // exactly at the boundary: kept
	for _, ts := range []int64{old.Unix(), edge.Unix(), now.Unix()} {
		if err := st.RecordAtlas(ctx, ts, []byte(`{"n":1}`), []byte(`{"online":1}`)); err != nil {
			t.Fatal(err)
		}
	}

	first, last, ok, err := st.AtlasBounds(ctx)
	if err != nil || !ok {
		t.Fatalf("bounds: ok=%v err=%v", ok, err)
	}
	if first != edge.Unix() || last != now.Unix() {
		t.Errorf("bounds = %d..%d, want %d..%d", first, last, edge.Unix(), now.Unix())
	}
	if _, ok, err := st.AtlasAt(ctx, old.Unix()); err != nil || ok {
		t.Errorf("pruned snapshot still readable: ok=%v err=%v", ok, err)
	}
}

func TestAtlasReRecordKeepsFirstCapture(t *testing.T) {
	st := open(t, t.TempDir())
	ctx := context.Background()
	ts := time.Now().UTC().Truncate(time.Second).Unix()

	if err := st.RecordAtlas(ctx, ts, []byte(`{"v":"first"}`), []byte(`{"online":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordAtlas(ctx, ts, []byte(`{"v":"second"}`), []byte(`{"online":9}`)); err != nil {
		t.Fatal(err)
	}
	snap, ok, err := st.AtlasAt(ctx, ts)
	if err != nil || !ok {
		t.Fatalf("AtlasAt: ok=%v err=%v", ok, err)
	}
	if string(snap.State) != `{"v":"first"}` {
		t.Errorf("state = %s, want the first capture", snap.State)
	}
	if string(snap.Summary) != `{"online":1}` {
		t.Errorf("summary = %s, want the first capture", snap.Summary)
	}
}

func TestAtlasAtPicksNewestAtOrBefore(t *testing.T) {
	st := open(t, t.TempDir())
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second).Unix()
	for _, ts := range []int64{now - 60, now - 30, now} {
		if err := st.RecordAtlas(ctx, ts, []byte(`{}`), []byte(`{"online":1}`)); err != nil {
			t.Fatal(err)
		}
	}
	// Between rows: the older row answers (the caller decides whether the gap
	// is still covered).
	snap, ok, err := st.AtlasAt(ctx, now-29)
	if err != nil || !ok {
		t.Fatalf("AtlasAt: ok=%v err=%v", ok, err)
	}
	if snap.TS != now-30 {
		t.Errorf("ts = %d, want %d", snap.TS, now-30)
	}
	// Before any row: no snapshot.
	if _, ok, err := st.AtlasAt(ctx, now-3600); err != nil || ok {
		t.Errorf("prehistory answered: ok=%v err=%v", ok, err)
	}
}
