package frame

import (
	"strings"
	"testing"
)

func TestRenderKeepsColour(t *testing.T) {
	lines := Render("\x1b[31mred\x1b[0m plain", true)
	if len(lines) != 1 {
		t.Fatalf("want 1 line, got %d", len(lines))
	}
	if got := lines[0].Text; got != "red plain" {
		t.Fatalf("text = %q", got)
	}
	if !strings.Contains(lines[0].HTML, "color:#f38ba8") {
		t.Fatalf("missing colour span: %s", lines[0].HTML)
	}
	if !strings.Contains(lines[0].HTML, `>red</span> plain`) {
		t.Fatalf("unexpected html: %s", lines[0].HTML)
	}
}

func TestRenderTruecolorAndAttributes(t *testing.T) {
	html := Render("\x1b[38;2;1;2;3m\x1b[1mx\x1b[0m", true)[0].HTML
	if !strings.Contains(html, "color:#010203") || !strings.Contains(html, "font-weight:600") {
		t.Fatalf("unexpected html: %s", html)
	}
}

func TestRenderTrimsTrailingBlanks(t *testing.T) {
	if got := Render("abc   ", true)[0].Text; got != "abc" {
		t.Fatalf("trimmed text = %q", got)
	}
	if got := Render("abc   ", false)[0].Text; got != "abc   " {
		t.Fatalf("untrimmed text = %q", got)
	}
	// A line that is only spaces becomes empty rather than a span of blanks.
	if got := Render("    ", true)[0].HTML; got != "" {
		t.Fatalf("blank line html = %q", got)
	}
}

func TestRenderEscapesMarkup(t *testing.T) {
	html := Render("<script>alert(1)</script>", true)[0].HTML
	if strings.Contains(html, "<script>") {
		t.Fatalf("raw html leaked: %s", html)
	}
}

func TestRenderHyperlink(t *testing.T) {
	html := Render("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", true)[0].HTML
	if !strings.Contains(html, `<a href="https://example.com">link</a>`) {
		t.Fatalf("unexpected html: %s", html)
	}
	// javascript: URLs are dropped rather than rendered as a link.
	html = Render("\x1b]8;;javascript:alert(1)\x1b\\x\x1b]8;;\x1b\\", true)[0].HTML
	if strings.Contains(html, "javascript:") {
		t.Fatalf("unsafe link rendered: %s", html)
	}
}

func TestRenderDropsCursorSequences(t *testing.T) {
	html := Render("\x1b[2K\x1b[1Gok", true)[0].Text
	if html != "ok" {
		t.Fatalf("text = %q", html)
	}
}

func makeLines(texts ...string) []Line {
	lines := make([]Line, len(texts))
	for i, s := range texts {
		lines[i] = Line{Num: i, HTML: s, Text: s, Hash: hashString(s)}
	}
	return lines
}

func TestDiffDetectsScroll(t *testing.T) {
	old := Frame{Lines: makeLines("a", "b", "c", "d")}
	now := Frame{Lines: makeLines("b", "c", "d", "e")}
	ch := Diff(old, now)
	if ch.Full {
		t.Fatal("expected an incremental patch")
	}
	if ch.From != 1 {
		t.Fatalf("from = %d, want 1", ch.From)
	}
	if len(ch.Lines) != 1 || ch.Lines[0].Text != "e" || ch.Lines[0].Num != 3 {
		t.Fatalf("changed = %+v", ch.Lines)
	}
	if ch.Total != 4 {
		t.Fatalf("total = %d", ch.Total)
	}
}

func TestDiffFallsBackToFull(t *testing.T) {
	old := Frame{Lines: makeLines("a", "b", "c")}
	now := Frame{Lines: makeLines("x", "y", "z")}
	if ch := Diff(old, now); !ch.Full {
		t.Fatalf("expected full resend, got %+v", ch)
	}
}

func TestDiffNoChange(t *testing.T) {
	old := Frame{Lines: makeLines("a", "b")}
	ch := Diff(old, Frame{Lines: makeLines("a", "b")})
	if ch.Full || len(ch.Lines) != 0 || ch.From != 0 {
		t.Fatalf("expected empty patch, got %+v", ch)
	}
}

func TestStripANSI(t *testing.T) {
	if got := StripANSI("\x1b[31mred\x1b[0m\r\nplain"); got != "red\nplain" {
		t.Fatalf("got %q", got)
	}
}
