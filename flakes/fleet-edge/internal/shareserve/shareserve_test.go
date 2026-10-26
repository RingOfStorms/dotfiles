package shareserve

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// sampleProcNetTCP mimics /proc/net/tcp: a 127.0.0.1 listener at port 40231
// (hex 9D27) owned by uid 993 (the `share` user in these tests), a
// loopback listener at 8080 (hex 1F90, like headscale) owned by uid 994
// (a different system service), a non-loopback row, and a non-LISTEN row --
// all of which must be ignored.
const sampleProcNetTCP = `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:9D27 00000000:0000 0A 00000000:00000000 00:00000000 00000000   993        0 1001 2 0000000000000000 100 0 0 10 0
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1002 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000   994        0 1003 2 0000000000000000 100 0 0 10 0
   3: 0100007F:9A02 0100007F:9D27 06 00000000:00000000 03:00000F8E 00000000     0        0 1004 2 0000000000000000 100 0 0 10 0
`

const shareUID = 993

func withProcNetTCP(t *testing.T, data string) {
	t.Helper()
	old := procNetTCP
	t.Cleanup(func() { procNetTCP = old })
	procNetTCP = func() ([]byte, error) { return []byte(data), nil }
}

func withUID(t *testing.T, uid int) {
	t.Helper()
	old := Getuid
	t.Cleanup(func() { Getuid = old })
	Getuid = func() int { return uid }
}

// withLookupUID stubs LookupUID so applyOne's (root's) independent
// VerifyPortForUser check resolves "share" to uid without a real system
// user in the test environment.
func withLookupUID(t *testing.T, uid int) {
	t.Helper()
	old := LookupUID
	t.Cleanup(func() { LookupUID = old })
	LookupUID = func(string) (int, error) { return uid, nil }
}

// withFstatOwner stubs fstatOwner so tests can simulate a request file
// "owned" by an arbitrary uid without needing root to chown a real file.
func withFstatOwner(t *testing.T, uid uint32) {
	t.Helper()
	old := fstatOwner
	t.Cleanup(func() { fstatOwner = old })
	fstatOwner = func(os.FileInfo) (uint32, bool) { return uid, true }
}

func testCfg(t *testing.T) *Config {
	t.Helper()
	dir := t.TempDir()
	requestsDir := filepath.Join(dir, "requests")
	confDir := filepath.Join(dir, "conf")
	statusDir := filepath.Join(dir, "status")
	for _, d := range []string{requestsDir, confDir, statusDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	withLookupUID(t, shareUID)
	withFstatOwner(t, shareUID)
	return &Config{
		Domain: "share.example.com", RequestsDir: requestsDir, ConfDir: confDir, StatusDir: statusDir,
		CertDir:   "/var/lib/fleet-cert/share.example.com/current",
		ShareUser: "share",
		NginxTest: "test", NginxReload: "reload", LimitZone: "fleet_share_rt", MaxFor: 8 * 3600,
	}
}

// runApplyUntilIdle drains any pending .new/.remove requests, used by tests
// to stand in for the systemd .path-triggered root apply step.
func runApplyUntilIdle(t *testing.T, c *Config) {
	t.Helper()
	if _, err := c.Apply(); err != nil {
		t.Fatalf("apply: %v", err)
	}
}

// applyInBackground polls Config.RequestsDir for new/remove requests and
// applies them, like the real .path unit would, until stop is closed.
func applyInBackground(t *testing.T, c *Config) (stop func()) {
	t.Helper()
	done := make(chan struct{})
	quit := make(chan struct{})
	var once sync.Once
	go func() {
		defer close(done)
		for {
			select {
			case <-quit:
				_, _ = c.Apply()
				return
			case <-time.After(5 * time.Millisecond):
				_, _ = c.Apply()
			}
		}
	}()
	return func() {
		once.Do(func() {
			close(quit)
			<-done
		})
	}
}

func TestParseCommand(t *testing.T) {
	r, err := ParseCommand("dev1 40231 3600")
	if err != nil || r.Name != "dev1" || r.Port != 40231 || r.For != time.Hour {
		t.Fatalf("got %+v %v", r, err)
	}
	if _, err := ParseCommand("dev1"); err == nil {
		t.Fatal("want error: missing port")
	}
	if _, err := ParseCommand("dev1 0"); err == nil {
		t.Fatal("want error: port 0")
	}
	if _, err := ParseCommand("dev1 70000"); err == nil {
		t.Fatal("want error: port too big")
	}
	if _, err := ParseCommand("dev1 100 bad"); err == nil {
		t.Fatal("want error: bad for")
	}
}

func TestValidateRefusesBadNames(t *testing.T) {
	c := testCfg(t)
	bad := []Request{
		{Name: "", Port: 1},
		{Name: "-dev", Port: 1},
		{Name: "dev..1", Port: 1},
		{Name: strings.Repeat("a", 64), Port: 1},
	}
	for _, r := range bad {
		if err := c.Validate(r); err == nil {
			t.Errorf("want error for %+v", r)
		}
	}
	if err := c.Validate(Request{Name: "dev-1", Port: 3000}); err != nil {
		t.Errorf("want ok: %v", err)
	}
}

func TestLoopbackListeners(t *testing.T) {
	got := loopbackListeners([]byte(sampleProcNetTCP))
	want := map[int]int{40231: 993, 8080: 994}
	if len(got) != len(want) {
		t.Fatalf("got %+v want %+v", got, want)
	}
	for _, l := range got {
		if want[l.port] != l.uid {
			t.Errorf("port %d: got uid %d want %d", l.port, l.uid, want[l.port])
		}
	}
}

func TestVerifyPortOwnership(t *testing.T) {
	withProcNetTCP(t, sampleProcNetTCP)
	withUID(t, shareUID)

	if err := VerifyPort(40231); err != nil {
		t.Fatalf("want ok: %v", err)
	}
	// Port 8080 is a real 127.0.0.1 listener, but owned by a different
	// uid (e.g. headscale) -- must be refused even though it's live.
	if err := VerifyPort(8080); err == nil {
		t.Fatal("want refusal: port owned by a different uid")
	}
	if err := VerifyPort(9999); err == nil {
		t.Fatal("want refusal: port not listening at all")
	}
}

func TestRenderHasUpstreamAndWebsocketsAndNoindex(t *testing.T) {
	c := testCfg(t)
	out := Render(c, Request{Name: "dev1", Port: 3000})
	for _, w := range []string{
		"proxy_pass http://127.0.0.1:3000;",
		"proxy_set_header Upgrade $http_upgrade;",
		"proxy_set_header Connection $connection_upgrade;",
		"add_header X-Robots-Tag noindex;",
		"proxy_http_version 1.1;",
		"limit_req zone=fleet_share_rt burst=100 nodelay;",
		"server_name dev1.share.example.com;",
		"_oauth2_proxy",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("missing %q in\n%s", w, out)
		}
	}
}

func TestServeLifecycleEndsOnStdinEOF(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)
	withUID(t, shareUID)
	stop := applyInBackground(t, c)
	defer stop()

	hup := make(chan struct{})
	var out bytes.Buffer
	err := Serve(c, "dev1 40231 3600", strings.NewReader(""), hup, &out)
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	if !strings.Contains(out.String(), "https://dev1.share.example.com") {
		t.Fatalf("missing URL in output: %q", out.String())
	}
	stop()
	// Cleanup: the conf must be gone after Serve returns and apply catches
	// up with the .remove marker.
	entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf"))
	if len(entries) != 0 {
		t.Fatalf("vhost not removed: %v", entries)
	}
}

func TestServeRefusesUnownedPort(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)
	withUID(t, shareUID)

	hup := make(chan struct{})
	var out bytes.Buffer
	err := Serve(c, "dev1 9999 3600", strings.NewReader(""), hup, &out)
	if err == nil {
		t.Fatal("want refusal: port not owned by this session")
	}
}

func TestServeRefusesOtherUidPort(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)
	withUID(t, shareUID)

	hup := make(chan struct{})
	var out bytes.Buffer
	// Port 8080 is a live 127.0.0.1 listener, but owned by uid 994, not
	// the share user -- must never be exposed just because it's claimed.
	err := Serve(c, "evil 8080 3600", strings.NewReader(""), hup, &out)
	if err == nil {
		t.Fatal("want refusal: port owned by a different uid")
	}
}

func TestServeRefusesDuplicatePort(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)
	withUID(t, shareUID)

	// Simulate an already-live share on the same port under a different
	// name, applied as root would.
	if err := writeFileAtomic(c.ConfDir, "other.conf", []byte(Render(c, Request{Name: "other", Port: 40231})), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	stop := applyInBackground(t, c)
	defer stop()
	hup := make(chan struct{})
	var out bytes.Buffer
	err := Serve(c, "dev1 40231 3600", strings.NewReader(""), hup, &out)
	if err == nil {
		t.Fatal("want refusal: port already shared under another name")
	}
}

func TestApplyRevalidatesAndIgnoresUntrustedRequestText(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)

	// A crafted request: filename says "dev1" but the embedded name tries
	// to target a different file / an invalid name. Apply must refuse it
	// rather than trust the JSON's own "name" field.
	bad := []byte(`{"name":"../escape","port":40231}`)
	if err := writeFileAtomic(c.RequestsDir, "dev1.new", bad, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatalf("expected refusal for mismatched/crafted name, got ok")
	}
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("no conf should have been written: %v", entries)
	}
}

func TestApplyRendersFromItsOwnValidationNotRequestPort(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)

	// Out-of-range port in the request must be refused even though the
	// filename/name are fine.
	bad := []byte(`{"name":"dev1","port":99999}`)
	if err := writeFileAtomic(c.RequestsDir, "dev1.new", bad, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal for out-of-range port")
	}
}

func TestApplyRefusesPortOwnedByAnotherUID(t *testing.T) {
	c := testCfg(t)
	Runner = func(string) error { return nil }
	withProcNetTCP(t, sampleProcNetTCP)

	// Port 8080 is live, but owned by uid 994, not the share user: Apply
	// must never trust a request's claim, even one that already made it
	// past Serve's own filename/name validation.
	req := []byte(`{"name":"evil","port":8080}`)
	if err := writeFileAtomic(c.RequestsDir, "evil.new", req, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("evil"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal: port not owned by the share user")
	}
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("no conf should have been written: %v", entries)
	}
}

func TestApplyNginxTestFailureRollsBack(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(cmd string) error {
		if cmd == c.NginxTest {
			return errors.New("syntax error")
		}
		return nil
	}

	req := []byte(`{"name":"dev1","port":40231}`)
	if err := writeFileAtomic(c.RequestsDir, "dev1.new", req, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal: nginx -t failed")
	}
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("conf should have been rolled back: %v", entries)
	}
}

func TestApplyRemoveDeletesConfAndReloads(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	reloaded := false
	Runner = func(cmd string) error {
		if cmd == c.NginxReload {
			reloaded = true
		}
		return nil
	}
	if err := writeFileAtomic(c.ConfDir, "dev1.conf", []byte(Render(c, Request{Name: "dev1", Port: 40231})), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(c.RequestsDir, "dev1.remove", []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("conf should be removed: %v", entries)
	}
	if !reloaded {
		t.Fatal("want nginx reloaded after remove")
	}
	if _, err := os.Stat(filepath.Join(c.RequestsDir, "dev1.remove")); !os.IsNotExist(err) {
		t.Fatalf("remove marker should be consumed: %v", err)
	}
}

func TestSweepRemovesStaleRequestsAndStatuses(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(string) error { return nil }
	old := staleRequestAge
	staleRequestAge = 0
	t.Cleanup(func() { staleRequestAge = old })

	if err := writeFileAtomic(c.RequestsDir, "x.new", []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(c.RequestsDir, "y.remove", []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(c.StatusDir, "z.status", []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Sweep(); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	for _, p := range []string{
		filepath.Join(c.RequestsDir, "x.new"),
		filepath.Join(c.RequestsDir, "y.remove"),
		filepath.Join(c.StatusDir, "z.status"),
	} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("want %s swept away: %v", p, err)
		}
	}
}

// --- new: symlink / wrong-uid / oversized request attacks ---

func TestApplyRefusesSymlinkRequest(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(string) error { return nil }

	target := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(target, []byte(`{"name":"dev1","port":40231}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(c.RequestsDir, "dev1.new")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal: symlink request must be ignored")
	}
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("no conf should have been written: %v", entries)
	}
}

func TestApplyRefusesRequestOwnedByWrongUID(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(string) error { return nil }
	// Simulate a request file actually owned by some other uid (e.g. one
	// `share` doesn't control), even though it landed in RequestsDir.
	withFstatOwner(t, shareUID+1)

	if err := writeFileAtomic(c.RequestsDir, "dev1.new", []byte(`{"name":"dev1","port":40231}`), 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal: request not owned by the share uid")
	}
	if entries, _ := filepath.Glob(filepath.Join(c.ConfDir, "*.conf")); len(entries) != 0 {
		t.Fatalf("no conf should have been written: %v", entries)
	}
}

func TestApplyRefusesOversizedRequest(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(string) error { return nil }

	huge := make([]byte, maxRequestSize+1)
	for i := range huge {
		huge[i] = 'a'
	}
	if err := writeFileAtomic(c.RequestsDir, "dev1.new", huge, 0o600); err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	status, err := os.ReadFile(c.statusPath("dev1"))
	if err != nil {
		t.Fatalf("expected a status file: %v", err)
	}
	if strings.TrimSpace(string(status)) == "ok" {
		t.Fatal("expected refusal: oversized request")
	}
}

// TestNoRootWritePathEverInsideRequestsDir asserts every place root
// (Apply/Sweep) writes lives outside RequestsDir: writeFileAtomic is
// always called with c.ConfDir or c.StatusDir as the destination
// directory when invoked from root code, never c.RequestsDir. This is a
// static assertion over the call sites that matter at runtime: after a
// full Apply+Sweep cycle, RequestsDir must contain nothing but what
// `share` itself wrote (which Apply/Sweep only ever delete, never create).
func TestNoRootWritePathEverInsideRequestsDir(t *testing.T) {
	c := testCfg(t)
	withProcNetTCP(t, sampleProcNetTCP)
	Runner = func(string) error { return nil }

	if err := writeFileAtomic(c.RequestsDir, "dev1.new", []byte(`{"name":"dev1","port":40231}`), 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadDir(c.RequestsDir)
	if err != nil {
		t.Fatal(err)
	}
	runApplyUntilIdle(t, c)
	if _, err := c.Sweep(); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadDir(c.RequestsDir)
	if err != nil {
		t.Fatal(err)
	}
	// Apply must have consumed dev1.new (deleted, not replaced with
	// something new); Sweep must not have created anything either.
	if len(after) != 0 {
		t.Fatalf("RequestsDir should be empty after apply+sweep, got %v (started with %v)", after, before)
	}
}

// TestApplyRefusesFIFOPromptly asserts a FIFO dropped in place of a
// request is refused quickly instead of blocking the root watcher: a
// bare blocking open(O_RDONLY) on a FIFO with no writer would hang
// forever, so openRequestFile must use O_NONBLOCK.
func TestApplyRefusesFIFOPromptly(t *testing.T) {
	c := testCfg(t)
	fifoPath := filepath.Join(c.RequestsDir, "x.new")
	if err := syscall.Mkfifo(fifoPath, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := openRequestFile(c.RequestsDir, "x.new", shareUID)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected an error opening a FIFO, got nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("openRequestFile blocked on a FIFO instead of refusing it promptly")
	}
}

// TestReadRequestFileRejectsGrowthAfterStat covers a request file that
// grows past maxRequestSize after openRequestFile's fstat check already
// passed it: readRequestFile must still cap the read and reject it,
// rather than trusting the earlier size check.
func TestReadRequestFileRejectsGrowthAfterStat(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "grown.new")
	if err := os.WriteFile(path, bytes.Repeat([]byte("a"), maxRequestSize+100), 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := readRequestFile(f); err == nil {
		t.Fatal("expected readRequestFile to reject a file larger than maxRequestSize")
	}
}
