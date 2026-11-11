package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
)

// BackupRow is one subject in the dashboard's backup table.
type BackupRow struct {
	Subject, Target, RetentionLocal, RetentionB2 string
	Offsite                                      bool
	// OffsiteNote is set when offsite cannot apply ("offsite unavailable").
	OffsiteNote          string
	TargetNote           string
	Local, B2, Cost      string
	LastBackup, LastCopy string
	StatsAt              string
	// Revision is the row revision a write must quote (0: follows default).
	Revision int64
	Clear    string
	Default  bool
	// Unlisted marks a repo a target reports that the inventory does not
	// name (a canary, a retired service): stats only, no policy invented.
	Unlisted bool
}

// BackupTable is the view of /internal/backup.json.
type BackupTable struct {
	Rows    []BackupRow
	Targets []backup.TargetView
	Error   string
}

func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func ago(ts int64, now time.Time) string {
	if ts == 0 {
		return "-"
	}
	return time.Unix(ts, 0).UTC().Format("2006-01-02 15:04") + " (" + now.Sub(time.Unix(ts, 0)).Round(time.Minute).String() + " ago)"
}

// BuildBackupTable turns the export into rows: one per subject (the default
// row first), then one per repo a target reports outside the inventory;
// stats from the holding target, never 0 for an unknown size.
func BuildBackupTable(e backup.Export, pricePerTB float64, now time.Time) BackupTable {
	t := BackupTable{Targets: e.Targets}
	byID := map[string]backup.TargetView{}
	for _, tg := range e.Targets {
		byID[tg.ID] = tg
	}
	rows := map[string]*backup.Row{}
	for _, r := range e.Rows {
		rows[r.Subject] = r
	}
	def := rows[backup.Default]
	if def == nil {
		def = &backup.Row{Subject: backup.Default, Target: backup.None, RetentionLocal: "standard", RetentionB2: "local"}
	}
	listed := map[string]bool{backup.Default: true}
	for _, n := range e.Subjects {
		listed[n] = true
	}
	var unlisted []string
	for _, tg := range e.Targets {
		for n := range tg.Stats {
			if !listed[n] {
				listed[n] = true
				unlisted = append(unlisted, n)
			}
		}
	}
	sort.Strings(unlisted)
	subjects := append(append([]string{backup.Default}, e.Subjects...), unlisted...)
	nInventory := 1 + len(e.Subjects)
	for i, name := range subjects {
		isUnlisted := i >= nInventory
		r := rows[name]
		switch {
		case r == nil && isUnlisted:
			r = &backup.Row{Subject: name, Target: "-", RetentionLocal: "-", RetentionB2: "-"}
		case r == nil:
			c := *def
			c.Subject = name
			r = &c
		}
		v := BackupRow{Subject: name, Target: r.Target, Offsite: r.Offsite, RetentionLocal: r.RetentionLocal,
			RetentionB2: r.RetentionB2, Default: name == backup.Default, Unlisted: isUnlisted,
			Local: "-", B2: "-", Cost: "-", LastBackup: "-", LastCopy: "-"}
		if rows[name] != nil {
			v.Revision = r.Revision
		}
		if rows[name] == nil && !v.Default {
			v.TargetNote = "default"
		}
		tg, ok := byID[r.Target]
		switch {
		case isUnlisted:
			v.TargetNote = "not in inventory"
		case r.Target == backup.None:
		case !ok:
			v.TargetNote = "unknown target"
		case !tg.Enabled:
			v.TargetNote = "disabled"
		case tg.Stale:
			v.TargetNote = "stale"
		}
		if r.Offsite && (!ok || !tg.Pusher) {
			v.OffsiteNote = "offsite unavailable"
		}
		if r.Clear != nil {
			if p := r.Clear.Pending(); p != "" {
				v.Clear = r.Clear.Scope + " on " + r.Clear.Target
				if len(r.Clear.Done) > 0 {
					v.Clear += fmt.Sprintf(" (done: %v, %s next)", r.Clear.Done, p)
				}
			}
		}
		// Stats: the policy target's, else any target holding the repo.
		var st *backup.Stats
		holder := ""
		if s, has := tg.Stats[name]; ok && has {
			st, holder = &s, tg.ID
		} else {
			for _, o := range e.Targets {
				if s, has := o.Stats[name]; has {
					st, holder = &s, o.ID
					break
				}
			}
		}
		if st != nil {
			if st.LocalBytes != nil {
				v.Local = humanBytes(*st.LocalBytes)
			}
			if st.B2Bytes != nil {
				v.B2 = humanBytes(*st.B2Bytes)
				v.Cost = fmt.Sprintf("$%.2f", float64(*st.B2Bytes)/1e12*pricePerTB)
			}
			v.LastBackup = ago(st.LastBackup, now)
			v.LastCopy = ago(st.LastCopied, now)
			if st.At != 0 {
				v.StatsAt = holder + " @ " + time.Unix(st.At, 0).UTC().Format("2006-01-02 15:04")
				if now.Sub(time.Unix(st.At, 0)) > 3*time.Hour {
					v.StatsAt += " (stale)"
				}
			}
		}
		t.Rows = append(t.Rows, v)
	}
	return t
}

func (s *Server) fetchBackup(ctx context.Context, now time.Time) BackupTable {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.cfg.BackupURL, nil)
	if err != nil {
		return BackupTable{Error: err.Error()}
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return BackupTable{Error: "backup policy unreachable"}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return BackupTable{Error: "backup policy: " + resp.Status}
	}
	var e backup.Export
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&e); err != nil {
		return BackupTable{Error: "bad export: " + err.Error()}
	}
	return BuildBackupTable(e, s.cfg.B2PricePerTB, now)
}
