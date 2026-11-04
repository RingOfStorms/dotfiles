package web

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer"
	"github.com/yuin/goldmark/util"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/watch"
)

// markdown renders agent prose. It is safe for model output: raw HTML is
// shown as text (models write <tags> in prose all the time; dropping them
// would lose words) and goldmark filters dangerous link schemes.
var markdown = goldmark.New(
	goldmark.WithExtensions(
		extension.Table,
		extension.Strikethrough,
		extension.Linkify,
		extension.TaskList,
	),
	goldmark.WithRendererOptions(renderer.WithNodeRenderers(util.Prioritized(literalHTML{}, 100))),
)

// literalHTML renders raw HTML nodes as escaped source text.
type literalHTML struct{}

func (literalHTML) RegisterFuncs(reg renderer.NodeRendererFuncRegisterer) {
	reg.Register(ast.KindRawHTML, func(w util.BufWriter, source []byte, node ast.Node, entering bool) (ast.WalkStatus, error) {
		if entering {
			segs := node.(*ast.RawHTML).Segments
			for i := range segs.Len() {
				seg := segs.At(i)
				_, _ = w.WriteString(template.HTMLEscapeString(string(seg.Value(source))))
			}
		}
		return ast.WalkSkipChildren, nil
	})
	reg.Register(ast.KindHTMLBlock, func(w util.BufWriter, source []byte, node ast.Node, entering bool) (ast.WalkStatus, error) {
		n := node.(*ast.HTMLBlock)
		if entering {
			_, _ = w.WriteString(`<p class="rawhtml">`)
			lines := n.Lines()
			for i := range lines.Len() {
				line := lines.At(i)
				_, _ = w.WriteString(template.HTMLEscapeString(string(line.Value(source))))
			}
			if n.HasClosure() {
				_, _ = w.WriteString(template.HTMLEscapeString(string(n.ClosureLine.Value(source))))
			}
			_, _ = w.WriteString("</p>\n")
		}
		return ast.WalkSkipChildren, nil
	})
}

// stripWrapperTags drops lines that are nothing but an opening or closing
// tag: notices wrap their body in <irc>, <system-notice>, <task-result …>.
func stripWrapperTags(s string) string {
	var b strings.Builder
	for line := range strings.SplitSeq(s, "\n") {
		if isWrapperTag(strings.TrimSpace(line)) {
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return strings.TrimSpace(b.String())
}

func isWrapperTag(line string) bool {
	return strings.HasPrefix(line, "<") && strings.HasSuffix(line, ">") && !strings.Contains(line[1:], "<")
}

var chatTemplates = template.Must(template.New("").Funcs(template.FuncMap{
	"md":          renderMarkdown,
	"firstLine":   firstLine,
	"summaryLine": summaryLine,
	"unwrap":      stripWrapperTags,
	"diffLines":   diffLines,
	"toolGlyph":   toolGlyph,
	"askData": func(questions []transcript.AskQuestion) string {
		data, _ := json.Marshal(questions)
		return string(data)
	},
	"noticeLabel": func(s string) string {
		return strings.ReplaceAll(s, "-", " ")
	},
	"todoGlyph": todoGlyph,
	"duration":  shortDuration,
	"jobsDone":  jobsDone,
}).ParseFS(assets, "templates/chat/*.html"))

// ChatRenderer is the markup for the native conversation view.
var ChatRenderer = watch.ChatRenderer{
	Item:  RenderChatItem,
	Todos: RenderTodos,
	Recap: RenderRecap,
}

// RenderChatItem renders one transcript item; the chat hub caches the result
// per item revision.
func RenderChatItem(it transcript.Item) string {
	return renderChat("item", it)
}

// TodoView is the todo card: the phases plus a one-line summary for the
// collapsed state.
type TodoView struct {
	Phases []transcript.TodoPhase
	Done   int
	Total  int
	// Current is the task in progress, else the next pending one.
	Current string
}

// RenderTodos renders the pinned todo card; empty when every task is closed
// (or there are none), as omp hides its own HUD then.
func RenderTodos(phases []transcript.TodoPhase) string {
	v := TodoView{Phases: phases}
	open, next := false, ""
	for _, p := range phases {
		for _, t := range p.Tasks {
			v.Total++
			switch t.Status {
			case transcript.TodoCompleted, transcript.TodoAbandoned:
				v.Done++
			case transcript.TodoInProgress:
				open = true
				if v.Current == "" {
					v.Current = t.Content
				}
			default:
				open = true
				if next == "" {
					next = t.Content
				}
			}
		}
	}
	if !open {
		return ""
	}
	if v.Current == "" {
		v.Current = next
	}
	return renderChat("todos", v)
}

// RecapView is omp's recap as shown.
type RecapView struct {
	Text string
	At   time.Time
}

// RenderRecap renders omp's idle recap.
func RenderRecap(r transcript.Recap) string {
	return renderChat("recap", RecapView{Text: r.Text, At: r.CreatedAt})
}

func renderChat(name string, data any) string {
	var b strings.Builder
	if err := chatTemplates.ExecuteTemplate(&b, name, data); err != nil {
		return `<div class="msg notice">render error: ` + template.HTMLEscapeString(err.Error()) + `</div>`
	}
	return b.String()
}

func todoGlyph(s transcript.TodoStatus) string {
	switch s {
	case transcript.TodoCompleted:
		return "✓"
	case transcript.TodoInProgress:
		return "▸"
	case transcript.TodoBlocked:
		return "!"
	case transcript.TodoAbandoned:
		return "⊘"
	}
	return "○"
}

func jobsDone(jobs []transcript.Job) int {
	n := 0
	for _, j := range jobs {
		if j.Status != transcript.ToolRunning {
			n++
		}
	}
	return n
}

// shortDuration formats milliseconds as omp does: "45s", "7m9s", "1h2m".
func shortDuration(ms int64) string {
	d := time.Duration(ms) * time.Millisecond
	switch {
	case d < time.Second:
		return ""
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm%ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
}

func renderMarkdown(src string) template.HTML {
	var buf bytes.Buffer
	if err := markdown.Convert([]byte(src), &buf); err != nil {
		return template.HTML("<pre>" + template.HTMLEscapeString(src) + "</pre>")
	}
	return template.HTML(buf.String())
}

// summaryLine is the first line with something to read: notices wrap their
// body in tags like <irc> or <advisory severity="…">, which say nothing.
func summaryLine(s string) string {
	for line := range strings.SplitSeq(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || isWrapperTag(line) {
			continue
		}
		return line
	}
	return ""
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	line, _, cut := strings.Cut(s, "\n")
	if cut {
		return line + " …"
	}
	return line
}

// DiffLine is one row of an edit's recorded diff.
type DiffLine struct {
	Class string
	Text  string
}

func diffLines(d string) []DiffLine {
	var out []DiffLine
	for _, line := range strings.Split(strings.TrimRight(d, "\n"), "\n") {
		class := "ctx"
		switch {
		case strings.HasPrefix(line, "+"):
			class = "add"
		case strings.HasPrefix(line, "-"):
			class = "del"
		case strings.HasPrefix(line, "…"):
			class = "more"
		}
		out = append(out, DiffLine{Class: class, Text: line})
	}
	return out
}

func toolGlyph(s transcript.ToolStatus) string {
	switch s {
	case transcript.ToolRunning:
		return "⠿"
	case transcript.ToolDone:
		return "✓"
	case transcript.ToolError:
		return "✗"
	case transcript.ToolStopped:
		return "⊘"
	}
	return "·"
}
