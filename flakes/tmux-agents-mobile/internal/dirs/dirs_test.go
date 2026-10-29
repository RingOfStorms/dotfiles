package dirs

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func tree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{
		"projects/alpha",
		"projects/beta/src",
		"work/notes",
		"node_modules/pkg", // skipped by name
		".cache/huge",      // skipped by name
		"projects/alpha/vendor/deep/deeper/deepest", // beyond MaxDepth
	} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestListSkipsNoiseAndDepth(t *testing.T) {
	root := tree(t)
	ix := New(root)
	ix.MaxDepth = 4
	list, err := ix.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(list, "\n")
	for _, want := range []string{"projects", "projects/alpha", "work/notes"} {
		if !strings.Contains(joined, filepath.Join(root, want)) {
			t.Errorf("missing %s in index", want)
		}
	}
	for _, banned := range []string{"node_modules", ".cache"} {
		if strings.Contains(joined, banned) {
			t.Errorf("index contains skipped dir %s", banned)
		}
	}
	// Four levels below root is the cut-off.
	if strings.Contains(joined, "deepest") {
		t.Errorf("index went past MaxDepth:\n%s", joined)
	}
}

func TestSearchRanksMatches(t *testing.T) {
	root := tree(t)
	ix := New(root)
	ix.Limit = 10

	for _, query := range []string{"beta", "alpha"} {
		got, err := ix.Search(context.Background(), query)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) == 0 {
			t.Fatalf("%q returned nothing", query)
		}
		if !strings.Contains(strings.Join(got, "\n"), filepath.Join(root, "projects", query)) {
			t.Errorf("%q did not rank %s: %v", query, query, got)
		}
		for _, g := range got {
			if strings.Contains(g, "node_modules") {
				t.Errorf("%q returned a pruned dir: %s", query, g)
			}
		}
	}
}

func TestSearchEmptyShowsShallowFirst(t *testing.T) {
	root := tree(t)
	ix := New(root)
	got, err := ix.Search(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) == 0 || got[0] != root {
		t.Fatalf("first suggestion = %v, want the root", got)
	}
}

func TestSearchFallsBackWithoutFZF(t *testing.T) {
	root := tree(t)
	ix := New(root)
	ix.Bin = "/nonexistent/fzf"
	got, err := ix.Search(context.Background(), "beta")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(got, "\n"), filepath.Join(root, "projects/beta")) {
		t.Fatalf("fallback did not match beta: %v", got)
	}
}

// The fzf path is what the UI normally uses; skip when it is not installed.
func TestSearchWithFZFFuzzy(t *testing.T) {
	if _, err := exec.LookPath("fzf"); err != nil {
		t.Skip("fzf not installed")
	}
	root := tree(t)
	ix := New(root)
	got, err := ix.Search(context.Background(), "wrknts") // fuzzy: work/notes
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(got, "\n"), filepath.Join(root, "work", "notes")) {
		t.Fatalf("fuzzy search missed work/notes: %v", got)
	}
}
