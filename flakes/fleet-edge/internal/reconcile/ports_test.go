package reconcile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/edgestream"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/placements"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/wanforward"
)

type fakeStreams struct {
	files         map[int]edgestream.Entry
	calls         []edgestream.Request
	fail, addFail bool
	old           bool
}

func (s *fakeStreams) DoStream(_ context.Context, req edgestream.Request) ([]byte, error) {
	s.calls = append(s.calls, req)
	if s.fail {
		return nil, errors.New("unreachable")
	}
	switch req.Op {
	case "list":
		if s.old {
			return []byte("[]"), nil
		}
		entries := []edgestream.Entry{}
		for _, e := range s.files {
			entries = append(entries, e)
		}
		return json.Marshal(edgestream.List{Streams: entries})
	case "add":
		if s.addFail {
			return nil, errors.New("nginx test failed")
		}
		s.files[req.Port] = edgestream.Entry{Port: req.Port, Kind: req.Kind, Host: req.Host}
	case "remove":
		cur := s.files[req.Port]
		if cur.Kind != req.Kind || cur.Host != req.Host {
			return []byte(edgestream.KeptPrefix), nil
		}
		delete(s.files, req.Port)
	}
	return nil, nil
}
func portRig(t *testing.T) (*rig, *fakeStreams) {
	rg := newRig(t)
	rg.r.cfg.Inventory.Services["forgejo"] = inventory.Service{Name: "forgejo", Routes: map[string]inventory.Route{"ssh": {Proto: "tcp", Port: 3032, Exposure: "public", Via: []string{"edge"}}}}
	mc := rg.r.cfg.Inventory.Services["minecraft"]
	rt := mc.Routes["game"]
	rt.Port = 25565
	mc.Routes["game"] = rt
	s := &fakeStreams{files: map[int]edgestream.Entry{}}
	rg.r.cfg.Streams = s
	rg.r.cfg.ForwardsFile = filepath.Join(t.TempDir(), "forwards.json")
	rg.r.cfg.ForwardsStatus = filepath.Join(t.TempDir(), "applied.json")
	return rg, s
}
func TestStreamAddsBeforeFencedRemoves(t *testing.T) {
	rg, s := portRig(t)
	s.files[4000] = edgestream.Entry{Port: 4000, Host: "h001", Kind: "placement"}
	s.files[4001] = edgestream.Entry{Port: 4001, Host: "h001", Kind: "other"}
	rg.place("forgejo", "h003", placements.Committed)
	rg.pass()
	if len(s.calls) != 3 || s.calls[0].Op != "list" || s.calls[1].Op != "add" || s.calls[2].Op != "remove" || s.calls[2].Host != "h001" || s.calls[2].Kind != "placement" {
		t.Fatalf("calls %+v", s.calls)
	}
	if s.files[3032].Host != "h003" || s.files[4001].Kind != "other" {
		t.Fatal(s.files)
	}
}
func TestStreamFailuresKeepLastSet(t *testing.T) {
	for _, mode := range []string{"stale", "no-ip", "duplicate", "unreachable", "old", "add-failed"} {
		t.Run(mode, func(t *testing.T) {
			rg, s := portRig(t)
			s.files[3032] = edgestream.Entry{Port: 3032, Host: "h001", Kind: "placement"}
			s.files[4000] = edgestream.Entry{Port: 4000, Host: "h001", Kind: "placement"}
			state := placements.Committed
			if mode == "stale" {
				state = placements.Stale
			}
			rg.place("forgejo", "h003", state)
			switch mode {
			case "no-ip":
				rg.r.cfg.Inventory.Hosts["h003"] = inventory.Host{}
			case "duplicate":
				rg.r.cfg.Inventory.Services["duplicate"] = rg.r.cfg.Inventory.Services["forgejo"]
			case "unreachable":
				s.fail = true
			case "old":
				s.old = true
			case "add-failed":
				s.addFail = true
			}
			rep := rg.pass()
			if s.files[3032].Host != "h001" {
				t.Fatalf("changed last answer: %+v", s.files)
			}
			if mode == "unreachable" || mode == "old" {
				if len(s.calls) != 1 || len(rep.Errors) == 0 {
					t.Fatal(s.calls, rep)
				}
			}
			if mode == "add-failed" {
				if _, ok := s.files[4000]; !ok {
					t.Fatal("removed after failed add")
				}
			}
		})
	}
}
func TestWANPlacementAndKeep(t *testing.T) {
	for _, mode := range []string{"placed", "unplaced", "stale", "no-lan", "duplicate", "source-failed"} {
		t.Run(mode, func(t *testing.T) {
			rg, _ := portRig(t)
			original := wanforward.Forward{Proto: "tcp", Port: 25565, Host: "h001", Source: "minecraft.game"}
			if err := wanforward.WriteAtomic(rg.r.cfg.ForwardsFile, wanforward.Marshal(wanforward.File{Forwards: []wanforward.Forward{original}})); err != nil {
				t.Fatal(err)
			}
			state := placements.Committed
			if mode == "stale" {
				state = placements.Stale
			}
			host := "h003"
			if mode == "no-lan" {
				host = "lio"
			}
			if mode != "unplaced" {
				rg.place("minecraft", host, state)
			}
			if mode == "duplicate" {
				rg.r.cfg.Inventory.Services["duplicate"] = rg.r.cfg.Inventory.Services["minecraft"]
			}
			if mode == "source-failed" {
				rg.srcErr = errors.New("unreachable registry")
			}
			rg.pass()
			f, err := wanforward.Read(rg.r.cfg.ForwardsFile)
			if err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "placed":
				if len(f.Forwards) != 1 || f.Forwards[0].Host != "h003" {
					t.Fatal(f)
				}
			case "unplaced":
				if len(f.Forwards) != 0 {
					t.Fatal(f)
				}
			default:
				if len(f.Forwards) != 1 || f.Forwards[0] != original {
					t.Fatal(f)
				}
			}
			fi, _ := os.Stat(rg.r.cfg.ForwardsFile)
			if fi.Mode().Perm() != 0644 {
				t.Fatal(fi.Mode())
			}
		})
	}
}
func TestPortAuditLayers(t *testing.T) {
	rg, _ := portRig(t)
	rg.place("forgejo", "h001", placements.Committed)
	rg.place("minecraft", "h001", placements.Committed)
	rg.pass()
	v := rg.r.Verify(context.Background())
	seen := map[string]bool{}
	for _, c := range v.Checks {
		seen[c.Layer] = true
	}
	if !seen[Stream] || !seen[WAN] {
		t.Fatalf("%+v", v)
	}
	if !strings.Contains(fmt.Sprint(v.Errors), "forwards-apply") {
		t.Fatal(v)
	}
}
