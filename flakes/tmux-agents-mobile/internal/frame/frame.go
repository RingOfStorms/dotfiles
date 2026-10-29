// Package frame turns a `tmux capture-pane -e` dump into HTML spans and diffs
// successive captures so the phone only receives lines that changed.
//
// This is deliberately not a terminal emulator: capture-pane already gives a
// rendered screen, so the only sequences that matter are SGR (colours and
// attributes) and OSC 8 (hyperlinks). Everything else is dropped.
package frame

import (
	"hash/fnv"
	"html"
	"strconv"
	"strings"
)

// Line is one captured row. Num is the row's index in the capture and is what
// patches address; HTML is safe to insert.
type Line struct {
	Num  int    `json:"n"`
	HTML string `json:"h"`
	Text string `json:"-"`
	Hash uint64 `json:"-"`
}

// Frame is one captured screen plus the pane geometry it was captured at.
type Frame struct {
	Cols    int    `json:"cols"`
	Rows    int    `json:"rows"`
	CursorX int    `json:"cx"`
	CursorY int    `json:"cy"`
	InMode  bool   `json:"in_mode"`
	Dead    bool   `json:"dead"`
	Lines   []Line `json:"lines"`
}

// Render parses a capture into lines. trimTrailing drops trailing blanks, which
// is the right behaviour when the browser re-wraps the text at phone width;
// fixed-width ("fit") mode keeps them so columns stay aligned.
func Render(raw string, trimTrailing bool) []Line {
	p := &parser{trim: trimTrailing}
	p.parse(raw)
	// A capture that does not end in a newline still has a last line.
	if p.pending.Len() > 0 || len(p.spans) > 0 {
		p.endLine()
	}
	return p.lines
}

type color struct {
	css string
}

type sgrState struct {
	fg, bg                               color
	bold, dim, italic, underline, strike bool
	reverse, hidden                      bool
	link                                 string
}

func (s *sgrState) reset() {
	*s = sgrState{link: s.link}
}

type span struct {
	text, style, href string
}

type parser struct {
	trim    bool
	lines   []Line
	spans   []span
	pending strings.Builder
	st      sgrState
}

func (p *parser) parse(raw string) {
	for i := 0; i < len(raw); i++ {
		switch b := raw[i]; {
		case b == 0x1b:
			i += p.escape(raw[i:])
		case b == '\n':
			p.endLine()
		case b == '\r':
			// capture-pane output is already line-based
		case b == '\t':
			p.pending.WriteByte('\t')
		case b < 0x20 || b == 0x7f:
			// bell and other controls: drop
		default:
			p.pending.WriteByte(b)
		}
	}
}

// escape consumes one escape sequence starting at raw[0] == ESC and returns the
// number of extra bytes consumed.
func (p *parser) escape(raw string) int {
	if len(raw) < 2 {
		return len(raw) - 1
	}
	switch raw[1] {
	case '[':
		j := 2
		for j < len(raw) && raw[j] >= 0x20 && raw[j] <= 0x3f {
			j++
		}
		if j >= len(raw) {
			return len(raw) - 1
		}
		if raw[j] == 'm' {
			p.sgr(string(raw[2:j]))
		}
		return j // bytes consumed after the ESC
	case ']':
		// OSC ... (BEL | ESC \)
		j := 2
		for j < len(raw) {
			if raw[j] == 0x07 {
				p.osc(string(raw[2:j]))
				return j
			}
			if raw[j] == 0x1b && j+1 < len(raw) && raw[j+1] == '\\' {
				p.osc(string(raw[2:j]))
				return j + 1
			}
			j++
		}
		return len(raw) - 1
	case '(', ')', '*', '+', '#', '%':
		// charset designation: one more byte
		return 2
	default:
		return 1
	}
}

func (p *parser) osc(body string) {
	// OSC 8 ; params ; uri ST — hyperlink on (uri non-empty) or off.
	if !strings.HasPrefix(body, "8;") {
		return
	}
	parts := strings.SplitN(body, ";", 3)
	if len(parts) != 3 {
		return
	}
	p.flushSpan()
	if safeURL(parts[2]) {
		p.st.link = parts[2]
	} else {
		p.st.link = ""
	}
}

func safeURL(u string) bool {
	l := strings.ToLower(u)
	return strings.HasPrefix(l, "http://") || strings.HasPrefix(l, "https://") || strings.HasPrefix(l, "mailto:")
}

func (p *parser) sgr(params string) {
	if params == "" {
		p.flushSpan()
		p.st.reset()
		return
	}
	f := strings.Split(params, ";")
	for i := 0; i < len(f); i++ {
		n, _ := strconv.Atoi(f[i])
		switch {
		case n == 0:
			p.flushSpan()
			p.st.reset()
		case n == 1:
			p.set(&p.st.bold, true)
		case n == 2:
			p.set(&p.st.dim, true)
		case n == 3:
			p.set(&p.st.italic, true)
		case n == 4:
			p.set(&p.st.underline, true)
		case n == 7:
			p.set(&p.st.reverse, true)
		case n == 8:
			p.set(&p.st.hidden, true)
		case n == 9:
			p.set(&p.st.strike, true)
		case n == 21, n == 22:
			p.set(&p.st.bold, false)
			p.set(&p.st.dim, false)
		case n == 23:
			p.set(&p.st.italic, false)
		case n == 24:
			p.set(&p.st.underline, false)
		case n == 27:
			p.set(&p.st.reverse, false)
		case n == 28:
			p.set(&p.st.hidden, false)
		case n == 29:
			p.set(&p.st.strike, false)
		case n >= 30 && n <= 37:
			p.setColor(&p.st.fg, palette[n-30])
		case n == 39:
			p.setColor(&p.st.fg, "")
		case n >= 40 && n <= 47:
			p.setColor(&p.st.bg, palette[n-40])
		case n == 49:
			p.setColor(&p.st.bg, "")
		case n >= 90 && n <= 97:
			p.setColor(&p.st.fg, palette[n-90+8])
		case n >= 100 && n <= 107:
			p.setColor(&p.st.bg, palette[n-100+8])
		case n == 38 || n == 48:
			css, used := extendedColor(f[i+1:])
			if used > 0 {
				i += used
			}
			if css != "" {
				if n == 38 {
					p.setColor(&p.st.fg, css)
				} else {
					p.setColor(&p.st.bg, css)
				}
			}
		}
	}
}

func (p *parser) set(field *bool, v bool) {
	if *field != v {
		p.flushSpan()
		*field = v
	}
}

func (p *parser) setColor(c *color, css string) {
	if c.css != css {
		p.flushSpan()
		c.css = css
	}
}

// extendedColor parses the parameters after 38/48. It returns the CSS colour and
// how many parameters were consumed.
func extendedColor(f []string) (string, int) {
	if len(f) == 0 {
		return "", 0
	}
	switch f[0] {
	case "5":
		if len(f) < 2 {
			return "", 0
		}
		n, err := strconv.Atoi(f[1])
		if err != nil || n < 0 || n > 255 {
			return "", 2
		}
		return color256(n), 2
	case "2":
		if len(f) < 4 {
			return "", 0
		}
		r, e1 := strconv.Atoi(f[1])
		g, e2 := strconv.Atoi(f[2])
		b, e3 := strconv.Atoi(f[3])
		if e1 != nil || e2 != nil || e3 != nil {
			return "", 4
		}
		return rgb(r, g, b), 4
	}
	return "", 0
}

func rgb(r, g, b int) string {
	clamp := func(v int) int {
		if v < 0 {
			return 0
		}
		if v > 255 {
			return 255
		}
		return v
	}
	return "#" + hex2(clamp(r)) + hex2(clamp(g)) + hex2(clamp(b))
}

func hex2(v int) string {
	const digits = "0123456789abcdef"
	return string([]byte{digits[v>>4], digits[v&0xf]})
}

// color256 maps the xterm 256-colour palette. The first 16 entries use the
// Catppuccin Mocha ANSI set, which is what the desktop terminals are themed
// with, so colours match what the agent actually looks like.
func color256(n int) string {
	if n < 16 {
		return palette[n]
	}
	if n < 232 {
		n -= 16
		level := func(v int) int {
			if v == 0 {
				return 0
			}
			return 55 + v*40
		}
		return rgb(level(n/36), level((n/6)%6), level(n%6))
	}
	v := 8 + (n-232)*10
	return rgb(v, v, v)
}

// palette is the 16-colour ANSI set (Catppuccin Mocha).
var palette = [16]string{
	"#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
	"#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
	"#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
	"#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
}

func (p *parser) style() string {
	fg, bg := p.st.fg.css, p.st.bg.css
	if p.st.reverse {
		fg, bg = bg, fg
		if fg == "" {
			fg = "var(--term-bg)"
		}
		if bg == "" {
			bg = "var(--term-fg)"
		}
	}
	var parts []string
	if p.st.bold {
		parts = append(parts, "font-weight:600")
	}
	if p.st.dim {
		parts = append(parts, "opacity:.65")
	}
	if p.st.italic {
		parts = append(parts, "font-style:italic")
	}
	decoration := ""
	if p.st.underline {
		decoration = "underline"
	}
	if p.st.strike {
		decoration += " line-through"
	}
	if decoration != "" {
		parts = append(parts, "text-decoration:"+strings.TrimSpace(decoration))
	}
	if p.st.hidden {
		parts = append(parts, "visibility:hidden")
	}
	if fg != "" {
		parts = append(parts, "color:"+fg)
	}
	if bg != "" {
		parts = append(parts, "background-color:"+bg)
	}
	return strings.Join(parts, ";")
}

func (p *parser) flushSpan() {
	if p.pending.Len() == 0 {
		return
	}
	text := p.pending.String()
	p.pending.Reset()
	p.spans = append(p.spans, span{text: text, style: p.style(), href: p.st.link})
}

func (p *parser) endLine() {
	p.flushSpan()
	spans := p.spans
	if p.trim {
		for len(spans) > 0 {
			last := &spans[len(spans)-1]
			trimmed := strings.TrimRight(last.text, " \t")
			if trimmed == "" {
				spans = spans[:len(spans)-1]
				continue
			}
			last.text = trimmed
			break
		}
	}
	var sb strings.Builder
	var text strings.Builder
	for _, s := range spans {
		text.WriteString(s.text)
		esc := html.EscapeString(s.text)
		switch {
		case s.href != "" && s.style != "":
			sb.WriteString(`<a href="` + html.EscapeString(s.href) + `" style="` + s.style + `">` + esc + `</a>`)
		case s.href != "":
			sb.WriteString(`<a href="` + html.EscapeString(s.href) + `">` + esc + `</a>`)
		case s.style != "":
			sb.WriteString(`<span style="` + s.style + `">` + esc + `</span>`)
		default:
			sb.WriteString(esc)
		}
	}
	p.lines = append(p.lines, Line{
		Num:  len(p.lines),
		HTML: sb.String(),
		Text: text.String(),
		Hash: hashString(sb.String()),
	})
	p.spans = nil
}

func hashString(s string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return h.Sum64()
}

// Change describes how to turn an old frame into a new one.
//
// From is the old row index that new row 0 corresponds to (the pane scrolled by
// From rows), so a client can carry unchanged rows and apply Lines on top. Full
// asks for a wholesale replace.
type Change struct {
	From  int    `json:"from,omitempty"`
	Full  bool   `json:"full,omitempty"`
	Total int    `json:"total"`
	Lines []Line `json:"lines,omitempty"`
}

// Diff compares two frames of the same pane. Panes scroll far more often than
// they repaint in place, so the row offset is detected first: a screen that
// scrolled by one row then costs one line instead of the whole grid.
func Diff(old, new Frame) Change {
	if len(new.Lines) == 0 || len(old.Lines) == 0 {
		return Change{Full: true, Total: len(new.Lines), Lines: new.Lines}
	}
	from := bestShift(old.Lines, new.Lines)
	carried := make([]uint64, len(new.Lines))
	for i := range new.Lines {
		j := i + from
		if j >= 0 && j < len(old.Lines) {
			carried[i] = old.Lines[j].Hash
		}
	}
	var changed []Line
	for i, ln := range new.Lines {
		if ln.Hash != carried[i] {
			changed = append(changed, ln)
		}
	}
	if len(changed)*2 > len(new.Lines) {
		return Change{Full: true, Total: len(new.Lines), Lines: new.Lines}
	}
	return Change{From: from, Total: len(new.Lines), Lines: changed}
}

// bestShift finds the offset that keeps the most rows identical.
func bestShift(old, new []Line) int {
	const window = 40
	best, bestScore := 0, -1
	for k := -window; k <= window; k++ {
		score := 0
		for i := range new {
			j := i + k
			if j >= 0 && j < len(old) && old[j].Hash == new[i].Hash {
				score++
			}
		}
		if score > bestScore || (score == bestScore && k == 0) {
			best, bestScore = k, score
		}
	}
	return best
}

// StripANSI removes escape sequences from a plain capture (no -e), used for
// one-line previews.
func StripANSI(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == 0x1b {
			j := i + 1
			if j < len(s) && s[j] == '[' {
				j++
				for j < len(s) && s[j] >= 0x20 && s[j] <= 0x3f {
					j++
				}
			}
			i = j // skip the escape and its final byte
			continue
		}
		if s[i] == '\r' {
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
