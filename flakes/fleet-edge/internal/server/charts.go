package server

import (
	"fmt"
	"html/template"
	"math"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

// FormatBytes renders bytes in human-readable IEC/SI units (e.g. "12.4 GB", "21.8 TB").
func FormatBytes(b uint64) string {
	switch {
	case b >= 1_000_000_000_000:
		return fmt.Sprintf("%.1f TB", float64(b)/1_000_000_000_000)
	case b >= 1_000_000_000:
		return fmt.Sprintf("%.1f GB", float64(b)/1_000_000_000)
	case b >= 1_000_000:
		return fmt.Sprintf("%.1f MB", float64(b)/1_000_000)
	case b >= 1_000:
		return fmt.Sprintf("%.1f KB", float64(b)/1_000)
	default:
		return fmt.Sprintf("%d B", b)
	}
}

// FormatRate renders bytes/sec as a compact throughput string.
func FormatRate(bps uint64) string {
	return FormatBytes(bps) + "/s"
}

// FormatUptime renders seconds as e.g. "14d 5h" or "3h 12m".
func FormatUptime(sec uint64) string {
	if sec == 0 {
		return "—"
	}
	d := time.Duration(sec) * time.Second
	days := int(d / (24 * time.Hour))
	hours := int((d % (24 * time.Hour)) / time.Hour)
	mins := int((d % time.Hour) / time.Minute)
	if days > 0 {
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}

// RenderSparklineSVG renders a compact inline SVG sparkline for the /hosts cards.
func RenderSparklineSVG(values []float64, maxFixed float64, strokeVar string) template.HTML {
	const w, h = 120.0, 28.0
	if len(values) == 0 {
		return template.HTML(fmt.Sprintf(`<svg class="sparkline" viewBox="0 0 %.0f %.0f" width="120" height="28"></svg>`, w, h))
	}
	maxVal := maxFixed
	if maxVal <= 0 {
		for _, v := range values {
			if v > maxVal {
				maxVal = v
			}
		}
	}
	if maxVal <= 0 {
		maxVal = 1
	}

	var pts []string
	n := len(values)
	for i, v := range values {
		x := 0.0
		if n > 1 {
			x = (float64(i) / float64(n-1)) * w
		} else {
			x = w / 2
		}
		clamped := math.Max(0, math.Min(v, maxVal))
		y := h - 2 - (clamped/maxVal)*(h-4)
		pts = append(pts, fmt.Sprintf("%.1f,%.1f", x, y))
	}
	poly := strings.Join(pts, " ")
	area := fmt.Sprintf("0,%.1f %s %.1f,%.1f", h, poly, w, h)
	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="sparkline" viewBox="0 0 %.0f %.0f" width="120" height="28">`, w, h)
	fmt.Fprintf(&b, `<polygon points="%s" fill="%s" fill-opacity="0.16"/>`, area, strokeVar)
	fmt.Fprintf(&b, `<polyline points="%s" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>`, poly, strokeVar)
	b.WriteString(`</svg>`)
	return template.HTML(b.String())
}

// ChartPoint holds one x/y timestamped value for a drill-down SVG chart.
type ChartPoint struct {
	TS   int64
	Val  float64
	Val2 float64 // optional secondary series (e.g. TX vs RX, Write vs Read, Max vs Avg)
}

// ChartEventMarker marks a cutover/lineage event (e.g. h002 -> h004) on a chart.
type ChartEventMarker struct {
	TS    int64
	Label string
}

// RenderHistoryChartSVG renders a full-width responsive SVG chart with axis labels,
// optional secondary series, and vertical dashed markers for host cutover events.
func RenderHistoryChartSVG(points []ChartPoint, sinceTS, untilTS int64, maxFixed float64, unit string, color1, color2 string, events []store.Event) template.HTML {
	const w, h = 640.0, 145.0
	const padL, padR, padT, padB = 48.0, 12.0, 14.0, 24.0
	plotW := w - padL - padR
	plotH := h - padT - padB

	if len(points) == 0 {
		return template.HTML(fmt.Sprintf(
			`<svg class="history-chart" viewBox="0 0 %.0f %.0f"><text x="%.0f" y="%.0f" fill="var(--muted)" font-size="12" text-anchor="middle">No samples in selected window</text></svg>`,
			w, h, w/2, h/2,
		))
	}

	if untilTS <= sinceTS {
		sinceTS = points[0].TS
		untilTS = points[len(points)-1].TS
		if untilTS <= sinceTS {
			untilTS = sinceTS + 60
		}
	}
	span := float64(untilTS - sinceTS)

	maxVal := maxFixed
	if maxVal <= 0 {
		for _, p := range points {
			if p.Val > maxVal {
				maxVal = p.Val
			}
			if p.Val2 > maxVal {
				maxVal = p.Val2
			}
		}
	}
	if maxVal <= 0 {
		maxVal = 1
	}

	xOf := func(ts int64) float64 {
		ratio := float64(ts-sinceTS) / span
		if ratio < 0 {
			ratio = 0
		}
		if ratio > 1 {
			ratio = 1
		}
		return padL + ratio*plotW
	}
	yOf := func(v float64) float64 {
		clamped := math.Max(0, math.Min(v, maxVal))
		return padT + plotH - (clamped/maxVal)*plotH
	}

	var pts1, pts2 []string
	hasVal2 := false
	for _, p := range points {
		x := xOf(p.TS)
		pts1 = append(pts1, fmt.Sprintf("%.1f,%.1f", x, yOf(p.Val)))
		if p.Val2 > 0 {
			hasVal2 = true
		}
		pts2 = append(pts2, fmt.Sprintf("%.1f,%.1f", x, yOf(p.Val2)))
	}

	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="history-chart" viewBox="0 0 %.0f %.0f">`, w, h)

	// Horizontal grid lines (0%, 50%, 100%)
	for _, frac := range []float64{0, 0.5, 1.0} {
		y := padT + plotH*(1.0-frac)
		val := maxVal * frac
		fmt.Fprintf(&b, `<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="var(--border)" stroke-dasharray="3,3" stroke-width="1"/>`, padL, y, w-padR, y)
		fmt.Fprintf(&b, `<text x="%.1f" y="%.1f" fill="var(--muted)" font-size="10" text-anchor="end">%s</text>`, padL-5, y+3, formatAxisVal(val, unit))
	}

	// Area + polyline for series 1
	firstX := xOf(points[0].TS)
	lastX := xOf(points[len(points)-1].TS)
	baseY := padT + plotH
	poly1 := strings.Join(pts1, " ")
	area1 := fmt.Sprintf("%.1f,%.1f %s %.1f,%.1f", firstX, baseY, poly1, lastX, baseY)
	fmt.Fprintf(&b, `<polygon points="%s" fill="%s" fill-opacity="0.16"/>`, area1, color1)
	fmt.Fprintf(&b, `<polyline points="%s" fill="none" stroke="%s" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>`, poly1, color1)

	// Optional series 2
	if hasVal2 && color2 != "" {
		poly2 := strings.Join(pts2, " ")
		fmt.Fprintf(&b, `<polyline points="%s" fill="none" stroke="%s" stroke-width="1.5" stroke-dasharray="3,2" stroke-linecap="round" stroke-linejoin="round"/>`, poly2, color2)
	}

	// Host replacement / lineage event markers
	for _, ev := range events {
		if ev.TS >= sinceTS && ev.TS <= untilTS {
			x := xOf(ev.TS)
			fmt.Fprintf(&b, `<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="var(--amber)" stroke-dasharray="4,3" stroke-width="1.5"/>`, x, padT, x, baseY)
			fmt.Fprintf(&b, `<text x="%.1f" y="%.1f" fill="var(--amber)" font-size="10" text-anchor="middle">%s</text>`, x, padT+10, template.HTMLEscapeString(ev.Detail))
		}
	}

	// Time axis labels (start, middle, end)
	midTS := sinceTS + (untilTS-sinceTS)/2
	timeLayout := "15:04"
	if untilTS-sinceTS > 48*3600 {
		timeLayout = "Jan 02"
	}
	for _, item := range []struct {
		ts     int64
		anchor string
	}{
		{sinceTS, "start"},
		{midTS, "middle"},
		{untilTS, "end"},
	} {
		x := xOf(item.ts)
		lbl := time.Unix(item.ts, 0).UTC().Format(timeLayout)
		fmt.Fprintf(&b, `<text x="%.1f" y="%.1f" fill="var(--muted)" font-size="10" text-anchor="%s">%s</text>`, x, h-5, item.anchor, lbl)
	}

	b.WriteString(`</svg>`)
	return template.HTML(b.String())
}

func formatAxisVal(v float64, unit string) string {
	switch unit {
	case "%":
		return fmt.Sprintf("%.0f%%", v)
	case "°C":
		return fmt.Sprintf("%.0f°C", v)
	case "B":
		return FormatBytes(uint64(v))
	case "B/s":
		return FormatRate(uint64(v))
	default:
		return fmt.Sprintf("%.1f", v)
	}
}
