package server

import (
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
)

func TestBuildBackupTable(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	b2 := int64(1e12)
	e := backup.Export{
		Rows: []*backup.Row{
			{Subject: "canary", Target: "h004", Offsite: true, RetentionLocal: "short", RetentionB2: "local"},
			{Subject: "old", Target: "h009", Offsite: true, RetentionLocal: "standard", RetentionB2: "local"},
		},
		Targets: []backup.TargetView{
			{Target: backup.Target{ID: "h004", Pusher: true, Enabled: true, Seen: now.Unix(),
				Stats: map[string]backup.Stats{"canary": {B2Bytes: &b2, At: now.Unix()}}}},
			{Target: backup.Target{ID: "h009", Enabled: true}, Stale: true},
		},
		Subjects: []string{"canary", "old", "fresh"},
	}
	tb := BuildBackupTable(e, 6.95, now)
	if len(tb.Rows) != 4 || !tb.Rows[0].Default {
		t.Fatalf("rows: %+v", tb.Rows)
	}
	c := tb.Rows[1]
	if c.Cost != "$6.95" || c.Local != "-" || !strings.HasPrefix(c.B2, "931.3 GiB") {
		t.Fatalf("canary: %+v", c)
	}
	if o := tb.Rows[2]; o.OffsiteNote != "offsite unavailable" || o.TargetNote != "stale" {
		t.Fatalf("old: %+v", o)
	}
	if f := tb.Rows[3]; f.Target != backup.None || f.TargetNote != "default" {
		t.Fatalf("fresh: %+v", f)
	}
}

// TestBuildBackupTableClears: a finished clear stays on the row as a record
// but is not shown; a partly done one says what runs next.
func TestBuildBackupTableClears(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	e := backup.Export{
		Rows: []*backup.Row{
			{Subject: "a", Target: "h004", Clear: &backup.Clear{Scope: "both", Target: "h004", Done: []string{"local", "b2"}}},
			{Subject: "b", Target: "h004", Clear: &backup.Clear{Scope: "both", Target: "h004", Done: []string{"local"}}},
			{Subject: "c", Target: "h004", Clear: &backup.Clear{Scope: "b2", Target: "h004"}},
		},
		Targets:  []backup.TargetView{{Target: backup.Target{ID: "h004", Pusher: true, Enabled: true, Seen: now.Unix()}}},
		Subjects: []string{"a", "b", "c"},
	}
	got := map[string]string{}
	for _, r := range BuildBackupTable(e, 6.95, now).Rows {
		got[r.Subject] = r.Clear
	}
	if got["a"] != "" || got["b"] != "both on h004 (done: [local], b2 next)" || got["c"] != "b2 on h004" {
		t.Fatalf("clears: %q", got)
	}
}

// TestBuildBackupTableUnlisted: a repo a target reports that the inventory
// does not name (the svc-canary repo) still gets a row, after the inventory,
// marked and with no policy invented for it.
func TestBuildBackupTableUnlisted(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	local := int64(5 << 20)
	e := backup.Export{
		Rows: []*backup.Row{{Subject: backup.Default, Target: "h004", Offsite: true, RetentionLocal: "long", RetentionB2: "short"}},
		Targets: []backup.TargetView{
			{Target: backup.Target{ID: "h004", Pusher: true, Enabled: true, Seen: now.Unix(),
				Stats: map[string]backup.Stats{
					"forgejo": {LocalBytes: &local, At: now.Unix()},
					"zeta":    {LocalBytes: &local, At: now.Unix()},
					"canary":  {LocalBytes: &local, LastBackup: now.Unix() - 120, At: now.Unix()},
				}}},
			{Target: backup.Target{ID: "h009", Enabled: true, Seen: now.Unix(),
				Stats: map[string]backup.Stats{"canary": {LocalBytes: &local, At: now.Unix()}}}},
		},
		Subjects: []string{"forgejo"},
	}
	tb := BuildBackupTable(e, 6.95, now)
	var got []string
	for _, r := range tb.Rows {
		got = append(got, r.Subject)
	}
	if strings.Join(got, ",") != "default,forgejo,canary,zeta" {
		t.Fatalf("subjects: %v", got)
	}
	if f := tb.Rows[1]; f.Unlisted || f.Target != "h004" || f.TargetNote != "default" {
		t.Fatalf("forgejo: %+v", f)
	}
	c := tb.Rows[2]
	if !c.Unlisted || c.TargetNote != "not in inventory" || c.Target != "-" || c.Offsite ||
		c.RetentionLocal != "-" || c.RetentionB2 != "-" || c.OffsiteNote != "" || c.Revision != 0 {
		t.Fatalf("canary policy: %+v", c)
	}
	if c.Local != "5.0 MiB" || c.Cost != "-" || c.LastBackup == "-" || !strings.HasPrefix(c.StatsAt, "h004 @ ") {
		t.Fatalf("canary stats: %+v", c)
	}
}

func TestBuildBackupTableWrittenByUnion(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	local, b2 := int64(10<<20), int64(1e12)
	oldLocal, oldB2 := int64(1<<20), int64(2e12)
	selected := backup.TargetView{Target: backup.Target{
		ID: "h004", Enabled: true, Pusher: true, Seen: now.Unix(),
		Stats: map[string]backup.Stats{
			"canary":  {LocalBytes: &local, B2Bytes: &b2, LastBackup: now.Unix() - 60, LastCopied: now.Unix() - 30, At: now.Unix()},
			"unknown": {LocalBytes: &local, At: now.Unix()},
		},
	}}
	stale := backup.TargetView{Target: backup.Target{
		ID: "h009", Enabled: true, Seen: now.Add(-24 * time.Hour).Unix(),
		Stats: map[string]backup.Stats{
			"canary": {LocalBytes: &oldLocal, B2Bytes: &oldB2, LastBackup: now.Add(-24 * time.Hour).Unix(),
				LastCopied: now.Add(-23 * time.Hour).Unix(), At: now.Add(-24 * time.Hour).Unix(), WrittenBy: backup.WrittenByLow},
		},
	}, Stale: true}
	for _, tc := range []struct {
		name    string
		targets []backup.TargetView
	}{
		{"selected holder first", []backup.TargetView{selected, stale}},
		{"stale holder first", []backup.TargetView{stale, selected}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := backup.Export{
				Rows: []*backup.Row{
					{Subject: "canary", Target: "h004", Offsite: true, RetentionLocal: "standard", RetentionB2: "local"},
					{Subject: "unknown", Target: "h004", RetentionLocal: "standard", RetentionB2: "local"},
				},
				Targets:  tc.targets,
				Subjects: []string{"canary", "unknown"},
			}
			tb := BuildBackupTable(e, 6.95, now)
			if len(tb.Rows) != 3 {
				t.Fatalf("rows: %+v", tb.Rows)
			}
			c := tb.Rows[1]
			if c.Subject != "canary" || c.WrittenBy != backup.WrittenByLow {
				t.Fatalf("stale holder's low-trust history lost: %+v", c)
			}
			if c.Target != "h004" || c.TargetNote != "" || c.Local != "10.0 MiB" || c.B2 != "931.3 GiB" || c.Cost != "$6.95" ||
				c.LastBackup != ago(now.Unix()-60, now) || c.LastCopy != ago(now.Unix()-30, now) ||
				c.StatsAt != "h004 @ "+now.UTC().Format("2006-01-02 15:04") {
				t.Fatalf("selected holder's newer stats changed by provenance union: %+v", c)
			}
			if u := tb.Rows[2]; u.Subject != "unknown" || u.WrittenBy != "" {
				t.Fatalf("unknown provenance marked: %+v", u)
			}
			if tb.Rows[0].WrittenBy != "" {
				t.Fatalf("default provenance invented: %+v", tb.Rows[0])
			}
		})
	}
}

func TestBuildBackupTableWrittenByWithoutStats(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	e := backup.Export{
		Rows:     []*backup.Row{{Subject: "known", Target: "h004", Offsite: true, RetentionLocal: "standard", RetentionB2: "local"}},
		Targets:  []backup.TargetView{{Target: backup.Target{ID: "h004", Enabled: true, Pusher: true, Seen: now.Unix()}}},
		Subjects: []string{"known", "unknown"},
		WrittenBy: map[string]string{
			"known":   backup.WrittenByLow,
			"retired": backup.WrittenByLow,
		},
	}
	tb := BuildBackupTable(e, 6.95, now)
	var subjects []string
	for _, r := range tb.Rows {
		subjects = append(subjects, r.Subject)
		if r.Local != "-" || r.B2 != "-" || r.Cost != "-" || r.LastBackup != "-" || r.LastCopy != "-" || r.StatsAt != "" {
			t.Errorf("stats invented for provenance-only subject: %+v", r)
		}
		want := ""
		if r.Subject == "known" || r.Subject == "retired" {
			want = backup.WrittenByLow
		}
		if r.WrittenBy != want {
			t.Errorf("%s writtenBy = %q, want %q", r.Subject, r.WrittenBy, want)
		}
	}
	if strings.Join(subjects, ",") != "default,known,unknown,retired" {
		t.Fatalf("subjects: %v", subjects)
	}
	if r := tb.Rows[1]; r.Target != "h004" || r.Unlisted || !r.Offsite {
		t.Errorf("canonical inventory subject's policy changed: %+v", r)
	}
	if r := tb.Rows[3]; !r.Unlisted || r.Target != "-" || r.TargetNote != "not in inventory" || r.Offsite ||
		r.RetentionLocal != "-" || r.RetentionB2 != "-" || r.Revision != 0 || r.Clear != "" {
		t.Errorf("retired provenance-only subject's policy invented: %+v", r)
	}
}
