package bunny

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func TestPlanOverrideNeverRetiredOrConflict(t *testing.T) {
	z := &Zone{ID: 7, Domain: "example.com", Records: []Record{
		{ID: 10, Type: 2, Name: "notes", Value: "o002.example.com", TTL: 60}, // retire-listed, owned
		{ID: 11, Type: 2, Name: "temp", Value: "o002.example.com", TTL: 60},  // owned, unlisted
		{ID: 12, Type: 2, Name: "other", Value: "o002.example.com", TTL: 60}, // not owned
	}}
	spec := &Spec{Zone: "example.com", Retire: []Retired{{Name: "notes", Type: "CNAME", Value: "o002.example.com"}}}
	plan := PlanWith(spec, z, []Owned{{ID: 10, Name: "notes", Service: "trilium"}, {ID: 11, Name: "temp", Service: "x"}})
	got := map[string]string{}
	for _, c := range plan {
		got[c.Name] = c.Action
	}
	if got["notes"] != Override || got["temp"] != Override || got["other"] != Unmanaged {
		t.Fatalf("plan: %v", got)
	}
	ops, err := Ops(z.ID, plan)
	if err != nil || len(ops) != 0 {
		t.Fatalf("ops %v err %v, want none", ops, err)
	}
	// Without the owned list the retire would delete the override's record.
	ops, _ = Ops(z.ID, Plan(spec, z))
	if len(ops) != 1 || ops[0].Method != "DELETE" {
		t.Fatalf("baseline ops %v", ops)
	}
}

func TestPlanOverrideOwnedIDMismatchIgnored(t *testing.T) {
	z := &Zone{ID: 7, Domain: "example.com", Records: []Record{{ID: 10, Type: 2, Name: "notes", Value: "o002.example.com", TTL: 60}}}
	spec := &Spec{Zone: "example.com"}
	// Owned under another name (record was renamed by hand): not an override.
	for _, c := range PlanWith(spec, z, []Owned{{ID: 10, Name: "other"}}) {
		if c.Action == Override {
			t.Fatalf("renamed record treated as owned: %+v", c)
		}
	}
}

func TestPlanOverrideDeclaredNameWins(t *testing.T) {
	z := &Zone{ID: 7, Domain: "example.com", Records: []Record{{ID: 10, Type: 2, Name: "app", Value: "o002.example.com", TTL: 60}}}
	spec := &Spec{Zone: "example.com", Records: []Desired{{Name: "app", Type: "CNAME", Value: "o002.example.com", TTL: 300}}}
	plan := PlanWith(spec, z, []Owned{{ID: 10, Name: "app"}})
	if len(plan) != 1 || plan[0].Action != Update {
		t.Fatalf("declared name must plan normally: %+v", plan)
	}
}

func TestCreateDeleteRecord(t *testing.T) {
	f := &fakeBunny{zone: Zone{ID: 7, Domain: "example.com"}, next: 100}
	srv := httptest.NewServer(f)
	defer srv.Close()
	c := &Client{Key: "k", Base: srv.URL}
	ctx := context.Background()
	id, err := c.CreateRecord(ctx, 7, "tmp", "CNAME", "o002.example.com", 60)
	if err != nil || id != 101 {
		t.Fatalf("create: %d %v", id, err)
	}
	z, _ := c.ZoneByDomain(ctx, "example.com")
	if r := z.FindRecord(id); r == nil || r.TTL != 60 || r.Name != "tmp" {
		t.Fatalf("record: %+v", r)
	}
	if err := c.DeleteRecord(ctx, 7, id); err != nil {
		t.Fatal(err)
	}
	if err := c.DeleteRecord(ctx, 7, id); err != nil {
		t.Fatalf("second delete must be a no-op: %v", err)
	}
}

func TestLock(t *testing.T) {
	p := filepath.Join(t.TempDir(), "lock")
	un, err := Lock(p)
	if err != nil {
		t.Fatal(err)
	}
	un()
	un, err = Lock(p)
	if err != nil {
		t.Fatal(err)
	}
	un()
}
