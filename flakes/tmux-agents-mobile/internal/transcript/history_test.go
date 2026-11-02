package transcript

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestHistoryLatestRecap(t *testing.T) {
	dir := t.TempDir()
	h := NewHistory(dir)
	t.Cleanup(func() { _ = h.Close() })
	ctx := context.Background()

	if _, ok, err := h.LatestRecap(ctx, "s1"); ok || err != nil {
		t.Fatalf("missing db = %v, %v", ok, err)
	}

	db, err := sql.Open("sqlite", filepath.Join(dir, "history.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`PRAGMA journal_mode=WAL`)
	exec(`CREATE TABLE session_recaps (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, cwd TEXT NOT NULL, recap TEXT NOT NULL, created_at INTEGER NOT NULL)`)
	exec(`INSERT INTO session_recaps (session_id, cwd, recap, created_at) VALUES ('s1', '/x', 'old', 100), ('s2', '/x', 'other', 300), ('s1', '/x', 'new', 200)`)

	r, ok, err := h.LatestRecap(ctx, "s1")
	if err != nil || !ok || r.Text != "new" || !r.CreatedAt.Equal(time.Unix(200, 0)) {
		t.Fatalf("recap = %+v, %v, %v", r, ok, err)
	}
	if _, ok, err := h.LatestRecap(ctx, "nope"); ok || err != nil {
		t.Fatalf("unknown session = %v, %v", ok, err)
	}

	// A new recap lands in the WAL; the cached answer must not stick.
	time.Sleep(10 * time.Millisecond)
	exec(`INSERT INTO session_recaps (session_id, cwd, recap, created_at) VALUES ('s1', '/x', 'newest', 400)`)
	if r, _, _ := h.LatestRecap(ctx, "s1"); r.Text != "newest" {
		t.Fatalf("after insert = %+v", r)
	}
}
