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
