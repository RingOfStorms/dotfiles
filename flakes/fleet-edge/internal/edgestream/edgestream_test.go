package edgestream

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func testCfg(t *testing.T) *Config {
	t.Helper()
	return &Config{Dir: t.TempDir(), Hosts: map[string]string{"h001": "100.64.0.13", "h003": "100.64.0.20"},
		Ports: []int{3032}, NginxTest: "test", NginxReload: "reload"}
}

func addReq() *Request { return &Request{Op: "add", Kind: KindPlacement, Port: 3032, Host: "h001"} }

func stubRunner(t *testing.T, failTest bool) *[]string {
	t.Helper()
	var calls []string
	old := Runner
	Runner = func(c string) error {
		calls = append(calls, c)
		if c == "test" && failTest {
			return errors.New("boom")
		}
		return nil
	}
	t.Cleanup(func() { Runner = old })
	return &calls
}

func TestValidateRefuses(t *testing.T) {
	c := testCfg(t)
	cases := map[string]func(r *Request){
		"port not allowed": func(r *Request) { r.Port = 22 },
		"zero port":        func(r *Request) { r.Port = 0 },
		"unknown host":     func(r *Request) { r.Host = "nope" },
		"no kind":          func(r *Request) { r.Kind = "" },
		"other kind":       func(r *Request) { r.Kind = "expose" },
		"bad op":           func(r *Request) { r.Op = "exec" },
	}
	for name, mut := range cases {
		r := addReq()
		mut(r)
		if err := c.Validate(r); err == nil {
			t.Errorf("%s: accepted %+v", name, r)
		}
	}
	if err := c.Validate(addReq()); err != nil {
		t.Fatal(err)
	}
	if err := c.Validate(&Request{Op: "remove", Kind: KindPlacement, Port: 3032}); err != nil {
		t.Fatalf("remove needs no host: %v", err)
	}
}

func TestRenderMatchesStaticServer(t *testing.T) {
	out := testCfg(t).Render(addReq())
	if !strings.Contains(out, "server {\n  listen 3032;\n  proxy_pass 100.64.0.13:3032;\n}\n") {
		t.Fatal(out)
	}
	e, ok := ParseHeader([]byte(out))
	if !ok || e != (Entry{Port: 3032, Host: "h001", Kind: KindPlacement}) {
		t.Fatalf("header %+v %v", e, ok)
	}
}

func TestAddListRemove(t *testing.T) {
	c := testCfg(t)
	calls := stubRunner(t, false)
	var out bytes.Buffer
	if err := c.Handle(addReq(), &out); err != nil {
		t.Fatal(err)
	}
	if strings.Join(*calls, ",") != "test,reload" || c.Pending() {
		t.Fatalf("calls %v pending %v", *calls, c.Pending())
	}
	// identical add: no reload
	if err := c.Handle(addReq(), &out); err != nil || len(*calls) != 2 {
		t.Fatalf("identical add reloaded: %v %v", err, *calls)
	}
	out.Reset()
	if err := c.Handle(&Request{Op: "list"}, &out); err != nil {
		t.Fatal(err)
	}
	l, err := ParseList(out.Bytes())
	if err != nil || len(l) != 1 || l[0].Host != "h001" || l[0].Port != 3032 {
		t.Fatalf("list %s %v", out.String(), err)
	}
	// fenced remove: wrong host is kept
	out.Reset()
	if err := c.Handle(&Request{Op: "remove", Kind: KindPlacement, Port: 3032, Host: "h003"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), KeptPrefix) {
		t.Fatalf("not kept: %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "3032.stream")); err != nil {
		t.Fatal("fenced remove deleted the file")
	}
	if err := c.Handle(&Request{Op: "remove", Kind: KindPlacement, Port: 3032, Host: "h001"}, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "3032.stream")); !os.IsNotExist(err) {
		t.Fatal("remove left the file")
	}
}

func TestFailedTestRestores(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	if err := c.Handle(addReq(), nil); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(c.Dir, "3032.stream"))
	stubRunner(t, true)
	r := addReq()
	r.Host = "h003"
	if err := c.Handle(r, nil); err == nil {
		t.Fatal("expected nginx -t failure")
	}
	after, _ := os.ReadFile(filepath.Join(c.Dir, "3032.stream"))
	if !bytes.Equal(before, after) || c.Pending() {
		t.Fatalf("not restored (pending %v):\n%s", c.Pending(), after)
	}
}

func TestFailedReloadStaysPending(t *testing.T) {
	c := testCfg(t)
	old := Runner
	t.Cleanup(func() { Runner = old })
	Runner = func(cmd string) error {
		if cmd == "reload" {
			return errors.New("down")
		}
		return nil
	}
	if err := c.Handle(addReq(), nil); err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		t.Fatalf("want reload pending, got %v", err)
	}
	if !c.Pending() {
		t.Fatal("marker not set")
	}
	Runner = func(string) error { return nil }
	var out bytes.Buffer
	if err := c.Handle(&Request{Op: "list"}, &out); err != nil || c.Pending() {
		t.Fatalf("list did not flush: %v", err)
	}
}

func TestExpireDropsWhatItCannotVouchFor(t *testing.T) {
	c := testCfg(t)
	calls := stubRunner(t, false)
	if err := c.Handle(addReq(), nil); err != nil {
		t.Fatal(err)
	}
	w := func(n, s string) { _ = os.WriteFile(filepath.Join(c.Dir, n), []byte(s), 0o644) }
	w("4000.stream", render(Entry{Port: 4000, Host: "h001", Kind: KindPlacement}, "100.64.0.13")) // port not allowed
	w("junk.stream", "server { listen 1; proxy_pass 1.2.3.4:1; }\n")                              // no header
	w("3033.stream", render(Entry{Port: 3032, Host: "h001", Kind: KindPlacement}, "100.64.0.13")) // name mismatch
	w("3032.stream.new", "partial")
	*calls = nil
	gone, err := c.Expire(true)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(gone, ",") != "3033.stream,4000.stream,junk.stream" {
		t.Fatalf("gone %v", gone)
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "3032.stream")); err != nil {
		t.Fatal("valid file removed")
	}
	if _, err := os.Stat(filepath.Join(c.Dir, "3032.stream.new")); !os.IsNotExist(err) {
		t.Fatal("temp left")
	}
	if strings.Join(*calls, ",") != "test,reload" {
		t.Fatalf("calls %v", *calls)
	}
	// host dropped from the config: closed
	c.Hosts = map[string]string{"h003": "100.64.0.20"}
	if gone, _ := c.Expire(false); len(gone) != 1 || !c.Pending() {
		t.Fatalf("unknown host kept: %v", gone)
	}
}

const oldConf = `
http { server { listen 443; proxy_pass http://100.64.0.13:8443; } }
stream {
server {
  listen 3032;
  proxy_pass 100.64.0.13:3032;
}
server { listen 9999; proxy_pass 100.64.0.13:9999; }
server { listen 3032; proxy_pass 100.64.0.13:22; }
}
`

func seededMarkerExists(c *Config) bool {
	_, err := os.Stat(filepath.Join(c.Dir, SeededMarker))
	return err == nil
}

func TestSeedFirstRunSeedsAndMarks(t *testing.T) {
	c := testCfg(t)
	c.Dir = filepath.Join(c.Dir, "streams") // created by Seed
	got, err := c.Seed([]byte(oldConf))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != (Entry{Port: 3032, Host: "h001", Kind: KindPlacement}) {
		t.Fatalf("seeded %+v", got)
	}
	b, _ := os.ReadFile(filepath.Join(c.Dir, "3032.stream"))
	if string(b) != testCfg(t).Render(addReq()) {
		t.Fatalf("seed differs from a pushed file:\n%s", b)
	}
	if !c.Pending() {
		t.Fatal("seed must leave a reload owed")
	}
	if !seededMarkerExists(c) {
		t.Fatal("first seed must write the seeded marker")
	}
	// An include-only file is not a static snapshot (but the one shot is spent).
	c2 := testCfg(t)
	if got, _ := c2.Seed([]byte("stream {\ninclude /var/lib/fleet-edge-streams/*.stream;\n}\n")); got != nil {
		t.Fatalf("seeded from include-only config: %+v", got)
	}
	if !seededMarkerExists(c2) {
		t.Fatal("an empty first seed must still write the marker")
	}
	// An address that is not exactly one fleet host is not guessed.
	c3 := testCfg(t)
	c3.Hosts["dup"] = "100.64.0.13"
	if got, _ := c3.Seed([]byte(oldConf)); got != nil {
		t.Fatalf("seeded an ambiguous address: %+v", got)
	}
}

func TestSeedExistingStreamsOnlyMarks(t *testing.T) {
	c := testCfg(t)
	moved := render(Entry{Port: 3032, Host: "h003", Kind: KindPlacement}, "100.64.0.20")
	_ = os.WriteFile(filepath.Join(c.Dir, "3032.stream"), []byte(moved), 0o644)
	if got, err := c.Seed([]byte(oldConf)); err != nil || got != nil {
		t.Fatalf("seeded over existing streams: %+v %v", got, err)
	}
	if b, _ := os.ReadFile(filepath.Join(c.Dir, "3032.stream")); string(b) != moved {
		t.Fatalf("existing stream changed:\n%s", b)
	}
	if !seededMarkerExists(c) || c.Pending() {
		t.Fatal("existing streams: want marker, no reload owed")
	}
}

func TestSeedNotRepeatedAfterUnplace(t *testing.T) {
	stubRunner(t, false)
	c := testCfg(t)
	if _, err := c.Seed([]byte(oldConf)); err != nil {
		t.Fatal(err)
	}
	if err := c.Handle(&Request{Op: "remove", Kind: KindPlacement, Port: 3032, Host: "h001"}, nil); err != nil {
		t.Fatal(err)
	}
	// Next activation (and boot): the empty directory stays closed.
	for range 2 {
		if got, err := c.Seed([]byte(oldConf)); err != nil || got != nil {
			t.Fatalf("re-seeded after unplace: %+v %v", got, err)
		}
	}
	if l, _ := c.List(); len(l) != 0 {
		t.Fatalf("unplaced port reopened: %+v", l)
	}
}

func TestSeedKeepsMovedStreamAcrossReboot(t *testing.T) {
	stubRunner(t, false)
	c := testCfg(t)
	if _, err := c.Seed([]byte(oldConf)); err != nil {
		t.Fatal(err)
	}
	if err := c.Handle(&Request{Op: "add", Kind: KindPlacement, Port: 3032, Host: "h003"}, nil); err != nil {
		t.Fatal(err)
	}
	// Reboot with the persisted dir: boot seeds, then expires without reload.
	if got, err := c.Seed([]byte(oldConf)); err != nil || got != nil {
		t.Fatalf("re-seeded after move: %+v %v", got, err)
	}
	if gone, err := c.Expire(false); err != nil || len(gone) != 0 {
		t.Fatalf("expire after reboot: %v %v", gone, err)
	}
	if l, _ := c.List(); len(l) != 1 || l[0] != (Entry{Port: 3032, Host: "h003", Kind: KindPlacement}) {
		t.Fatalf("after reboot %+v, want :3032 -> h003", l)
	}
}

func TestReceiveStrict(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	p := filepath.Join(t.TempDir(), "cfg.json")
	b, _ := json.Marshal(c)
	_ = os.WriteFile(p, b, 0o644)
	var out bytes.Buffer
	if err := Receive(p, strings.NewReader(`{"op":"add","kind":"placement","port":3032,"host":"h001","fqdn":"x"}`), &out); err == nil {
		t.Fatal("unknown field accepted")
	}
	if err := Receive(p, strings.NewReader(`{"op":"add","kind":"placement","port":3032,"host":"h001"}`), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "ok add 3032\n" {
		t.Fatalf("%q", out.String())
	}
}

func TestParseListRejectsVhostReply(t *testing.T) {
	// What an edge still running only fleet-vhost-receive answers to {"op":"list"}.
	if _, err := ParseList([]byte(`[{"fqdn":"git.example.com","host":"h001","until":0,"kind":"placement"}]` + "\n")); err == nil {
		t.Fatal("vhost list accepted as a stream list")
	}
	if _, err := ParseList([]byte("[]\n")); err == nil {
		t.Fatal("empty array accepted")
	}
	if l, err := ParseList([]byte(`{"streams":[]}`)); err != nil || len(l) != 0 {
		t.Fatalf("%v %v", l, err)
	}
}

func TestLockIsExclusive(t *testing.T) {
	c := testCfg(t)
	unlock, err := c.lock()
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	f, err := os.OpenFile(filepath.Join(c.Dir, LockFile), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("lock was not exclusive: %v", err)
	}
}

func TestRemoveFencesKind(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	_ = os.WriteFile(c.path(3032), []byte(render(Entry{Port: 3032, Host: "h001", Kind: "other"}, c.Hosts["h001"])), 0644)
	var out bytes.Buffer
	if err := c.Handle(&Request{Op: "remove", Port: 3032, Host: "h001", Kind: KindPlacement}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), KeptPrefix) {
		t.Fatal(out.String())
	}
}

func TestInvalidAddress(t *testing.T) {
	c := testCfg(t)
	c.Hosts["h001"] = "999.1.1.1"
	if c.Validate(addReq()) == nil {
		t.Fatal("invalid IP accepted")
	}
}
