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
	"time"
)

// realProbe is the production Probe; TestMain stubs Probe to confirm every
// reload at once, so tests only exercise it where they ask to.
var realProbe = Probe

func TestMain(m *testing.M) {
	Probe = func(*Config) (func() (bool, error), error) { return func() (bool, error) { return true, nil }, nil }
	os.Exit(m.Run())
}

func testCfg(t *testing.T) *Config {
	t.Helper()
	return &Config{Dir: t.TempDir(), Hosts: map[string]string{"h001": "100.64.0.13", "h003": "100.64.0.20"},
		Ports: []int{3032}, NginxTest: "test", NginxReload: "reload", NginxMainPID: "pid"}
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

func TestEmptyDirectoryStaysClosedUntilReconcile(t *testing.T) {
	calls := stubRunner(t, false)
	c := testCfg(t)
	if gone, err := c.Expire(false); err != nil || len(gone) != 0 {
		t.Fatalf("empty boot expiry: %v %v", gone, err)
	}
	if entries, err := c.List(); err != nil || len(entries) != 0 {
		t.Fatalf("empty directory opened streams: %v %v", entries, err)
	}
	if len(*calls) != 0 {
		t.Fatalf("boot ran nginx: %v", *calls)
	}
	if err := c.Handle(addReq(), nil); err != nil {
		t.Fatal(err)
	}
	if entries, err := c.List(); err != nil || len(entries) != 1 || entries[0].Host != "h001" {
		t.Fatalf("reconcile did not open stream: %v %v", entries, err)
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

// lockFree reports whether the dir lock can be taken now, which is what
// fleet-stream-expire-boot (Before=nginx) needs while a reload is queued.
func lockFree(t *testing.T, c *Config) bool {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(c.Dir, LockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil
}

// A reload that systemd queued and then failed must leave the marker, and a
// later flush (the expire timer) must retry it. The reload runs without the
// dir lock, so it may wait for the boot expire unit.
func TestQueuedReloadFailureStaysPendingAndRetried(t *testing.T) {
	c := testCfg(t)
	stubRunner(t, false)
	if err := c.Handle(addReq(), nil); err != nil {
		t.Fatal(err)
	}
	var calls []string
	reloadOK := false
	Runner = func(cmd string) error {
		calls = append(calls, cmd)
		if cmd != "reload" {
			return nil
		}
		if !lockFree(t, c) {
			t.Error("reload ran under the dir lock")
		}
		if !reloadOK {
			return errors.New("Job for nginx.service failed")
		}
		return nil
	}
	rm := &Request{Op: "remove", Kind: KindPlacement, Port: 3032, Host: "h001"}
	if err := c.Handle(rm, nil); err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		t.Fatalf("remove with failing reload: %v", err)
	}
	if !c.Pending() {
		t.Fatal("failed reload cleared the marker")
	}
	if _, err := c.Expire(true); err == nil || !c.Pending() {
		t.Fatalf("expire with failing reload: %v pending %v", err, c.Pending())
	}
	reloadOK = true
	n := len(calls)
	if gone, err := c.Expire(true); err != nil || len(gone) != 0 || c.Pending() {
		t.Fatalf("retry: gone %v err %v pending %v", gone, err, c.Pending())
	}
	if strings.Join(calls[n:], ",") != "test,reload" {
		t.Fatalf("retry calls %v", calls[n:])
	}
}

// A change made while an unlocked reload runs re-arms the marker; the older
// reload's success must not clear that newer debt.
func TestChangeDuringReloadKeepsNewerMarker(t *testing.T) {
	c := testCfg(t)
	old := Runner
	t.Cleanup(func() { Runner = old })
	reloads := 0
	Runner = func(cmd string) error {
		if cmd != "reload" {
			return nil
		}
		reloads++
		switch reloads {
		case 1: // the add's reload: h005 removes the port meanwhile
			if !lockFree(t, c) {
				t.Fatal("reload ran under the dir lock")
			}
			rm := &Request{Op: "remove", Kind: KindPlacement, Port: 3032}
			if err := c.Handle(rm, nil); err == nil {
				t.Error("nested remove: want reload pending")
			}
		case 2: // the remove's own reload fails
			return errors.New("down")
		}
		return nil
	}
	if err := c.Handle(addReq(), nil); err != nil {
		t.Fatalf("add: %v", err)
	}
	if _, err := os.Stat(c.path(3032)); !os.IsNotExist(err) {
		t.Fatalf("remove not applied: %v", err)
	}
	if !c.Pending() {
		t.Fatal("older reload cleared the newer marker")
	}
	if err := c.Handle(&Request{Op: "list"}, &bytes.Buffer{}); err != nil || c.Pending() || reloads != 3 {
		t.Fatalf("list flush: %v pending %v reloads %d", err, c.Pending(), reloads)
	}
}

func TestLoadConfigRefusesNoBlockReload(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.json")
	if err := os.WriteFile(p, []byte(`{"dir":"/x","nginxTest":"t","nginxReload":"systemctl reload --no-block nginx","nginxMainPid":"p"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(p); err == nil || !strings.Contains(err.Error(), "--no-block") {
		t.Fatalf("want --no-block refused, got %v", err)
	}
}

func TestLoadConfigRequiresMainPID(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.json")
	if err := os.WriteFile(p, []byte(`{"dir":"/x","nginxTest":"t","nginxReload":"r"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(p); err == nil || !strings.Contains(err.Error(), "nginxMainPid") {
		t.Fatalf("want nginxMainPid required, got %v", err)
	}
}

// `systemctl reload nginx` exits 0 once nginx -t passed and SIGHUP was sent;
// the master may still keep its old config (e.g. the new port is taken).
// Until Probe confirms, the marker stays and a later flush reloads again.
func TestUnconfirmedReloadStaysPendingAndRetried(t *testing.T) {
	c := testCfg(t)
	calls := stubRunner(t, false)
	oldProbe, oldTimeout := Probe, ConfirmTimeout
	t.Cleanup(func() { Probe, ConfirmTimeout = oldProbe, oldTimeout })
	ConfirmTimeout = 20 * time.Millisecond
	loaded := false // whether the master's next HUP loads the config
	reloads, probes := 0, 0
	Probe = func(*Config) (func() (bool, error), error) {
		probes++
		if probes != reloads+1 {
			t.Errorf("probe %d not taken before reload %d", probes, reloads+1)
		}
		return func() (bool, error) { return loaded && reloads == probes, nil }, nil
	}
	Runner = func(cmd string) error {
		*calls = append(*calls, cmd)
		if cmd == "reload" {
			reloads++
		}
		return nil // the reload job "succeeds" either way
	}
	if err := c.Handle(addReq(), nil); err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		t.Fatalf("unconfirmed reload: want reload pending, got %v", err)
	}
	if !c.Pending() {
		t.Fatal("unconfirmed reload cleared the marker")
	}
	if _, err := c.Expire(true); err == nil || !c.Pending() || reloads != 2 {
		t.Fatalf("expire, still unconfirmed: %v pending %v reloads %d", err, c.Pending(), reloads)
	}
	loaded = true
	if err := c.Handle(&Request{Op: "list"}, &bytes.Buffer{}); err != nil || c.Pending() || reloads != 3 {
		t.Fatalf("list flush: %v pending %v reloads %d", err, c.Pending(), reloads)
	}
	probeErr := errors.New("no master")
	Probe = func(*Config) (func() (bool, error), error) { return nil, probeErr }
	if err := c.Handle(&Request{Op: "remove", Kind: KindPlacement, Port: 3032}, nil); err == nil || !strings.Contains(err.Error(), "no master") || !c.Pending() {
		t.Fatalf("probe error: %v pending %v", err, c.Pending())
	}
}
