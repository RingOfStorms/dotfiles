package transcript

import (
	"database/sql"
	"net/url"
	"os"
	"time"

	// Pure Go, so the binary stays CGO_ENABLED=0.
	_ "modernc.org/sqlite"
)

// dbStamp is what tells a changed database apart: SQLite in WAL mode appends
// to the -wal file and only checkpoints into the main file now and then.
type dbStamp struct {
	main, wal         time.Time
	mainSize, walSize int64
}

func statDB(path string) (dbStamp, error) {
	st, err := os.Stat(path)
	if err != nil {
		return dbStamp{}, err
	}
	stamp := dbStamp{main: st.ModTime(), mainSize: st.Size()}
	if wal, err := os.Stat(path + "-wal"); err == nil {
		stamp.wal, stamp.walSize = wal.ModTime(), wal.Size()
	}
	return stamp, nil
}

// openReadOnly opens an agent's database without ever writing to it: the
// agent owns the file. busy_timeout covers the agent holding a write lock for
// a moment.
func openReadOnly(path string, conns int) (*sql.DB, error) {
	u := url.URL{Scheme: "file", Path: path}
	q := url.Values{}
	q.Set("mode", "ro")
	q.Add("_pragma", "busy_timeout(2000)")
	q.Add("_pragma", "query_only(1)")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(conns)
	return db, nil
}
