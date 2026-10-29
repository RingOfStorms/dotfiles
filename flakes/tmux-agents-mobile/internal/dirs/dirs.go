// Package dirs indexes the directories under a root and ranks them for the
// new-session picker. Ranking is fzf's when the binary is available (fuzzy,
// path-aware, best match first), with a plain substring fallback so the picker
// still works on a machine without fzf.
package dirs

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// skipNames are directories that never hold a checkout worth opening, or whose
// subtrees are enormous. The walk stops at them.
var skipNames = map[string]bool{
	"node_modules": true, ".git": true, ".hg": true, ".svn": true,
	".cache": true, ".direnv": true, ".venv": true, "venv": true,
	"__pycache__": true, ".mypy_cache": true, ".pytest_cache": true,
	".cargo": true, ".rustup": true, ".m2": true, ".gradle": true,
	".npm": true, ".bun": true, ".pnpm-store": true, ".yarn": true,
	"target": true, "dist": true, "build": true, "result": true,
	".next": true, ".svelte-kit": true, ".nuxt": true, ".terraform": true,
	".nix-profile": true, ".nix-defexpr": true, ".Trash": true,
	".mozilla": true, ".thunderbird": true, "snap": true, "go": true,
	"Library": true, "Applications": true, "Music": true, "Videos": true,
}

// skipRel prunes heavy subtrees that are only reachable through an allowed dot
// directory (.config, .local).
var skipRel = map[string]bool{
	".local/share/opencode":   true,
	".local/share/containers": true,
	".local/share/Trash":      true,
	".local/share/nix":        true,
	".local/share/flatpak":    true,
	".local/share/Steam":      true,
	".local/state":            true,
	".config/Code":            true,
	".config/Code - OSS":      true,
	".config/google-chrome":   true,
	".config/Chromium":        true,
	".config/Slack":           true,
	".config/discord":         true,
	".config/spotify":         true,
	".config/BraveSoftware":   true,
	".config/Element":         true,
}

// Index caches a bounded walk of Root.
type Index struct {
	Root     string
	MaxDepth int           // directory levels below Root
	Bin      string        // fzf binary; empty means "look on PATH"
	TTL      time.Duration // how long the walk is reused
	Limit    int           // suggestions returned per query

	mu   sync.Mutex
	at   time.Time
	list []string
}

// New returns an index rooted at the given directory.
func New(root string) *Index {
	return &Index{Root: root, MaxDepth: 6, TTL: time.Minute, Limit: 40}
}

// List returns every candidate directory, cached for TTL.
func (ix *Index) List(ctx context.Context) ([]string, error) {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	if len(ix.list) > 0 && time.Since(ix.at) < ix.ttl() {
		return ix.list, nil
	}
	list, err := ix.walk()
	if err != nil {
		if len(ix.list) > 0 {
			return ix.list, nil // keep serving the previous index
		}
		return nil, err
	}
	ix.list, ix.at = list, time.Now()
	return list, nil
}

// Search ranks the indexed directories for a query. An empty query returns the
// top of the index (root first, then its immediate children), which is what the
// picker shows before anything is typed.
func (ix *Index) Search(ctx context.Context, query string) ([]string, error) {
	list, err := ix.List(ctx)
	if err != nil {
		return nil, err
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return truncate(orderDefault(ix.Root, list), ix.limit()), nil
	}
	if out, err := ix.fzf(ctx, list, query); err == nil {
		return truncate(out, ix.limit()), nil
	}
	// No fzf, or it refused the query: a substring match is still useful.
	return truncate(match(list, query), ix.limit()), nil
}

func (ix *Index) ttl() time.Duration {
	if ix.TTL <= 0 {
		return time.Minute
	}
	return ix.TTL
}

func (ix *Index) limit() int {
	if ix.Limit <= 0 {
		return 40
	}
	return ix.Limit
}

func (ix *Index) walk() ([]string, error) {
	root, err := filepath.Abs(ix.Root)
	if err != nil {
		return nil, err
	}
	base := strings.Count(root, string(os.PathSeparator))
	var dirs []string
	walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if path == root {
				return err
			}
			return nil // unreadable subtree: skip it
		}
		if !d.IsDir() {
			return nil
		}
		if path != root {
			name := d.Name()
			// Hidden directories are noise (caches, tool state), except the two
			// that routinely hold checkouts: .config and .local.
			if strings.HasPrefix(name, ".") && name != ".config" && name != ".local" {
				return fs.SkipDir
			}
			if skipNames[name] {
				return fs.SkipDir
			}
			if rel, err := filepath.Rel(root, path); err == nil && skipRel[filepath.ToSlash(rel)] {
				return fs.SkipDir
			}
			if strings.Count(path, string(os.PathSeparator))-base >= ix.MaxDepth {
				return fs.SkipDir
			}
		}
		dirs = append(dirs, path)
		return nil
	})
	if walkErr != nil {
		return nil, walkErr
	}
	sort.Strings(dirs)
	return dirs, nil
}

// fzf ranks with `fzf --filter`, which is fuzzy, path-aware and sorted by score
// without needing a terminal.
func (ix *Index) fzf(ctx context.Context, list []string, query string) ([]string, error) {
	bin := ix.Bin
	if bin == "" {
		bin = "fzf"
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "--filter", query, "--scheme=path")
	cmd.Stdin = strings.NewReader(strings.Join(list, "\n"))
	cmd.Env = append(os.Environ(), "LC_ALL=C")

	out, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		// fzf exits 1 with no output when nothing matches; that is not a failure.
		if errors.As(err, &exit) && exit.ExitCode() == 1 {
			return nil, nil
		}
		return nil, fmt.Errorf("fzf: %w", err)
	}
	var hits []string
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			hits = append(hits, line)
		}
	}
	return hits, nil
}

// match is the no-fzf fallback: candidates whose path contains the query,
// shortest first so shallow, likely directories win.
func match(list []string, query string) []string {
	q := strings.ToLower(query)
	var hits []string
	for _, path := range list {
		if strings.Contains(strings.ToLower(path), q) {
			hits = append(hits, path)
		}
	}
	sort.SliceStable(hits, func(i, j int) bool { return len(hits[i]) < len(hits[j]) })
	return hits
}

// orderDefault puts the root first, then its children, then the rest.
func orderDefault(root string, list []string) []string {
	out := make([]string, 0, len(list))
	out = append(out, list...)
	rank := func(p string) int {
		depth := strings.Count(p, string(os.PathSeparator))
		if p == root {
			return -1
		}
		return depth
	}
	sort.SliceStable(out, func(i, j int) bool {
		ri, rj := rank(out[i]), rank(out[j])
		if ri != rj {
			return ri < rj
		}
		return out[i] < out[j]
	})
	return out
}

func truncate(list []string, n int) []string {
	if len(list) > n {
		return list[:n]
	}
	return list
}
