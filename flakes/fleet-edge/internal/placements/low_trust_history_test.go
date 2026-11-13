package placements

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"
)

func setPlacementHostTrust(r *rig, host, trust string) {
	h := r.s.cfg.Inventory.Hosts[host]
	h.Trust = trust
	r.s.cfg.Inventory.Hosts[host] = h
}

func assertPlacementLowTrustSubjects(t *testing.T, s *Service, want map[string]bool) Export {
	t.Helper()
	check := func(where string, got map[string]bool) {
		t.Helper()
		if len(got) != len(want) {
			t.Fatalf("%s low-trust subjects = %v, want %v", where, got, want)
		}
		for subject, low := range want {
			if marked, ok := got[subject]; !ok || marked != low {
				t.Fatalf("%s low-trust subjects = %v, want %v", where, got, want)
			}
		}
	}
	check("registry", s.lowTrustSubjects)
	ex := s.export()
	check("export", ex.LowTrustSubjects)

	req := httptest.NewRequest("GET", "/internal/placements.json", nil)
	req.RemoteAddr = "127.0.0.1:1"
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("loopback export: %d %s", w.Code, w.Body.String())
	}
	var httpExport Export
	if err := json.Unmarshal(w.Body.Bytes(), &httpExport); err != nil {
		t.Fatal(err)
	}
	check("HTTP export", httpExport.LowTrustSubjects)

	b, err := os.ReadFile(s.statePath())
	if err != nil {
		t.Fatal(err)
	}
	var persisted state
	if err := json.Unmarshal(b, &persisted); err != nil {
		t.Fatal(err)
	}
	check("persisted state", persisted.LowTrustSubjects)
	return ex
}

func restartPlacementLowTrustRig(t *testing.T, r *rig) {
	t.Helper()
	if err := r.s.audit.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := New(r.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	r.s = again
}

func TestPlacementLowTrustHistoryBeforeFirstExport(t *testing.T) {
	place := func(r *rig, host string) {
		r.t.Helper()
		if c, out := r.reserve("app", host, false); c != 200 {
			r.t.Fatalf("reserve on %s: %d %v", host, c, out)
		}
		r.up(host, "app")
		if c, out := r.commit("app"); c != 200 {
			r.t.Fatalf("commit on %s: %d %v", host, c, out)
		}
	}
	importLow := func(r *rig) {
		r.t.Helper()
		r.up("h001", "app")
		if c, out := r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "app", Host: "h001"}}}); c != 200 {
			r.t.Fatalf("import low placement: %d %v", c, out)
		}
	}
	for _, tc := range []struct {
		name     string
		finish   func(*rig)
		wantHost string
	}{
		{
			name: "low committed placement moved high and retired",
			finish: func(r *rig) {
				place(r, "h001")
				if c, out := r.reserve("app", "h003", false); c != 200 {
					r.t.Fatalf("reserve high move: %d %v", c, out)
				}
				r.stop("h001", "app")
				r.up("h003", "app")
				if c, out := r.commit("app"); c != 200 {
					r.t.Fatalf("commit high move: %d %v", c, out)
				}
				if c, out := r.call("POST", "/api/placements/retire", Request{Service: "app", Token: r.tok}); c != 200 {
					r.t.Fatalf("retire low source: %d %v", c, out)
				}
				r.gone("h001")
				r.s.Sweep(context.Background())
			},
			wantHost: "h003",
		},
		{
			name: "low reservation rolled back to high source",
			finish: func(r *rig) {
				place(r, "h003")
				if c, out := r.reserve("app", "h001", false); c != 200 {
					r.t.Fatalf("reserve low destination: %d %v", c, out)
				}
				if c, out := r.del("app", false); c != 200 {
					r.t.Fatalf("rollback low reservation: %d %v", c, out)
				}
			},
			wantHost: "h003",
		},
		{
			name: "low committed move rolled back to high source",
			finish: func(r *rig) {
				place(r, "h003")
				if c, out := r.reserve("app", "h001", false); c != 200 {
					r.t.Fatalf("reserve low destination: %d %v", c, out)
				}
				r.stop("h003", "app")
				r.up("h001", "app")
				if c, out := r.commit("app"); c != 200 {
					r.t.Fatalf("commit low destination: %d %v", c, out)
				}
				if c, out := r.del("app", false); c != 200 {
					r.t.Fatalf("rollback low committed move: %d %v", c, out)
				}
			},
			wantHost: "h003",
		},
		{
			name: "first low reservation deleted",
			finish: func(r *rig) {
				if c, out := r.reserve("app", "h001", false); c != 200 {
					r.t.Fatalf("reserve low destination: %d %v", c, out)
				}
				if c, out := r.del("app", false); c != 200 {
					r.t.Fatalf("delete low reservation: %d %v", c, out)
				}
			},
		},
		{
			name: "low committed placement deleted",
			finish: func(r *rig) {
				place(r, "h001")
				if c, out := r.delRev("app", r.s.rows["app"].Revision); c != 200 {
					r.t.Fatalf("delete low placement: %d %v", c, out)
				}
			},
		},
		{
			name: "low import replaced by high import",
			finish: func(r *rig) {
				importLow(r)
				r.gone("h001")
				r.up("h003", "app")
				if c, out := r.call("POST", "/api/placements/import", Import{Force: true, Placements: []Placement{{Service: "app", Host: "h003"}}}); c != 200 {
					r.t.Fatalf("replace low import: %d %v", c, out)
				}
			},
			wantHost: "h003",
		},
		{
			name: "low import deleted",
			finish: func(r *rig) {
				importLow(r)
				if c, out := r.delRev("app", r.s.rows["app"].Revision); c != 200 {
					r.t.Fatalf("delete low import: %d %v", c, out)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)
			t.Cleanup(func() { _ = r.s.audit.Close() })
			r.s.cfg.Status = r.status
			setPlacementHostTrust(r, "h001", "low")
			setPlacementHostTrust(r, "h003", "high")
			tc.finish(r)
			if tc.wantHost == "" {
				if r.s.rows["app"] != nil {
					t.Fatalf("deleted placement still has a row: %+v", r.s.rows["app"])
				}
			} else if m := r.s.rows["app"]; m == nil || m.Host != tc.wantHost || m.State != Committed || m.Previous != nil || m.Token != "" {
				t.Fatalf("low binding or previous still present: %+v", m)
			}

			// No export or backup reader has observed the transient low binding.
			// Promotion cannot reconstruct that history from the remaining rows.
			setPlacementHostTrust(r, "h001", "high")
			want := map[string]bool{"app": true}
			if ex := assertPlacementLowTrustSubjects(t, r.s, want); ex.Host["app"] != tc.wantHost {
				t.Fatalf("export host = %q, want %q", ex.Host["app"], tc.wantHost)
			}
			restartPlacementLowTrustRig(t, r)
			assertPlacementLowTrustSubjects(t, r.s, want)

			if tc.wantHost != "" {
				if c, out := r.delRev("app", r.s.rows["app"].Revision); c != 200 {
					t.Fatalf("delete remaining high placement: %d %v", c, out)
				}
				if ex := assertPlacementLowTrustSubjects(t, r.s, want); len(ex.Rows) != 0 || len(ex.Host) != 0 {
					t.Fatalf("row deletion left placement state: %+v", ex)
				}
				restartPlacementLowTrustRig(t, r)
				assertPlacementLowTrustSubjects(t, r.s, want)
			}
		})
	}
}

func TestPlacementLowTrustHistorySeedsLegacyBindings(t *testing.T) {
	for _, format := range []string{"bare rows", "state without history"} {
		t.Run(format, func(t *testing.T) {
			r := newRig(t)
			t.Cleanup(func() { _ = r.s.audit.Close() })
			setPlacementHostTrust(r, "h001", "low")
			setPlacementHostTrust(r, "h003", "high")
			rows := []*Row{
				{Service: "app", Host: "h003", State: Committed, Previous: &Binding{Host: "h001"}, Revision: 1},
				{Service: "web", Host: "h001", State: Committed, Revision: 2},
				{Service: "db", Host: "h003", State: Committed, Revision: 3},
			}
			var legacy any = rows
			if format == "state without history" {
				legacy = state{Revision: 3, Rows: rows}
			}
			b, err := json.Marshal(legacy)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(r.s.statePath(), b, 0o600); err != nil {
				t.Fatal(err)
			}
			restartPlacementLowTrustRig(t, r)
			// The migration must save both current and previous low bindings,
			// not merely expose them while the inventory still labels h001 low.
			setPlacementHostTrust(r, "h001", "high")
			restartPlacementLowTrustRig(t, r)
			want := map[string]bool{"app": true, "web": true}
			assertPlacementLowTrustSubjects(t, r.s, want)

			if c, out := r.delRev("app", r.s.rows["app"].Revision); c != 200 {
				t.Fatalf("rollback migrated previous: %d %v", c, out)
			}
			if m := r.s.rows["app"]; m == nil || m.Host != "h001" || m.Previous != nil {
				t.Fatalf("rollback did not remove previous: %+v", m)
			}
			for _, subject := range []string{"app", "web"} {
				if c, out := r.delRev(subject, r.s.rows[subject].Revision); c != 200 {
					t.Fatalf("delete migrated %s: %d %v", subject, c, out)
				}
			}
			restartPlacementLowTrustRig(t, r)
			if ex := assertPlacementLowTrustSubjects(t, r.s, want); len(ex.Rows) != 1 || ex.Host["db"] != "h003" {
				t.Fatalf("unexpected remaining placements: %+v", ex)
			}
		})
	}
}

func TestPlacementLowTrustUsesDestinationInventory(t *testing.T) {
	for _, action := range []string{"reserve", "import"} {
		for _, trust := range []string{"low", "high", ""} {
			t.Run(action+"/destination trust "+trust, func(t *testing.T) {
				r := newRig(t)
				t.Cleanup(func() { _ = r.s.audit.Close() })
				setPlacementHostTrust(r, "lio", "high")
				setPlacementHostTrust(r, "h001", trust)
				path := "/api/placements/" + action
				var body any = Request{Service: "app", Host: "h001", User: "high-trust-operator"}
				if action == "import" {
					body = Import{User: "high-trust-operator", Placements: []Placement{{Service: "app", Host: "h001"}}}
				}
				if c, out := r.callTok("POST", path, lioPeer, "good-"+lioSub, body); c != 200 {
					t.Fatalf("%s by high-trust writer: %d %v", action, c, out)
				}
				if m := r.s.rows["app"]; m == nil || m.Device != "lio" || m.User != "high-trust-operator" {
					t.Fatalf("request did not retain the high-trust operator identity: %+v", m)
				}
				want := map[string]bool{}
				if trust == "low" {
					want["app"] = true
				}
				assertPlacementLowTrustSubjects(t, r.s, want)
			})
		}
	}
}

func TestPlacementLowTrustSaveFailureIsAtomic(t *testing.T) {
	for _, tc := range []struct {
		name      string
		placeHigh bool
		request   func(*rig) (int, map[string]any)
	}{
		{
			name: "first low reserve",
			request: func(r *rig) (int, map[string]any) {
				return r.reserve("app", "h001", false)
			},
		},
		{
			name:      "high to low reserve",
			placeHigh: true,
			request: func(r *rig) (int, map[string]any) {
				return r.reserve("app", "h001", false)
			},
		},
		{
			name: "import low and high subjects",
			request: func(r *rig) (int, map[string]any) {
				r.up("h001", "app")
				r.up("h003", "web")
				return r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "app", Host: "h001"}, {Service: "web", Host: "h003"}}})
			},
		},
		{
			name:      "forced import high to low",
			placeHigh: true,
			request: func(r *rig) (int, map[string]any) {
				r.up("h001", "app")
				return r.call("POST", "/api/placements/import", Import{Force: true, Placements: []Placement{{Service: "app", Host: "h001"}}})
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)
			t.Cleanup(func() { _ = r.s.audit.Close() })
			r.s.cfg.Status = r.status
			setPlacementHostTrust(r, "h001", "low")
			setPlacementHostTrust(r, "h003", "high")
			r.up("h001", "keep")
			if c, out := r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "keep", Host: "h001"}}}); c != 200 {
				t.Fatalf("seed prior low history: %d %v", c, out)
			}
			if c, out := r.delRev("keep", r.s.rows["keep"].Revision); c != 200 {
				t.Fatalf("delete prior low placement: %d %v", c, out)
			}
			if tc.placeHigh {
				r.up("h003", "app")
				if c, out := r.reserve("app", "h003", false); c != 200 {
					t.Fatalf("reserve high source: %d %v", c, out)
				}
				if c, out := r.commit("app"); c != 200 {
					t.Fatalf("commit high source: %d %v", c, out)
				}
			}
			want := map[string]bool{"keep": true}
			assertPlacementLowTrustSubjects(t, r.s, want)
			before := snapshot(r)
			notified := 0
			r.s.cfg.Notify = func() { notified++ }
			restore := r.broke()
			c, out := tc.request(r)
			restore()
			if c != 500 {
				t.Fatalf("low-trust write with an unwritable state dir: %d %v", c, out)
			}
			if out["row"] != nil || out["imported"] != nil {
				t.Fatalf("failed write returned uncommitted state: %v", out)
			}
			if notified != 0 {
				t.Fatalf("failed write notified readers %d times", notified)
			}
			assertPlacementLowTrustSubjects(t, r.s, want)
			before.check(t, r, tc.name)
			restartPlacementLowTrustRig(t, r)
			assertPlacementLowTrustSubjects(t, r.s, want)
		})
	}
}

func TestPlacementLowTrustRecordsRemovedBindingsAtomically(t *testing.T) {
	for _, tc := range []struct {
		name     string
		start    string
		reserve  string
		request  func(*rig) (int, map[string]any)
		wantHost string
	}{
		{
			name:  "delete low current binding",
			start: "h001",
			request: func(r *rig) (int, map[string]any) {
				return r.delRev("app", r.s.rows["app"].Revision)
			},
		},
		{
			name:    "rollback low destination",
			start:   "h003",
			reserve: "h001",
			request: func(r *rig) (int, map[string]any) {
				return r.del("app", false)
			},
			wantHost: "h003",
		},
		{
			name:  "replace low current binding with high import",
			start: "h001",
			request: func(r *rig) (int, map[string]any) {
				return r.call("POST", "/api/placements/import", Import{Force: true, Placements: []Placement{{Service: "app", Host: "h003"}}})
			},
			wantHost: "h003",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)
			t.Cleanup(func() { _ = r.s.audit.Close() })
			setPlacementHostTrust(r, "h001", "high")
			setPlacementHostTrust(r, "h003", "high")
			if c, out := r.call("POST", "/api/placements/import", Import{Placements: []Placement{{Service: "app", Host: tc.start}}}); c != 200 {
				t.Fatalf("seed placement before inventory change: %d %v", c, out)
			}
			if tc.reserve != "" {
				if c, out := r.reserve("app", tc.reserve, false); c != 200 {
					t.Fatalf("seed move before inventory change: %d %v", c, out)
				}
			}
			before := snapshot(r)
			// The inventory now identifies the old binding as low. The next
			// stage erases that binding, so inspecting only its new rows loses it.
			setPlacementHostTrust(r, "h001", "low")
			restore := r.broke()
			c, out := tc.request(r)
			restore()
			if c != 500 || out["row"] != nil || out["imported"] != nil {
				t.Fatalf("failed removal exposed staged state: %d %v", c, out)
			}
			assertPlacementLowTrustSubjects(t, r.s, map[string]bool{})
			// Avoid a fresh constructor independently seeding the still-present
			// binding: only the failed stage is under test here.
			setPlacementHostTrust(r, "h001", "high")
			before.check(t, r, tc.name)
			setPlacementHostTrust(r, "h001", "low")
			if c, out := tc.request(r); c != 200 {
				t.Fatalf("retry removal with writable state: %d %v", c, out)
			}
			if tc.wantHost == "" {
				if r.s.rows["app"] != nil {
					t.Fatalf("delete left a binding: %+v", r.s.rows["app"])
				}
			} else if m := r.s.rows["app"]; m == nil || m.Host != tc.wantHost || m.Previous != nil {
				t.Fatalf("removal left a low binding: %+v", m)
			}
			setPlacementHostTrust(r, "h001", "high")
			restartPlacementLowTrustRig(t, r)
			assertPlacementLowTrustSubjects(t, r.s, map[string]bool{"app": true})
		})
	}
}
