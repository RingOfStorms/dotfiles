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
