package bunny

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func spec() *Spec {
	return &Spec{
		Zone: "example.com",
		Records: []Desired{
			{Name: "o002", Type: "A", Value: "1.2.3.4", TTL: 300, Source: "hand"},
			{Name: "photos", Type: "CNAME", Value: "o002.example.com", TTL: 300, Source: "immich.web"},
			{Name: "git", Type: "CNAME", Value: "o002.example.com", TTL: 300, Source: "forgejo.web"},
			{Name: "new", Type: "CNAME", Value: "o002.example.com", TTL: 300, Source: "x.web"},
			{Name: "docs", Type: "CNAME", Value: "o002.example.com", TTL: 300, Source: "p.web"},
		},
		External: []string{"home"},
	}
}

func zone() *Zone {
	return &Zone{ID: 1, Domain: "example.com", Records: []Record{
		{ID: 10, Type: 0, Name: "o002", Value: "1.2.3.4", TTL: 300},
		{ID: 11, Type: 2, Name: "photos", Value: "o002.example.com.", TTL: 300},
		{ID: 12, Type: 2, Name: "git", Value: "o002.example.com", TTL: 3600},
		{ID: 13, Type: 0, Name: "docs", Value: "100.64.0.13", TTL: 300},
		{ID: 14, Type: 0, Name: "home", Value: "5.6.7.8", TTL: 300},
		{ID: 15, Type: 3, Name: "", Value: "v=spf1 -all", TTL: 300},
	}}
}

func byName(p []Change) map[string]Change {
	m := map[string]Change{}
	for _, c := range p {
		m[c.Name+"/"+c.Type] = c
	}
	return m
}

func TestPlan(t *testing.T) {
	m := byName(Plan(spec(), zone()))
	want := map[string]string{
		"o002/A":       Keep,
		"photos/CNAME": Keep, // trailing dot and case don't matter
		"git/CNAME":    Update,
		"new/CNAME":    Create,
		"docs/CNAME":   Conflict, // A record in the way: never replaced silently
		"home/A":       External,
		"/TXT":         Unmanaged,
	}
	for k, a := range want {
		if m[k].Action != a {
			t.Errorf("%s: got %q want %q", k, m[k].Action, a)
		}
	}
	if len(m) != len(want) {
		t.Errorf("plan has %d entries, want %d: %+v", len(m), len(want), m)
	}
	if m["git/CNAME"].ID != 12 {
		t.Errorf("update must carry the live id")
	}
}

// The CNAME set follows the registry: an unplaced service's record is retired
// only on an exact match (a changed record blocks Apply), a placed one and a
// hand name are planned as before, and the input spec is left alone.
func TestForPlacements(t *testing.T) {
	s := spec()
	for i := range s.Records {
		switch s.Records[i].Name {
		case "photos":
			s.Records[i].Service = "immich"
		case "git":
			s.Records[i].Service = "forgejo"
		case "new":
			s.Records[i].Service = "x"
		}
	}
	z := zone()
	z.Records = append(z.Records, Record{ID: 16, Type: 2, Name: "new", Value: "elsewhere.example.com", TTL: 300})
	placed := map[string]bool{"forgejo": true}
	f := s.ForPlacements(func(svc string) bool { return placed[svc] })
	if err := f.Validate(); err != nil {
		t.Fatal(err)
	}
	m := byName(PlanWith(f, z, nil))
	want := map[string]string{
		"o002/A":       Keep,
		"git/CNAME":    Update,
		"photos/CNAME": Retire,
		"new/CNAME":    RetireMismatch,
	}
	for k, a := range want {
		if m[k].Action != a {
			t.Errorf("%s: got %q want %q", k, m[k].Action, a)
		}
	}
	if len(s.Records) != 5 || len(s.Retire) != 0 {
		t.Errorf("input spec changed: %+v", s)
	}
	if _, err := Ops(1, PlanWith(f, z, nil)); err == nil {
		t.Error("a retire-mismatch must block the plan")
	}
}

func TestValidate(t *testing.T) {
	s := spec()
	s.Records = append(s.Records, Desired{Name: "evil", Type: "CNAME", Value: "attacker.net", TTL: 300})
	if err := s.Validate(); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("external CNAME target accepted: %v", err)
	}
	s = spec()
	s.Records = append(s.Records, s.Records[0])
	if err := s.Validate(); err == nil {
		t.Fatal("duplicate accepted")
	}
	s = spec()
	s.Records[0].TTL = 5
	if err := s.Validate(); err == nil {
		t.Fatal("ttl 5 accepted")
	}
}

func TestRender(t *testing.T) {
	var b bytes.Buffer
	Render(&b, "example.com", Plan(spec(), zone()))
	out := b.String()
	for _, s := range []string{"create    new", "1 create, 1 update, 0 retire, 1 conflict, 0 retire-mismatch, 2 keep, 0 override, 1 external, 1 unmanaged", "unmanaged @"} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in\n%s", s, out)
		}
	}
}

func TestClientReadOnly(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("client sent %s", r.Method)
		}
		if r.Header.Get("AccessKey") != "k" {
			t.Errorf("missing key header")
		}
		w.Write([]byte(`{"Items":[{"Id":7,"Domain":"other.com","Records":[]},{"Id":1,"Domain":"example.com","Records":[{"Id":10,"Type":2,"Name":"a","Value":"b.example.com","Ttl":60}]}]}`))
	}))
	defer srv.Close()
	z, err := (&Client{Key: "k", Base: srv.URL}).ZoneByDomain(context.Background(), "example.com")
	if err != nil {
		t.Fatal(err)
	}
	if z.ID != 1 || len(z.Records) != 1 || z.Records[0].Value != "b.example.com" {
		t.Fatalf("got %+v", z)
	}
	if _, err := (&Client{Key: "k", Base: srv.URL}).ZoneByDomain(context.Background(), "missing.com"); err == nil {
		t.Fatal("missing zone not reported")
	}
}
