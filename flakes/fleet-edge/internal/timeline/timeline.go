package timeline

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

// Step is how long one snapshot covers: [snapshotAt, snapshotAt+Step). A
// request past that window is a gap, never served by an older snapshot.
const Step = 30 * time.Second

// Retention bounds the history both in SQLite and in memory.
const Retention = store.AtlasRetention

// maxMemorySamples is the in-memory ring size: one day of samples, plus one so
// a sample recorded exactly at the edge of retention is never dropped.
const maxMemorySamples = int(Retention/Step) + 1

// Summary is the tiny per-sample record the timeline chart draws. It is stored
// as JSON so a day of history never parses a day of state documents.
type Summary struct {
	Online        int `json:"online"`
	Down          int `json:"down"`
	Sleeping      int `json:"sleeping"`
	DriveWarnings int `json:"driveWarnings"`
	BannedCount   int `json:"bannedCount"`
	BannedRecent  int `json:"bannedRecent"`
}

// Sample is one timeline point.
type Sample struct {
	At time.Time `json:"at"`
	Summary
}

// Snapshot is one recorded topology state plus its counters. It is immutable
// once recorded.
type Snapshot struct {
	TS      int64
	State   []byte
	Summary Summary
}

// Recorder captures the merged topology state every Step and answers historical
// queries from SQLite (when configured) or a bounded in-memory ring.
type Recorder struct {
	store *store.Store

	mu   sync.RWMutex
	ring []Snapshot // fixed capacity ring; head is the oldest entry
	head int
	n    int
}

// NewRecorder returns a recorder. A nil store selects the 24 h in-memory ring,
// which is volatile across restarts.
func NewRecorder(st *store.Store) *Recorder {
	return &Recorder{store: st, ring: make([]Snapshot, maxMemorySamples)}
}

// Persistent reports whether history survives a restart.
func (r *Recorder) Persistent() bool { return r != nil && r.store != nil }

// Summarize derives the timeline counters from a merged state, reusing the
// diagram's own drive-warning predicate so the chart and the topology agree.
func Summarize(m state.Merged) Summary {
	var s Summary
	for _, h := range m.Hosts {
		switch h.StateBadge {
		case "online":
			s.Online++
		case "down":
			s.Down++
		case "sleeping":
			s.Sleeping++
		}
		s.DriveWarnings += state.DriveWarnings(h)
		s.BannedCount += h.BannedCount
		if h.Status != nil && h.Status.Fail2ban != nil {
			s.BannedRecent += len(h.Status.Fail2ban.RecentBans)
		}
	}
	return s
}

// Record captures m as of now. The timestamp is the real capture instant, never
// a rounded one: history must not claim a state for a moment before it was
// observed. A capture at an instant already recorded is dropped, so a restart
// cannot rewrite history.
func (r *Recorder) Record(ctx context.Context, m state.Merged, now time.Time) error {
	if r == nil {
		return nil
	}
	ts := now.UTC().Unix()
	doc, err := json.Marshal(m)
	if err != nil {
		return fmt.Errorf("atlas: marshal state: %w", err)
	}
	summary := Summarize(m)
	sumDoc, err := json.Marshal(summary)
	if err != nil {
		return fmt.Errorf("atlas: marshal summary: %w", err)
	}
	if r.store != nil {
		return r.store.RecordAtlas(ctx, ts, doc, sumDoc)
	}
	r.remember(Snapshot{TS: ts, State: doc, Summary: summary})
	return nil
}

func (r *Recorder) remember(s Snapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.n > 0 {
		newest := r.ring[(r.head+r.n-1)%len(r.ring)]
		// Same instant: keep the first capture. Clock skew backwards: drop,
		// history stays monotonic.
		if s.TS <= newest.TS {
			return
		}
	}
	cutoff := s.TS - int64(Retention/time.Second)
	for r.n > 0 && r.ring[r.head].TS < cutoff {
		r.ring[r.head] = Snapshot{}
		r.head = (r.head + 1) % len(r.ring)
		r.n--
	}
	if r.n == len(r.ring) {
		r.ring[r.head] = Snapshot{}
		r.head = (r.head + 1) % len(r.ring)
		r.n--
	}
	r.ring[(r.head+r.n)%len(r.ring)] = s
	r.n++
}

// Run samples the current state every Step until ctx is cancelled. It records
// immediately, so a recorder started right after the first poll has a sample
// at once; onError receives recording failures instead of swallowing them.
func (r *Recorder) Run(ctx context.Context, current func() state.Merged, onError func(error)) {
	if r == nil || current == nil {
		return
	}
	sample := func() {
		if err := r.Record(ctx, current(), time.Now()); err != nil && onError != nil {
			onError(err)
		}
	}
	sample()
	t := time.NewTicker(Step)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			sample()
		}
	}
}

// Latest returns the newest recorded snapshot.
func (r *Recorder) Latest(ctx context.Context) (Snapshot, bool, error) {
	if r == nil {
		return Snapshot{}, false, nil
	}
	if r.store != nil {
		snap, ok, err := r.store.AtlasAt(ctx, time.Now().Unix())
		if err != nil || !ok {
			return Snapshot{}, false, err
		}
		return snapshotFrom(snap), true, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.n == 0 {
		return Snapshot{}, false, nil
	}
	return r.ring[(r.head+r.n-1)%len(r.ring)], true, nil
}

// At returns the snapshot covering at: the newest capture at or before at.
// Coverage is half-open — a capture at ts covers [ts, ts+Step) — so a gap is
// never floored to the snapshot that preceded it.
func (r *Recorder) At(ctx context.Context, at time.Time) (Snapshot, bool, error) {
	if r == nil {
		return Snapshot{}, false, nil
	}
	ts := at.UTC().Unix()
	if r.store != nil {
		snap, ok, err := r.store.AtlasAt(ctx, ts)
		if err != nil || !ok || ts-snap.TS >= int64(Step/time.Second) {
			return Snapshot{}, false, err
		}
		return snapshotFrom(snap), true, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	i := sort.Search(r.n, func(i int) bool { return r.ring[(r.head+i)%len(r.ring)].TS > ts })
	if i == 0 {
		return Snapshot{}, false, nil
	}
	snap := r.ring[(r.head+i-1)%len(r.ring)]
	if ts-snap.TS >= int64(Step/time.Second) {
		return Snapshot{}, false, nil
	}
	return snap, true, nil
}

// Summaries returns every recorded counter in [from, to], oldest first.
func (r *Recorder) Summaries(ctx context.Context, from, to time.Time) ([]Sample, error) {
	if r == nil {
		return nil, nil
	}
	if r.store != nil {
		rows, err := r.store.AtlasSummaries(ctx, from.Unix(), to.Unix())
		if err != nil {
			return nil, err
		}
		out := make([]Sample, 0, len(rows))
		for _, row := range rows {
			var s Summary
			if err := json.Unmarshal(row.Summary, &s); err != nil {
				return nil, fmt.Errorf("atlas: decode summary at %d: %w", row.TS, err)
			}
			out = append(out, Sample{At: time.Unix(row.TS, 0).UTC(), Summary: s})
		}
		return out, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := []Sample{}
	for i := range r.n {
		snap := r.ring[(r.head+i)%len(r.ring)]
		if snap.TS < from.Unix() || snap.TS > to.Unix() {
			continue
		}
		out = append(out, Sample{At: time.Unix(snap.TS, 0).UTC(), Summary: snap.Summary})
	}
	return out, nil
}

// Bounds returns the oldest and newest recorded capture.
func (r *Recorder) Bounds(ctx context.Context) (first, last time.Time, ok bool, err error) {
	if r == nil {
		return time.Time{}, time.Time{}, false, nil
	}
	if r.store != nil {
		f, l, ok, err := r.store.AtlasBounds(ctx)
		if err != nil || !ok {
			return time.Time{}, time.Time{}, false, err
		}
		return time.Unix(f, 0).UTC(), time.Unix(l, 0).UTC(), true, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.n == 0 {
		return time.Time{}, time.Time{}, false, nil
	}
	first = time.Unix(r.ring[r.head].TS, 0).UTC()
	last = time.Unix(r.ring[(r.head+r.n-1)%len(r.ring)].TS, 0).UTC()
	return first, last, true, nil
}

func snapshotFrom(s store.AtlasSnapshot) Snapshot {
	var sum Summary
	if len(s.Summary) > 0 {
		_ = json.Unmarshal(s.Summary, &sum)
	}
	return Snapshot{TS: s.TS, State: s.State, Summary: sum}
}
