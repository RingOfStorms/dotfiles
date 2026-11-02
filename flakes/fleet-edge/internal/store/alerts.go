package store

import (
	"context"
	"fmt"
)

// alertSchemaSQL holds the alert de-duplication state (internal/alert): one row
// per open (kind, subject) condition, so a restart does not re-send an alert
// that was already delivered. Recovery deletes the row.
const alertSchemaSQL = `
CREATE TABLE IF NOT EXISTS alert_state (
  kind      TEXT NOT NULL,
  subject   TEXT NOT NULL,
  title     TEXT NOT NULL,
  body      TEXT NOT NULL,
  since     INTEGER NOT NULL,
  notified  INTEGER NOT NULL,
  PRIMARY KEY (kind, subject)
);
`

// AlertState is one open alert. Since is when the condition started firing,
// Notified when the firing notification was delivered (0 = not yet
// delivered). Times are unix seconds.
type AlertState struct {
	Kind     string `json:"kind"`
	Subject  string `json:"subject"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	Since    int64  `json:"since"`
	Notified int64  `json:"notified"`
}

// AlertStates returns every open alert.
func (s *Store) AlertStates(ctx context.Context) ([]AlertState, error) {
	if s == nil {
		return nil, nil
	}
	var rows []AlertState
	if err := s.queryJSON(ctx, `SELECT kind, subject, title, body, since, notified
FROM alert_state ORDER BY kind, subject;`, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

// PutAlertState inserts or replaces one open alert.
func (s *Store) PutAlertState(ctx context.Context, a AlertState) error {
	if s == nil {
		return nil
	}
	return s.execSQL(ctx, fmt.Sprintf(`INSERT OR REPLACE INTO alert_state
(kind, subject, title, body, since, notified) VALUES (%s, %s, %s, %s, %d, %d);`,
		sqlQuote(a.Kind), sqlQuote(a.Subject), sqlQuote(a.Title), sqlQuote(a.Body), a.Since, a.Notified))
}

// DeleteAlertState forgets one alert (it resolved).
func (s *Store) DeleteAlertState(ctx context.Context, kind, subject string) error {
	if s == nil {
		return nil
	}
	return s.execSQL(ctx, fmt.Sprintf(`DELETE FROM alert_state WHERE kind = %s AND subject = %s;`,
		sqlQuote(kind), sqlQuote(subject)))
}
