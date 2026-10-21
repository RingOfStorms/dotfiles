package bunny

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// fakeBunny is an in-memory bunny DNS API for one zone.
type fakeBunny struct {
	mu   sync.Mutex
	zone Zone
	next int64
	log  []string
}

func (f *fakeBunny) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("AccessKey") != "k" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	f.log = append(f.log, r.Method+" "+r.URL.Path)
	prefix := "/dnszone/" + strconv.FormatInt(f.zone.ID, 10) + "/records"
	switch {
	case r.Method == "GET" && r.URL.Path == "/dnszone":
		_ = json.NewEncoder(w).Encode(map[string]any{"Items": []Zone{f.zone}})
	case r.Method == "PUT" && r.URL.Path == prefix:
		var rec Record
		_ = json.NewDecoder(r.Body).Decode(&rec)
		f.next++
		rec.ID = f.next
		f.zone.Records = append(f.zone.Records, rec)
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(rec)
	case strings.HasPrefix(r.URL.Path, prefix+"/"):
		id, err := strconv.ParseInt(strings.TrimPrefix(r.URL.Path, prefix+"/"), 10, 64)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		for i, rec := range f.zone.Records {
			if rec.ID != id {
				continue
			}
			switch r.Method {
			case "POST":
				var upd Record
				_ = json.NewDecoder(r.Body).Decode(&upd)
				upd.ID = id
				f.zone.Records[i] = upd
			case "DELETE":
				f.zone.Records = append(f.zone.Records[:i], f.zone.Records[i+1:]...)
			default:
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func liveZone() Zone {
	return Zone{ID: 7, Domain: "example.com", Records: []Record{
		{ID: 1, Type: 2, Name: "photos", Value: "o002.example.com", TTL: 3600}, // ttl update
		{ID: 2, Type: 0, Name: "docs", Value: "100.64.0.13", TTL: 3600},        // retire
		{ID: 3, Type: 2, Name: "kura", Value: "o002.example.com", TTL: 3600},   // retire
		{ID: 4, Type: 4, Name: "", Value: "mx.mail.example", TTL: 3600},        // unmanaged
		{ID: 5, Type: 0, Name: "home", Value: "9.9.9.9", TTL: 60},              // external
	}}
}

func applySpec() *Spec {
	return &Spec{
		Zone: "example.com",
		Records: []Desired{
			{Name: "photos", Type: "CNAME", Value: "o002.example.com", TTL: 300},
			{Name: "git", Type: "CNAME", Value: "o002.example.com", TTL: 300}, // create
		},
		External: []string{"home"},
		Retire: []Retired{
			{Name: "docs", Type: "A", Value: "100.64.0.13"},
			{Name: "kura", Type: "CNAME", Value: "o002.example.com."},
			{Name: "gone", Type: "A", Value: "1.2.3.4"}, // absent: no-op
		},
	}
}

func run(t *testing.T, f *fakeBunny, spec *Spec) (int, error) {
	t.Helper()
	srv := httptest.NewServer(f)
	defer srv.Close()
	c := &Client{Key: "k", Base: srv.URL}
	z, err := c.ZoneByDomain(context.Background(), spec.Zone)
	if err != nil {
		t.Fatal(err)
	}
	ops, err := Ops(z.ID, Plan(spec, z))
	if err != nil {
		return 0, err
	}
	return len(ops), c.Apply(context.Background(), ops, nil)
}

func TestApplyConverges(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	if err := applySpec().Validate(); err != nil {
		t.Fatal(err)
	}
	n, err := run(t, f, applySpec())
	if err != nil || n != 4 {
		t.Fatalf("first apply: n=%d err=%v log=%v", n, err, f.log)
	}
	want := []string{"GET /dnszone", "PUT /dnszone/7/records", "POST /dnszone/7/records/1",
		"DELETE /dnszone/7/records/2", "DELETE /dnszone/7/records/3"}
	if strings.Join(f.log, ",") != strings.Join(want, ",") {
		t.Fatalf("calls %v, want %v", f.log, want)
	}
	got := map[string]Record{}
	for _, r := range f.zone.Records {
		got[r.Name] = r
	}
	if len(got) != 4 || got["photos"].TTL != 300 || got["git"].Value != "o002.example.com" ||
		got["home"].Value != "9.9.9.9" || got[""].Type != 4 {
		t.Fatalf("zone after apply: %+v", f.zone.Records)
	}
	// second run: nothing left to do
	f.log = nil
	n, err = run(t, f, applySpec())
	if err != nil || n != 0 || len(f.log) != 1 {
		t.Fatalf("second apply: n=%d err=%v log=%v", n, err, f.log)
	}
}

func TestRetireMismatchRefusesEverything(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    Retired
	}{
		{"value", Retired{Name: "docs", Type: "A", Value: "100.64.0.14"}},
		{"type", Retired{Name: "kura", Type: "A", Value: "o002.example.com"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeBunny{zone: liveZone(), next: 100}
			s := applySpec()
			s.Retire = []Retired{tc.r}
			_, err := run(t, f, s)
			if err == nil || !strings.Contains(err.Error(), "retire-mismatch") {
				t.Fatalf("want refusal, got %v", err)
			}
			if len(f.log) != 1 || len(f.zone.Records) != 5 {
				t.Fatalf("wrote despite refusal: %v", f.log)
			}
		})
	}
}

func TestConflictRefusesEverything(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	s := applySpec()
	s.Records = append(s.Records, Desired{Name: "docs2", Type: "CNAME", Value: "o002.example.com", TTL: 300})
	f.zone.Records = append(f.zone.Records, Record{ID: 9, Type: 0, Name: "docs2", Value: "1.1.1.1", TTL: 60})
	if _, err := run(t, f, s); err == nil || len(f.log) != 1 {
		t.Fatalf("conflict should block all writes: err=%v log=%v", err, f.log)
	}
}

func TestApplyStopsOnError(t *testing.T) {
	f := &fakeBunny{zone: liveZone(), next: 100}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		f.ServeHTTP(w, r)
	}))
	defer srv.Close()
	c := &Client{Key: "k", Base: srv.URL}
	z, _ := c.ZoneByDomain(context.Background(), "example.com")
	ops, err := Ops(z.ID, Plan(applySpec(), z))
	if err != nil {
		t.Fatal(err)
	}
	var done int
	if err := c.Apply(context.Background(), ops, func(Op) { done++ }); err == nil || done != 2 {
		t.Fatalf("want stop at first delete: done=%d err=%v", done, err)
	}
}

func TestValidateRetire(t *testing.T) {
	s := applySpec()
	s.Retire = append(s.Retire, Retired{Name: "photos", Type: "CNAME", Value: "o002.example.com"})
	if s.Validate() == nil {
		t.Fatal("retiring a declared name must fail")
	}
	s = applySpec()
	s.Retire = []Retired{{Name: "x", Type: "BOGUS", Value: "v"}}
	if s.Validate() == nil {
		t.Fatal("unknown type must fail")
	}
}
