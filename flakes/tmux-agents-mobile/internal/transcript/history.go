package transcript

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Recap is omp's "while you were away" summary of a session. omp writes one
// to its history database (never to the session log) after the session has
// been idle for a few minutes.
type Recap struct {
	Text      string
	CreatedAt time.Time
}

// History reads omp's history.db, the side index next to the session logs.
// It only ever opens the file read-only, and only queries again once the
// database or its WAL has changed. Safe for concurrent use.
type History struct {
	path string

	mu     sync.Mutex
	db     *sql.DB
	stamp  dbStamp
	recaps map[string]recapResult
}

type recapResult struct {
	recap Recap
	ok    bool
}

// NewHistory reads <ompDir>/history.db.
func NewHistory(ompDir string) *History {
	return &History{path: filepath.Join(ompDir, "history.db"), recaps: map[string]recapResult{}}
}

// LatestRecap returns the newest recap omp wrote for the session, if any.
func (h *History) LatestRecap(ctx context.Context, sessionID string) (Recap, bool, error) {
	if sessionID == "" {
		return Recap{}, false, nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()

	stamp, err := statDB(h.path)
	if errors.Is(err, os.ErrNotExist) {
		return Recap{}, false, nil
	}
	if err != nil {
		return Recap{}, false, err
	}
	if stamp != h.stamp {
		h.stamp = stamp
		h.recaps = map[string]recapResult{}
	} else if r, ok := h.recaps[sessionID]; ok {
		return r.recap, r.ok, nil
	}

	if h.db == nil {
		db, err := openReadOnly(h.path, 1)
		if err != nil {
			return Recap{}, false, err
		}
		h.db = db
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var (
		r       Recap
		created int64
	)
	err = h.db.QueryRowContext(ctx,
		`SELECT recap, created_at FROM session_recaps WHERE session_id = ? ORDER BY id DESC LIMIT 1`,
		sessionID,
	).Scan(&r.Text, &created)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		h.recaps[sessionID] = recapResult{}
		return Recap{}, false, nil
	case err != nil:
		// Most likely an older omp without the table; try again on the next
		// change rather than every poll.
		h.recaps[sessionID] = recapResult{}
		return Recap{}, false, err
	}
	r.CreatedAt = time.Unix(created, 0)
	h.recaps[sessionID] = recapResult{recap: r, ok: true}
	return r, true, nil
}

// Close releases the database handle.
func (h *History) Close() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.db == nil {
		return nil
	}
	err := h.db.Close()
	h.db = nil
	return err
}
