// Package diff renders git status and per-file diffs for a pane's worktree.
// It shells out to git as the same user the tmux server runs as, read-only.
package diff

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Git runs read-only git commands.
type Git struct {
	Bin     string
	Timeout time.Duration
}

// New returns a git runner.
func New(bin string) *Git {
	if bin == "" {
		bin = "git"
	}
	return &Git{Bin: bin, Timeout: 10 * time.Second}
}

// Repo identifies the worktree a pane's directory belongs to.
type Repo struct {
	Root   string
	Branch string
}

// Find resolves dir to a worktree root and its branch.
func (g *Git) Find(ctx context.Context, dir string) (Repo, error) {
	out, err := g.run(ctx, dir, "rev-parse", "--path-format=absolute", "--show-toplevel", "--abbrev-ref", "HEAD")
	if err != nil {
		return Repo{}, err
	}
	fields := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(fields) < 2 {
		return Repo{}, errors.New("git rev-parse: unexpected output")
	}
	return Repo{Root: fields[0], Branch: fields[1]}, nil
}

// Worktrees lists the linked worktrees of the repo containing dir, plus the
// main checkout.
func (g *Git) Worktrees(ctx context.Context, dir string) ([]string, error) {
	out, err := g.run(ctx, dir, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		if p, ok := strings.CutPrefix(line, "worktree "); ok {
			paths = append(paths, p)
		}
	}
	return paths, nil
}

// File is one entry of `git status --porcelain=v1`.
type File struct {
	Path      string
	Staged    bool
	Unstaged  bool
	Untracked bool
	Status    string // two porcelain letters, for the badge
}

// Status lists changed files relative to the repo root.
func (g *Git) Status(ctx context.Context, root string) ([]File, error) {
	out, err := g.run(ctx, root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	var files []File
	entries := strings.Split(string(out), "\x00")
	for i := 0; i < len(entries); i++ {
		e := entries[i]
		if len(e) < 4 {
			continue
		}
		xy, path := e[:2], e[3:]
		if xy[0] == 'R' || xy[0] == 'C' {
			// rename/copy: the original path follows in its own record
			i++
		}
		files = append(files, File{
			Path:      path,
			Staged:    xy[0] != ' ' && xy[0] != '?',
			Unstaged:  xy[1] != ' ' && xy[1] != '?',
			Untracked: xy == "??",
			Status:    strings.TrimSpace(xy),
		})
	}
	return files, nil
}

// Line is one rendered diff line.
type Line struct {
	Kind  string // meta | hunk | add | del | ctx
	Text  string
	OldNo int
	NewNo int
}

// Sign is the change marker shown in its own gutter, like a code review UI.
func (l Line) Sign() string {
	switch l.Kind {
	case "add":
		return "+"
	case "del":
		return "-"
	}
	return ""
}

// Body is the line without its diff prefix (the +, - or leading space).
func (l Line) Body() string {
	switch l.Kind {
	case "add", "del":
		if l.Text == "" {
			return ""
		}
		return l.Text[1:]
	}
	return strings.TrimPrefix(l.Text, " ")
}

// Display drops the plumbing lines that carry no information once the page
// already names the file: diff --git, index, ---/+++, similarity index. Mode,
// rename/copy and "Binary files" notices are kept.
func Display(res Result) Result {
	out := make([]Line, 0, len(res.Lines))
	for _, l := range res.Lines {
		if l.Kind == "meta" && !notableMeta(l.Text) {
			continue
		}
		out = append(out, l)
	}
	res.Lines = out
	return res
}

func notableMeta(s string) bool {
	for _, prefix := range []string{
		"new file", "deleted file", "old mode", "new mode",
		"rename from", "rename to", "copy from", "copy to",
		"Binary files", "similarity index 100",
	} {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}

// Cell is one side of a side-by-side row. Kind is ctx, add, del, or empty.
type Cell struct {
	No   int
	Text string
	Kind string
}

// Row is a side-by-side row: a full-width header (Kind hunk/meta) or a pair of
// cells.
type Row struct {
	Kind  string
	Text  string
	Left  Cell
	Right Cell
}

// Split turns the unified diff into side-by-side rows: deletions and additions
// in the same block are paired, leftovers get an empty opposite side.
func Split(lines []Line) []Row {
	rows := make([]Row, 0, len(lines))
	var dels, adds []Line

	flush := func() {
		n := len(dels)
		if len(adds) > n {
			n = len(adds)
		}
		for i := 0; i < n; i++ {
			row := Row{Left: Cell{Kind: "empty"}, Right: Cell{Kind: "empty"}}
			if i < len(dels) {
				row.Left = Cell{No: dels[i].OldNo, Text: dels[i].Body(), Kind: "del"}
			}
			if i < len(adds) {
				row.Right = Cell{No: adds[i].NewNo, Text: adds[i].Body(), Kind: "add"}
			}
			rows = append(rows, row)
		}
		dels, adds = nil, nil
	}

	for _, l := range lines {
		switch l.Kind {
		case "del":
			dels = append(dels, l)
		case "add":
			adds = append(adds, l)
		case "ctx":
			flush()
			rows = append(rows, Row{
				Left:  Cell{No: l.OldNo, Text: l.Body(), Kind: "ctx"},
				Right: Cell{No: l.NewNo, Text: l.Body(), Kind: "ctx"},
			})
		default:
			flush()
			rows = append(rows, Row{Kind: l.Kind, Text: l.Text})
		}
	}
	flush()
	return rows
}

// Result is a file's diff, capped so a giant generated file cannot wedge the
// phone.
type Result struct {
	Lines     []Line
	Truncated bool
}

const (
	maxLines = 2000
	maxBytes = 512 << 10
)

// FileDiff renders the staged or unstaged diff of one file. context is the -U
// value. Output is always a plain unified diff: the user's diff.external (and
// textconv filters) would otherwise replace it with something unparsable.
func (g *Git) FileDiff(ctx context.Context, root, path string, staged, untracked bool, context int) (Result, error) {
	if context <= 0 {
		context = 3
	}
	var (
		out []byte
		err error
	)
	if untracked {
		out, err = g.runAllowExit1(ctx, root, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index",
			fmt.Sprintf("-U%d", context), "--", "/dev/null", path)
	} else {
		args := []string{"diff", "--no-color", "--no-ext-diff", "--no-textconv", fmt.Sprintf("-U%d", context)}
		if staged {
			args = append(args, "--cached")
		}
		args = append(args, "--", path)
		out, err = g.run(ctx, root, args...)
	}
	if err != nil {
		return Result{}, err
	}
	return Parse(string(out)), nil
}

// Parse turns unified diff text into numbered lines.
func Parse(raw string) Result {
	res := Result{}
	if raw == "" {
		return res
	}
	oldNo, newNo := 0, 0
	for _, line := range strings.Split(strings.TrimRight(raw, "\n"), "\n") {
		if len(res.Lines) >= maxLines || res.Truncated {
			res.Truncated = true
			break
		}
		switch {
		case strings.HasPrefix(line, "@@"):
			oldNo, newNo = parseHunkHeader(line)
			res.Lines = append(res.Lines, Line{Kind: "hunk", Text: line})
		case strings.HasPrefix(line, "diff "), strings.HasPrefix(line, "index "),
			strings.HasPrefix(line, "--- "), strings.HasPrefix(line, "+++ "),
			strings.HasPrefix(line, "new file"), strings.HasPrefix(line, "deleted"),
			strings.HasPrefix(line, "old mode"), strings.HasPrefix(line, "new mode"),
			strings.HasPrefix(line, "similarity"), strings.HasPrefix(line, "rename"):
			res.Lines = append(res.Lines, Line{Kind: "meta", Text: line})
		case strings.HasPrefix(line, "\\"):
			// "\ No newline at end of file"
		case strings.HasPrefix(line, "+"):
			res.Lines = append(res.Lines, Line{Kind: "add", Text: line, NewNo: newNo})
			newNo++
		case strings.HasPrefix(line, "-"):
			res.Lines = append(res.Lines, Line{Kind: "del", Text: line, OldNo: oldNo})
			oldNo++
		default:
			res.Lines = append(res.Lines, Line{Kind: "ctx", Text: line, OldNo: oldNo, NewNo: newNo})
			oldNo++
			newNo++
		}
	}
	return res
}

func parseHunkHeader(line string) (int, int) {
	// @@ -12,7 +12,9 @@ trailing context
	var oldNo, newNo int
	for _, field := range strings.Fields(line) {
		switch {
		case strings.HasPrefix(field, "-") && len(field) > 1:
			oldNo = leadingInt(field[1:])
		case strings.HasPrefix(field, "+") && len(field) > 1:
			newNo = leadingInt(field[1:])
		}
	}
	return oldNo, newNo
}

func leadingInt(s string) int {
	if i := strings.IndexByte(s, ','); i >= 0 {
		s = s[:i]
	}
	n, _ := strconv.Atoi(s)
	return n
}

func (g *Git) run(ctx context.Context, dir string, args ...string) ([]byte, error) {
	return g.exec(ctx, false, dir, args...)
}

func (g *Git) runAllowExit1(ctx context.Context, dir string, args ...string) ([]byte, error) {
	return g.exec(ctx, true, dir, args...)
}

func (g *Git) exec(ctx context.Context, allowExit1 bool, dir string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, g.timeout())
	defer cancel()

	cmd := exec.CommandContext(ctx, g.Bin, append([]string{"--no-pager", "-C", dir}, args...)...)
	cmd.Env = append(cmd.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		var exit *exec.ExitError
		if allowExit1 && errors.As(err, &exit) && exit.ExitCode() == 1 {
			return stdout.Bytes(), nil
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("git %s: %s", args[0], msg)
	}
	if stdout.Len() > maxBytes {
		return stdout.Bytes()[:maxBytes], nil
	}
	return stdout.Bytes(), nil
}

func (g *Git) timeout() time.Duration {
	if g.Timeout <= 0 {
		return 10 * time.Second
	}
	return g.Timeout
}
