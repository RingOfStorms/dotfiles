package wanforward

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
)

func sp(s string) *string { return &s }

func testInv() *inventory.Inventory {
	return &inventory.Inventory{
		Services: map[string]inventory.Service{
			"minecraft": {Name: "minecraft", Routes: map[string]inventory.Route{
				"game": {Port: 25565, Proto: "tcp", Exposure: "public", Via: []string{"router"}},
				"map":  {Port: 8080, Proto: "http", Exposure: "public", Via: []string{"edge"}},
			}},
			"forgejo": {Name: "forgejo", Routes: map[string]inventory.Route{
				"ssh": {Port: 3032, Proto: "tcp", Exposure: "public", Via: []string{"edge"}},
			}},
		},
		Hosts: map[string]inventory.Host{
			"h003": {LanIP: sp("10.12.14.30")},
			"lio":  {},
		},
	}
}

func mc(host string) Forward {
	return Forward{Proto: "tcp", Port: 25565, Host: host, Source: "minecraft.game"}
}

func TestRoutesOnlyRouter(t *testing.T) {
	r := Routes(testInv())
	if len(r) != 1 || r["tcp/25565"] != "minecraft.game" {
		t.Fatalf("%v", r)
	}
}

func TestResolveRefuses(t *testing.T) {
	inv := testInv()
	cases := map[string]File{
		"edge route":   {Forwards: []Forward{{Proto: "tcp", Port: 3032, Host: "h003", Source: "forgejo.ssh"}}},
		"wrong source": {Forwards: []Forward{{Proto: "tcp", Port: 25565, Host: "h003", Source: "forgejo.ssh"}}},
		"wrong proto":  {Forwards: []Forward{{Proto: "udp", Port: 25565, Host: "h003", Source: "minecraft.game"}}},
		"no lan ip":    {Forwards: []Forward{mc("lio")}},
		"unknown host": {Forwards: []Forward{mc("nope")}},
		"twice":        {Forwards: []Forward{mc("h003"), mc("h003")}},
	}
	for name, f := range cases {
		if _, err := Resolve(inv, f); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	got, err := Resolve(inv, File{Forwards: []Forward{mc("h003")}})
	if err != nil || len(got) != 1 || got[0].IP != "10.12.14.30" {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestRender(t *testing.T) {
	out := Render("wan0", []Applied{{Forward: mc("h003"), IP: "10.12.14.30"}})
	for _, w := range []string{
		"table ip fleet-wan-forwards {}\ndelete table ip fleet-wan-forwards\n",
		"type nat hook prerouting priority dstnat; policy accept;",
		`iifname "wan0" tcp dport 25565 dnat to 10.12.14.30:25565 comment "minecraft.game"`,
	} {
		if !strings.Contains(out, w) {
			t.Errorf("missing %q in\n%s", w, out)
		}
	}
	if strings.Contains(Render("wan0", nil), "dnat") {
		t.Fatal("empty set renders a rule")
	}
}

type rig struct {
	cfg     ApplyConfig
	scripts []string
	logs    []string
	nftErr  error
}

func newRig(t *testing.T) *rig {
	t.Helper()
	d := t.TempDir()
	rg := &rig{}
	rg.cfg = ApplyConfig{Inventory: testInv(), File: filepath.Join(d, "in", "forwards.json"),
		Status: filepath.Join(d, "run", "applied.json"), WAN: "wan0", LAN: "lan0",
		Logf: func(f string, a ...any) { rg.logs = append(rg.logs, fmt.Sprintf(f, a...)) }}
	_ = os.MkdirAll(filepath.Dir(rg.cfg.File), 0o755)
	old := Runner
	Runner = func(s string) error {
		if rg.nftErr != nil {
			return rg.nftErr
		}
		rg.scripts = append(rg.scripts, s)
		return nil
	}
	t.Cleanup(func() { Runner = old })
	return rg
}

func TestApplyMissingFileIsClosed(t *testing.T) {
	rg := newRig(t)
	if err := Apply(rg.cfg); err != nil {
		t.Fatal(err)
	}
	if len(rg.scripts) != 1 || strings.Contains(rg.scripts[0], "dnat") {
		t.Fatalf("%v", rg.scripts)
	}
	if len(rg.logs) != 1 || !strings.Contains(rg.logs[0], "no forwards") {
		t.Fatalf("logs %v", rg.logs)
	}
	st, err := ReadStatus(rg.cfg.Status)
	if err != nil || len(st.Forwards) != 0 || st.Error != "" {
		t.Fatalf("%+v %v", st, err)
	}
}

func TestApplyLogsAndRecords(t *testing.T) {
	rg := newRig(t)
	_ = WriteAtomic(rg.cfg.File, Marshal(File{Forwards: []Forward{mc("h003")}}))
	if err := Apply(rg.cfg); err != nil {
		t.Fatal(err)
	}
	if len(rg.logs) != 1 || !strings.Contains(rg.logs[0], "tcp/25565 on wan0 -> h003 10.12.14.30:25565 (minecraft.game)") {
		t.Fatalf("logs %v", rg.logs)
	}
	st, _ := ReadStatus(rg.cfg.Status)
	if len(st.Forwards) != 1 || st.Forwards[0].IP != "10.12.14.30" {
		t.Fatalf("%+v", st)
	}
}

func TestApplyInvalidKeepsTable(t *testing.T) {
	rg := newRig(t)
	_ = WriteAtomic(rg.cfg.File, Marshal(File{Forwards: []Forward{mc("h003")}}))
	if err := Apply(rg.cfg); err != nil {
		t.Fatal(err)
	}
	// A forged entry: no nft run, status keeps the applied set and names the error.
	_ = WriteAtomic(rg.cfg.File, []byte(`{"forwards":[{"proto":"tcp","port":22,"host":"h003","source":"x.y"}]}`))
	if err := Apply(rg.cfg); err == nil {
		t.Fatal("forged forward applied")
	}
	if len(rg.scripts) != 1 {
		t.Fatalf("nft ran on an invalid file: %d", len(rg.scripts))
	}
	st, _ := ReadStatus(rg.cfg.Status)
	if st.Error == "" || len(st.Forwards) != 1 {
		t.Fatalf("%+v", st)
	}
	// Unknown fields and nft failure also leave it.
	_ = WriteAtomic(rg.cfg.File, []byte(`{"forwards":[],"x":1}`))
	if err := Apply(rg.cfg); err == nil {
		t.Fatal("unknown field accepted")
	}
	_ = WriteAtomic(rg.cfg.File, Marshal(File{}))
	rg.nftErr = errors.New("busy")
	if err := Apply(rg.cfg); err == nil {
		t.Fatal("nft failure not reported")
	}
	if st, _ := ReadStatus(rg.cfg.Status); len(st.Forwards) != 1 || !strings.Contains(st.Error, "busy") {
		t.Fatalf("%+v", st)
	}
}

func TestMarshalStable(t *testing.T) {
	a := Marshal(File{Forwards: []Forward{mc("h003"), {Proto: "tcp", Port: 1, Host: "h003", Source: "a.b"}}})
	b := Marshal(File{Forwards: []Forward{{Proto: "tcp", Port: 1, Host: "h003", Source: "a.b"}, mc("h003")}})
	if string(a) != string(b) {
		t.Fatalf("%s\n%s", a, b)
	}
	if string(Marshal(File{})) != "{\n  \"forwards\": []\n}\n" {
		t.Fatalf("%q", Marshal(File{}))
	}
}
