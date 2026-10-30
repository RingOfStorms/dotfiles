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
