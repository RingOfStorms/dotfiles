package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadOverrides(t *testing.T) {
	d := t.TempDir()
	old := overridesRoot
	overridesRoot = d
	defer func() { overridesRoot = old }()
	if o := readOverrides(); o == nil || len(o) != 0 {
		t.Fatalf("empty: %#v", o)
	}
	_ = os.MkdirAll(filepath.Join(d, "app"), 0o755)
	_ = os.WriteFile(filepath.Join(d, "app", "override.json"), []byte(`{"service":"app","route":"web","exposure":"public","baseline":"tailnet","until":0}`), 0o644)
	_ = os.MkdirAll(filepath.Join(d, "bad"), 0o755)
	_ = os.WriteFile(filepath.Join(d, "bad", "override.json"), []byte("garbage"), 0o644)
	o := readOverrides()
	if len(o) != 1 || o[0].Exposure != "public" || o[0].Route != "web" {
		t.Fatalf("%#v", o)
	}
}

func TestExposeReloadPending(t *testing.T) {
	d := t.TempDir()
	old := overridesRoot
	overridesRoot = d
	defer func() { overridesRoot = old }()
	if exposeReloadPending() {
		t.Fatal("pending without marker")
	}
	_ = os.WriteFile(filepath.Join(d, ".reload-pending"), []byte("x\n"), 0o644)
	if !exposeReloadPending() {
		t.Fatal("marker not seen")
	}
	if o := readOverrides(); len(o) != 0 {
		t.Fatalf("marker read as an override: %#v", o)
	}
}
