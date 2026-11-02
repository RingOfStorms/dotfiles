package web

import (
	"net/url"
	"strings"
	"testing"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

func TestRenderChatItemEscapesModelOutput(t *testing.T) {
	html := RenderChatItem(transcript.Item{
		Kind: transcript.KindAssistant,
		Parts: []transcript.Part{
			{Kind: transcript.PartText, Text: "**bold** <script>alert(1)</script> [x](javascript:alert(1))"},
			{Kind: transcript.PartTool, Tool: transcript.Tool{Name: "bash", Detail: "echo <b>hi</b>", Status: transcript.ToolDone, Output: "<img src=x onerror=alert(1)>"}},
		},
	})
	if !strings.Contains(html, "<strong>bold</strong>") {
		t.Fatalf("markdown not rendered: %s", html)
	}
	if !strings.Contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;") {
		t.Fatalf("raw html should show as text: %s", html)
	}
	block := RenderChatItem(transcript.Item{Kind: transcript.KindAssistant, Parts: []transcript.Part{
		{Kind: transcript.PartText, Text: "<div onclick=x>\nhello\n</div>"},
	}})
	if strings.Contains(block, "<div onclick") || !strings.Contains(block, "&lt;div onclick=x&gt;") {
		t.Fatalf("html block should show as text: %s", block)
	}
	for _, bad := range []string{"<script>", "javascript:", "<img", "<b>hi"} {
		if strings.Contains(html, bad) {
			t.Fatalf("unsafe %q in output: %s", bad, html)
		}
	}
}

func TestRenderChatItemUserTextIsLiteral(t *testing.T) {
	html := RenderChatItem(transcript.Item{Kind: transcript.KindUser, Text: "use **this** <tag>", Files: []string{"a.go"}})
	if !strings.Contains(html, "use **this** &lt;tag&gt;") || !strings.Contains(html, "@a.go") {
		t.Fatalf("user html = %s", html)
	}
}

func TestRenderTodos(t *testing.T) {
	phases := []transcript.TodoPhase{{Name: "Build", Tasks: []transcript.TodoTask{
		{Content: "done", Status: transcript.TodoCompleted},
		{Content: "<now>", Status: transcript.TodoInProgress},
		{Content: "later", Status: transcript.TodoPending},
	}}}
	html := RenderTodos(phases)
	for _, want := range []string{"1/3", "&lt;now&gt;", "td-in_progress", "Build"} {
		if !strings.Contains(html, want) {
			t.Fatalf("missing %q: %s", want, html)
		}
	}
	phases[0].Tasks[1].Status = transcript.TodoCompleted
	phases[0].Tasks[2].Status = transcript.TodoAbandoned
	if html := RenderTodos(phases); html != "" {
		t.Fatalf("closed list should hide the card: %s", html)
	}
}

func TestRenderEventsJobsAndRecap(t *testing.T) {
	ev := RenderChatItem(transcript.Item{Kind: transcript.KindEvent, Settings: []transcript.Setting{{Key: "model", Value: "opus"}, {Key: "thinking", Value: "high"}}})
	if !strings.Contains(ev, `model <span class="eval">opus</span> · thinking <span class="eval">high</span>`) {
		t.Fatalf("event = %s", ev)
	}
	tool := RenderChatItem(transcript.Item{Kind: transcript.KindAssistant, Parts: []transcript.Part{{Kind: transcript.PartTool, Tool: transcript.Tool{
		Name: "task", Status: transcript.ToolDone,
		Jobs: []transcript.Job{{Name: "Alpha", Agent: "scout", Status: transcript.ToolDone, DurationMs: 429000}, {Name: "Beta", Status: transcript.ToolRunning}},
	}}}})
	for _, want := range []string{"1/2", "Alpha", "scout", "7m9s", `class="st-running"`} {
		if !strings.Contains(tool, want) {
			t.Fatalf("missing %q: %s", want, tool)
		}
	}
	if r := RenderRecap(transcript.Recap{Text: "did <x>"}); !strings.Contains(r, "※ recap: did &lt;x&gt;") {
		t.Fatalf("recap = %s", r)
	}
}

func TestSummaryLineSkipsWrapperTags(t *testing.T) {
	if got := summaryLine("<advisory severity=\"concern\">\n\nVerify the count\nmore"); got != "Verify the count" {
		t.Fatalf("summaryLine = %q", got)
	}
	if got := summaryLine("<b>inline</b> text"); got != "<b>inline</b> text" {
		t.Fatalf("summaryLine inline = %q", got)
	}
}

func TestRequestedView(t *testing.T) {
	cases := map[string]PaneView{
		"":            "",
		"view=native": ViewNative,
		"view=wrap":   ViewWrap,
		"view=fit":    ViewFit,
		"fit=1":       ViewFit,
		"view=bogus":  "",
	}
	for raw, want := range cases {
		q, _ := url.ParseQuery(raw)
		if got := requestedView(q); got != want {
			t.Errorf("requestedView(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestPaneActionsOfferOtherViews(t *testing.T) {
	labels := func(actions []Action) string {
		var out []string
		for _, a := range actions {
			if strings.Contains(a.Href, "view=") {
				out = append(out, a.Href[strings.Index(a.Href, "view="):])
			}
		}
		return strings.Join(out, ",")
	}
	if got := labels(paneActions("1", ViewNative, true)); got != "view=wrap,view=fit" {
		t.Errorf("native: %s", got)
	}
	if got := labels(paneActions("1", ViewFit, true)); got != "view=native,view=wrap" {
		t.Errorf("fit with native: %s", got)
	}
	if got := labels(paneActions("1", ViewWrap, false)); got != "view=fit" {
		t.Errorf("wrap without native: %s", got)
	}
}
