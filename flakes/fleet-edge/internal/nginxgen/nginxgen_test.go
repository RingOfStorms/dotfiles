package nginxgen

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeProc writes /proc/<pid>/{stat,cmdline} under root.
func fakeProc(t *testing.T, root string, pid, ppid int, start, title string) {
	t.Helper()
	dir := filepath.Join(root, fmt.Sprint(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Fields 3.. after comm; field 22 (starttime) is the 20th of them.
	rest := []string{"S", fmt.Sprint(ppid)}
	for len(rest) < 19 {
		rest = append(rest, "0")
	}
	rest = append(rest, start, "0", "0")
	stat := fmt.Sprintf("%d (nginx (x)) %s\n", pid, strings.Join(rest, " "))
	cmd := title + strings.Repeat("\x00", 16)
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(stat), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cmdline"), []byte(cmd), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAppliedFollowsWorkerGenerations(t *testing.T) {
	root := t.TempDir()
	fakeProc(t, root, 100, 1, "5", "nginx: master process nginx -c x")
	fakeProc(t, root, 101, 100, "6", workerTitle)
	fakeProc(t, root, 102, 100, "6", workerTitle)
	fakeProc(t, root, 103, 100, "6", "nginx: cache manager process")
	fakeProc(t, root, 200, 1, "6", workerTitle) // another nginx's worker
	w, err := watch(root, "echo 100")
	if err != nil {
		t.Fatal(err)
	}
	check := func(want bool) {
		t.Helper()
		if got, err := w.Applied(); err != nil || got != want {
			t.Fatalf("Applied = %v, %v; want %v", got, err, want)
		}
	}
	check(false) // nothing changed: a failed HUP looks like this

	fakeProc(t, root, 104, 100, "9", workerTitle) // new cycle started
	check(false)                                  // old workers not yet told to drain

	fakeProc(t, root, 101, 100, "6", workerTitle+" is shutting down")
	os.RemoveAll(filepath.Join(root, "102"))
	check(true)

	// A reused pid with a new start time is a new worker, not an old one.
	fakeProc(t, root, 102, 100, "10", workerTitle)
	check(true)

	// No serving worker at all proves nothing.
	os.RemoveAll(filepath.Join(root, "102"))
	os.RemoveAll(filepath.Join(root, "104"))
	check(false)
}

func TestAppliedAfterMasterRestart(t *testing.T) {
	root := t.TempDir()
	pidFile := filepath.Join(root, "pid")
	os.WriteFile(pidFile, []byte("100\n"), 0o644)
	fakeProc(t, root, 100, 1, "5", "nginx: master process")
	fakeProc(t, root, 101, 100, "6", workerTitle)
	w, err := watch(root, "cat "+pidFile)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(pidFile, []byte("300\n"), 0o644)
	fakeProc(t, root, 300, 1, "20", "nginx: master process")
	fakeProc(t, root, 301, 300, "21", workerTitle)
	if ok, err := w.Applied(); err != nil || !ok {
		t.Fatalf("restarted master: %v %v", ok, err)
	}
}

func TestWatchNeedsMaster(t *testing.T) {
	for _, cmd := range []string{"echo 0", "echo", "exit 1"} {
		if _, err := watch(t.TempDir(), cmd); err == nil {
			t.Errorf("%q: want error", cmd)
		}
	}
}

func TestAwait(t *testing.T) {
	old := Poll
	Poll = time.Millisecond
	t.Cleanup(func() { Poll = old })
	n := 0
	if err := Await(func() (bool, error) { n++; return n == 3, nil }, time.Second); err != nil || n != 3 {
		t.Fatalf("Await: %v after %d", err, n)
	}
	if err := Await(func() (bool, error) { return false, nil }, 5*time.Millisecond); err == nil || !strings.Contains(err.Error(), "old workers") {
		t.Fatalf("want timeout, got %v", err)
	}
	if err := Await(func() (bool, error) { return false, fmt.Errorf("gone") }, 5*time.Millisecond); err == nil || !strings.Contains(err.Error(), "gone") {
		t.Fatalf("want last error, got %v", err)
	}
}
