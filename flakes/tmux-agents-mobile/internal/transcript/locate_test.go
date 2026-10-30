package transcript

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestCrumbResolvesRelativeAndAbsolute(t *testing.T) {
	dir := t.TempDir()
	l := &Locator{OmpDir: dir}
	if err := os.MkdirAll(filepath.Join(dir, "terminal-sessions"), 0o700); err != nil {
		t.Fatal(err)
	}
	session := filepath.Join(dir, "sessions", "-x", "s.jsonl")
	if err := os.MkdirAll(filepath.Dir(session), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(session, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, "terminal-sessions", name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	write("pts-3", "/x\n"+session+"\ncwdstat 1 2\n")
	if got, ok := l.crumb("pts/3"); !ok || got != session {
		t.Fatalf("absolute crumb = %q, %v", got, ok)
	}
	write("pts-4", filepath.Dir(session)+"\ns.jsonl\n")
	if got, ok := l.crumb("/dev/pts/4"); !ok || got != session {
		t.Fatalf("relative crumb = %q, %v", got, ok)
	}
	write("pts-5", "/x\n/does/not/exist.jsonl\n")
	if _, ok := l.crumb("pts/5"); ok {
		t.Fatal("missing session file should not resolve")
	}
	if _, ok := l.crumb("?"); ok {
		t.Fatal("no tty should not resolve")
	}
}

func TestFindWithoutAgent(t *testing.T) {
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("ps not installed")
	}
	l := &Locator{OmpDir: t.TempDir()}
	// Our own process tree has no omp in it.
	if _, _, err := l.Find(context.Background(), os.Getpid()); err != ErrNoSession {
		t.Fatalf("Find = %v, want ErrNoSession", err)
	}
	if _, _, err := l.Find(context.Background(), 0); err != ErrNoSession {
		t.Fatalf("Find(0) = %v", err)
	}
}
