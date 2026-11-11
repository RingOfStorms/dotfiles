package main

import (
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
)

// A move's preflight on the destination resolves the subject's backup policy,
// so the destination may read it while the move is in flight, and only then
// (BACKUP-PLAN §2.7). Regression: the reader check used the committed host
// only, so every `cnt move` failed its destination preflight with 403.
func TestOwnsSubjectFollowsPlacement(t *testing.T) {
	owner := map[string]string{"canary": "lio"}
	committed := placements.Export{Rows: []*placements.Row{{Service: "s", Host: "h003", State: placements.Committed}}}
	moving := placements.Export{Rows: []*placements.Row{{Service: "s", Host: "h001", State: placements.Prepared, Previous: &placements.Binding{Host: "h003"}}}}
	for _, c := range []struct {
		name string
		e    placements.Export
		host string
		subj string
		owns bool
	}{
		{"committed host", committed, "h003", "s", true},
		{"other host", committed, "h001", "s", false},
		{"move source", moving, "h003", "s", true},
		{"move destination", moving, "h001", "s", true},
		{"bystander during move", moving, "lio", "s", false},
		{"unplaced", placements.Export{}, "h001", "s", false},
		{"empty host", committed, "", "s", false},
		{"host subject owner", committed, "lio", "canary", true},
		{"host subject other", committed, "h003", "canary", false},
	} {
		if got := ownsSubject(owner, c.e, c.host, c.subj); got != c.owns {
			t.Errorf("%s: ownsSubject(%s, %s) = %v, want %v", c.name, c.host, c.subj, got, c.owns)
		}
	}
}
