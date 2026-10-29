package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// AtlasRetention is how much topology history the atlas keeps.
const AtlasRetention = 24 * time.Hour

// atlasSchemaSQL creates the topology snapshot history table. The store keeps
// the documents as text and never decodes them: the writer owns their shape and
// the reader parses them back, which keeps this package free of state/topology
// imports.
const atlasSchemaSQL = `
CREATE TABLE IF NOT EXISTS atlas_snapshots (
  ts          INTEGER PRIMARY KEY,
  state_doc   TEXT NOT NULL,
  summary_doc TEXT NOT NULL
);
`

// AtlasSnapshot is one recorded topology state, stamped with the real capture
// time. State is the /api/state.json document at that moment, Summary the
// derived counters the timeline chart renders. Storing the bytes instead of a
// re-resolved view is what makes replay exact.
type AtlasSnapshot struct {
	TS      int64           `json:"ts"`
	State   json.RawMessage `json:"state"`
	Summary json.RawMessage `json:"summary"`
}

// AtlasSummary is a snapshot without its state document.
type AtlasSummary struct {
	TS      int64           `json:"ts"`
	Summary json.RawMessage `json:"summary"`
}

// atlasRow is the wire shape of sqlite3 -json: text columns arrive as JSON
// strings, so each document is decoded a second time into a raw message.
type atlasRow struct {
	TS      int64  `json:"ts"`
	State   string `json:"state"`
	Summary string `json:"summary"`
}

func (r atlasRow) snapshot() AtlasSnapshot {
	return AtlasSnapshot{TS: r.TS, State: json.RawMessage(r.State), Summary: json.RawMessage(r.Summary)}
}

// atlasSummaryRow is AtlasSummaries' projection of the same encoding.
type atlasSummaryRow struct {
	TS      int64  `json:"ts"`
	Summary string `json:"summary"`
}

// RecordAtlas stores one snapshot and prunes expired history. Snapshots are
// immutable: recording a timestamp that already exists keeps the first capture,
// so a restart can never rewrite a past instant.
func (s *Store) RecordAtlas(ctx context.Context, ts int64, state, summary []byte) error {
	if s == nil {
		return nil
	}
	if ts <= 0 {
		return fmt.Errorf("atlas: invalid snapshot timestamp %d", ts)
	}
	cutoff := ts - int64(AtlasRetention/time.Second)
	q := fmt.Sprintf(`BEGIN;
INSERT INTO atlas_snapshots (ts, state_doc, summary_doc) VALUES (%d, %s, %s)
  ON CONFLICT(ts) DO NOTHING;
DELETE FROM atlas_snapshots WHERE ts < %d;
COMMIT;
`, ts, sqlQuote(string(state)), sqlQuote(string(summary)), cutoff)
	return s.execSQL(ctx, q)
}

// AtlasAt returns the newest snapshot recorded at or before ts.
func (s *Store) AtlasAt(ctx context.Context, ts int64) (AtlasSnapshot, bool, error) {
	if s == nil {
		return AtlasSnapshot{}, false, nil
	}
	q := fmt.Sprintf(`SELECT ts, state_doc AS state, summary_doc AS summary
FROM atlas_snapshots WHERE ts <= %d ORDER BY ts DESC LIMIT 1;`, ts)
	var rows []atlasRow
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return AtlasSnapshot{}, false, err
	}
	if len(rows) == 0 {
		return AtlasSnapshot{}, false, nil
	}
	return rows[0].snapshot(), true, nil
}

// AtlasSummaries returns every snapshot summary in [from, to], oldest first.
func (s *Store) AtlasSummaries(ctx context.Context, from, to int64) ([]AtlasSummary, error) {
	if s == nil {
		return nil, nil
	}
	q := fmt.Sprintf(`SELECT ts, summary_doc AS summary FROM atlas_snapshots
WHERE ts >= %d AND ts <= %d ORDER BY ts ASC;`, from, to)
	var rows []atlasSummaryRow
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return nil, err
	}
	out := make([]AtlasSummary, len(rows))
	for i, r := range rows {
		out[i] = AtlasSummary{TS: r.TS, Summary: json.RawMessage(r.Summary)}
	}
	return out, nil
}

// AtlasBounds returns the oldest and newest recorded capture timestamps.
func (s *Store) AtlasBounds(ctx context.Context) (first, last int64, ok bool, err error) {
	if s == nil {
		return 0, 0, false, nil
	}
	var rows []struct {
		First *int64 `json:"first"`
		Last  *int64 `json:"last"`
	}
	if err := s.queryJSON(ctx, `SELECT MIN(ts) AS first, MAX(ts) AS last FROM atlas_snapshots;`, &rows); err != nil {
		return 0, 0, false, err
	}
	if len(rows) == 0 || rows[0].First == nil || rows[0].Last == nil {
		return 0, 0, false, nil
	}
	return *rows[0].First, *rows[0].Last, true, nil
}
