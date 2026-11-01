package edgestream

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// freePort returns a tcp port nothing listens on right now.
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func dialable(port int) bool {
	conn, err := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(port), time.Second)
	if err == nil {
		conn.Close()
	}
	return err == nil
}

// A real nginx: nginx -t passes and the reload (HUP) is delivered, but the
// master cannot bind the new stream's port (a Go listener holds it), logs
// [emerg] and keeps its old config. The marker must stay until a later flush
// whose reload nginx really loads.
func TestRealNginxBindConflictKeepsMarker(t *testing.T) {
	bin, err := exec.LookPath("nginx")
	if err != nil {
		t.Skip("nginx not on PATH")
	}
	d := t.TempDir()
	streams := filepath.Join(d, "streams")
	if err := os.Mkdir(streams, 0o755); err != nil {
		t.Fatal(err)
	}
	conf, pidFile, errLog := filepath.Join(d, "nginx.conf"), filepath.Join(d, "nginx.pid"), filepath.Join(d, "error.log")
	if err := os.WriteFile(conf, []byte(fmt.Sprintf(
		"daemon on;\npid %s;\nerror_log %s info;\nworker_processes 2;\nevents {}\nstream { include %s/*.stream; }\n",
		pidFile, errLog, streams)), 0o644); err != nil {
		t.Fatal(err)
	}
	nginx := fmt.Sprintf("%q -p %q -c %q -e %q", bin, d, conf, errLog)
	okPort, busyPort := freePort(t), freePort(t)
	// Upstream is TEST-NET (never answers): a dial only proves nginx listens,
	// and a loopback upstream on the same port would proxy to itself.
	c := &Config{Dir: streams, Hosts: map[string]string{"h001": "192.0.2.1"}, Ports: []int{okPort, busyPort},
		NginxTest: nginx + " -t -q", NginxReload: nginx + " -s reload", NginxMainPID: "cat " + pidFile}

	oldProbe, oldTimeout := Probe, ConfirmTimeout
	t.Cleanup(func() { Probe, ConfirmTimeout = oldProbe, oldTimeout })
	Probe, ConfirmTimeout = realProbe, 5*time.Second

	if err := Runner(nginx); err != nil {
		t.Fatalf("starting nginx: %v", err)
	}
	t.Cleanup(func() {
		if b, err := os.ReadFile(pidFile); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				_ = syscall.Kill(pid, syscall.SIGTERM)
			}
		}
	})
	time.Sleep(300 * time.Millisecond) // let the first workers start

	add := func(port int) error {
		return c.Handle(&Request{Op: "add", Kind: KindPlacement, Port: port, Host: "h001"}, nil)
	}
	if err := add(okPort); err != nil || c.Pending() {
		t.Fatalf("add on a free port: %v pending %v", err, c.Pending())
	}
	if !dialable(okPort) {
		t.Fatalf("confirmed reload but :%d is not served", okPort)
	}

	ln, err := net.Listen("tcp4", "0.0.0.0:"+strconv.Itoa(busyPort))
	if err != nil {
		t.Fatal(err)
	}
	err = add(busyPort)
	if err == nil || !strings.Contains(err.Error(), ErrReloadPending) {
		ln.Close()
		t.Fatalf("add on a taken port: want reload pending, got %v", err)
	}
	if !c.Pending() {
		ln.Close()
		t.Fatal("reload nginx never loaded cleared the marker")
	}
	if b, _ := os.ReadFile(errLog); !strings.Contains(string(b), "Address already in use") {
		ln.Close()
		t.Fatalf("expected nginx to log the bind failure:\n%s", b)
	}

	ln.Close()
	if _, err := c.Expire(true); err != nil || c.Pending() {
		t.Fatalf("flush after the port freed: %v pending %v", err, c.Pending())
	}
	if !dialable(busyPort) || !dialable(okPort) {
		t.Fatalf("after the retried reload :%d and :%d must be served", busyPort, okPort)
	}
}
