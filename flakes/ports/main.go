package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// --- Styles ---

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("12")).
			PaddingBottom(1)

	activeStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("10")).
			Bold(true)

	errorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("9"))

	dimStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("8"))

	selectedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("14")).
			Bold(true)

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("8")).
			PaddingTop(1)

	statusBarStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("11")).
			PaddingTop(1)
)

// --- Types ---

type PortStatus int

const (
	PortInactive PortStatus = iota
	PortForwarding
	PortActive
	PortFailed
)

type PortEntry struct {
	Port        int
	Process     string // remote process name if discovered
	Status      PortStatus
	Error       string
	LocalPort   int // local port (usually same as remote)
	Discovered  bool
	PID         int    // remote PID, 0 if unknown
	Cwd         string // remote working dir of process, "" if unknown
}

type ViewMode int

const (
	ViewNormal ViewMode = iota
	ViewAddPort
)

type model struct {
	host        string
	controlPath string
	ports       []PortEntry
	cursor      int
	connected   bool
	connecting  bool
	err         error
	statusMsg   string
	width       int
	height      int
	viewMode    ViewMode
	textInput   textinput.Model
	quitting    bool
	scrollOffset int
}

// --- Messages ---

type connectResultMsg struct{ err error }
type discoverResultMsg struct {
	ports []PortEntry
	err   error
}
type forwardResultMsg struct {
	port  int
	err   error
}
type cancelResultMsg struct {
	port  int
	err   error
}
type statusMsg string
type clearStatusMsg struct{}
type tickMsg struct{}

// --- SSH helpers ---

func controlSocketPath(host string) string {
	dir := os.TempDir()
	return filepath.Join(dir, fmt.Sprintf("ports-ctrl-%s-%d", host, os.Getpid()))
}

func sshConnect(host, controlPath string) tea.Cmd {
	return func() tea.Msg {
		// Start a ControlMaster connection in the background
		cmd := exec.Command("ssh",
			"-M",                   // ControlMaster
			"-S", controlPath,      // ControlPath
			"-f",                   // background after auth
			"-N",                   // no remote command
			"-o", "ControlPersist=yes",
			"-o", "ServerAliveInterval=15",
			"-o", "ServerAliveCountMax=3",
			"-o", "ConnectTimeout=10",
			host,
		)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		err := cmd.Run()
		if err != nil {
			return connectResultMsg{err: fmt.Errorf("ssh connect failed: %w", err)}
		}
		return connectResultMsg{err: nil}
	}
}

func sshDiscover(host, controlPath string) tea.Cmd {
	return func() tea.Msg {
		// Run ss on the remote to discover listening TCP ports
		cmd := exec.Command("ssh",
			"-S", controlPath,
			"-o", "ConnectTimeout=5",
			host,
			"ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo DISCOVERY_FAILED",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return discoverResultMsg{err: fmt.Errorf("discovery failed: %w", err)}
		}

		output := string(out)
		if strings.Contains(output, "DISCOVERY_FAILED") {
			return discoverResultMsg{err: fmt.Errorf("neither ss nor netstat available on remote")}
		}

		ports := parseListeningPorts(output)

		// Resolve working directory for each PID via /proc on remote.
		// Single ssh round-trip; gracefully degrades if /proc isn't available
		// (non-Linux remote) or the process is owned by another user.
		pidSet := map[int]bool{}
		for _, p := range ports {
			if p.PID > 0 {
				pidSet[p.PID] = true
			}
		}
		if len(pidSet) > 0 {
			pids := make([]string, 0, len(pidSet))
			for pid := range pidSet {
				pids = append(pids, strconv.Itoa(pid))
			}
			// Build: for pid in 1 2 3; do printf '%s\t' "$pid"; readlink /proc/$pid/cwd 2>/dev/null || echo; done
			script := fmt.Sprintf(
				`for pid in %s; do printf '%%s\t' "$pid"; readlink /proc/$pid/cwd 2>/dev/null || echo; done`,
				strings.Join(pids, " "),
			)
			cwdCmd := exec.Command("ssh",
				"-S", controlPath,
				"-o", "ConnectTimeout=5",
				host,
				script,
			)
			if cwdOut, cwdErr := cwdCmd.Output(); cwdErr == nil {
				cwdMap := map[int]string{}
				for _, line := range strings.Split(string(cwdOut), "\n") {
					parts := strings.SplitN(line, "\t", 2)
					if len(parts) != 2 {
						continue
					}
					pid, err := strconv.Atoi(parts[0])
					if err != nil {
						continue
					}
					cwdMap[pid] = strings.TrimSpace(parts[1])
				}
				for i := range ports {
					if cwd, ok := cwdMap[ports[i].PID]; ok {
						ports[i].Cwd = cwd
					}
				}
			}
		}

		// Re-sort now that cwd is populated, so groups are adjacent.
		sortPortsGrouped(ports)
		return discoverResultMsg{ports: ports, err: nil}
	}
}

func parseListeningPorts(output string) []PortEntry {
	type seenEntry struct {
		proc string
		pid  int
	}
	seen := make(map[int]seenEntry)
	// Match port from ss output: patterns like *:8080, 0.0.0.0:3000, [::]:5432, 127.0.0.1:9090
	portRe := regexp.MustCompile(`(?:[\d.*]+|\[?::[\].]?):(\d+)\s`)
	// Match process name and PID from ss -p: users:(("name",pid=12345,fd=20))
	procRe := regexp.MustCompile(`users:\(\("([^"]+)",pid=(\d+)`)

	lines := strings.Split(output, "\n")
	for _, line := range lines {
		if !strings.Contains(line, "LISTEN") {
			continue
		}
		matches := portRe.FindAllStringSubmatch(line, -1)
		if len(matches) == 0 {
			continue
		}
		// Take the first port match (local address)
		portStr := matches[0][1]
		port, err := strconv.Atoi(portStr)
		if err != nil || port == 0 {
			continue
		}

		proc := ""
		pid := 0
		procMatch := procRe.FindStringSubmatch(line)
		if len(procMatch) > 2 {
			proc = procMatch[1]
			pid, _ = strconv.Atoi(procMatch[2])
		}
		if _, exists := seen[port]; !exists {
			seen[port] = seenEntry{proc: proc, pid: pid}
		}
	}

	var entries []PortEntry
	for port, info := range seen {
		entries = append(entries, PortEntry{
			Port:       port,
			Process:    info.proc,
			PID:        info.pid,
			Status:     PortInactive,
			LocalPort:  port,
			Discovered: true,
		})
	}
	sortPortsGrouped(entries)
	return entries
}

// sortPortsGrouped orders entries so that ports sharing a working directory
// are adjacent. Groups are ordered alphabetically by cwd; ports without a
// known cwd come last. Within a group, ports are sorted numerically.
func sortPortsGrouped(entries []PortEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		ci, cj := entries[i].Cwd, entries[j].Cwd
		// empty cwd sorts last
		if (ci == "") != (cj == "") {
			return ci != ""
		}
		if ci != cj {
			return ci < cj
		}
		return entries[i].Port < entries[j].Port
	})
}

func sshForward(host, controlPath string, localPort, remotePort int) tea.Cmd {
	return func() tea.Msg {
		forwardSpec := fmt.Sprintf("%d:localhost:%d", localPort, remotePort)
		cmd := exec.Command("ssh",
			"-S", controlPath,
			"-O", "forward",
			"-L", forwardSpec,
			host,
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return forwardResultMsg{
				port: remotePort,
				err:  fmt.Errorf("forward failed: %w (%s)", err, strings.TrimSpace(string(out))),
			}
		}
		return forwardResultMsg{port: remotePort, err: nil}
	}
}

func sshCancelForward(host, controlPath string, localPort, remotePort int) tea.Cmd {
	return func() tea.Msg {
		forwardSpec := fmt.Sprintf("%d:localhost:%d", localPort, remotePort)
		cmd := exec.Command("ssh",
			"-S", controlPath,
			"-O", "cancel",
			"-L", forwardSpec,
			host,
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return cancelResultMsg{
				port: remotePort,
				err:  fmt.Errorf("cancel failed: %w (%s)", err, strings.TrimSpace(string(out))),
			}
		}
		return cancelResultMsg{port: remotePort, err: nil}
	}
}

func sshCleanup(controlPath string) {
	cmd := exec.Command("ssh", "-S", controlPath, "-O", "exit", "dummy")
	_ = cmd.Run()
	_ = os.Remove(controlPath)
}

func clearStatusAfter(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(time.Time) tea.Msg {
		return clearStatusMsg{}
	})
}

// --- Model ---

func initialModel(host string) model {
	ti := textinput.New()
	ti.Placeholder = "8080"
	ti.CharLimit = 5
	ti.Width = 10

	cp := controlSocketPath(host)
	return model{
		host:        host,
		controlPath: cp,
		ports:       []PortEntry{},
		cursor:      0,
		textInput:   ti,
	}
}

func (m model) Init() tea.Cmd {
	m.connecting = true
	return sshConnect(m.host, m.controlPath)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.ensureVisible()
		return m, nil

	case connectResultMsg:
		m.connecting = false
		if msg.err != nil {
			m.err = msg.err
			return m, tea.Quit
		}
		m.connected = true
		m.statusMsg = "Connected! Discovering ports..."
		return m, sshDiscover(m.host, m.controlPath)

	case discoverResultMsg:
		if msg.err != nil {
			m.statusMsg = errorStyle.Render("Discovery: " + msg.err.Error() + " (add ports manually with 'a')")
		} else {
			m.ports = msg.ports
			if m.cursor >= len(m.ports) {
				m.cursor = len(m.ports) - 1
			}
			if m.cursor < 0 {
				m.cursor = 0
			}
			m.ensureVisible()
			m.statusMsg = fmt.Sprintf("Found %d listening ports", len(msg.ports))
		}
		return m, clearStatusAfter(5 * time.Second)

	case forwardResultMsg:
		for i, p := range m.ports {
			if p.Port == msg.port {
				if msg.err != nil {
					m.ports[i].Status = PortFailed
					m.ports[i].Error = msg.err.Error()
					m.statusMsg = errorStyle.Render(fmt.Sprintf("Port %d: %s", msg.port, msg.err.Error()))
				} else {
					m.ports[i].Status = PortActive
					m.ports[i].Error = ""
					m.statusMsg = fmt.Sprintf("Forwarding localhost:%d -> %s:%d", m.ports[i].LocalPort, m.host, msg.port)
				}
				break
			}
		}
		return m, clearStatusAfter(5 * time.Second)

	case cancelResultMsg:
		for i, p := range m.ports {
			if p.Port == msg.port {
				if msg.err != nil {
					m.statusMsg = errorStyle.Render(fmt.Sprintf("Cancel port %d: %s", msg.port, msg.err.Error()))
				} else {
					m.ports[i].Status = PortInactive
					m.ports[i].Error = ""
					m.statusMsg = fmt.Sprintf("Stopped forwarding port %d", msg.port)
				}
				break
			}
		}
		return m, clearStatusAfter(5 * time.Second)

	case clearStatusMsg:
		m.statusMsg = ""
		return m, nil

	case tea.KeyMsg:
		// Handle text input mode
		if m.viewMode == ViewAddPort {
			switch msg.String() {
			case "enter":
				val := strings.TrimSpace(m.textInput.Value())
				m.viewMode = ViewNormal
				m.textInput.Blur()
				m.textInput.SetValue("")
				if val == "" {
					return m, nil
				}
				port, err := strconv.Atoi(val)
				if err != nil || port < 1 || port > 65535 {
					m.statusMsg = errorStyle.Render("Invalid port: " + val)
					return m, clearStatusAfter(3 * time.Second)
				}
				// Check if already exists
				for _, p := range m.ports {
					if p.Port == port {
						m.statusMsg = errorStyle.Render(fmt.Sprintf("Port %d already in list", port))
						return m, clearStatusAfter(3 * time.Second)
					}
				}
				entry := PortEntry{
					Port:       port,
					LocalPort:  port,
					Status:     PortInactive,
					Discovered: false,
				}
				m.ports = append(m.ports, entry)
				sortPortsGrouped(m.ports)
				// Move cursor to the new entry
				for i, p := range m.ports {
					if p.Port == port {
						m.cursor = i
						break
					}
				}
				m.ensureVisible()
				m.statusMsg = fmt.Sprintf("Added port %d", port)
				return m, clearStatusAfter(3 * time.Second)
			case "esc":
				m.viewMode = ViewNormal
				m.textInput.Blur()
				m.textInput.SetValue("")
				return m, nil
			default:
				var cmd tea.Cmd
				m.textInput, cmd = m.textInput.Update(msg)
				return m, cmd
			}
		}

		// Normal mode keys
		switch msg.String() {
		case "q", "ctrl+c":
			m.quitting = true
			return m, tea.Quit

		case "up", "k":
			m.moveCursor(0, -1)
			return m, nil

		case "down", "j":
			m.moveCursor(0, 1)
			return m, nil

		case "left", "h":
			m.moveCursor(-1, 0)
			return m, nil

		case "right", "l":
			m.moveCursor(1, 0)
			return m, nil

		case "home", "g":
			if len(m.ports) > 0 {
				m.cursor = 0
				m.ensureVisible()
			}
			return m, nil

		case "end", "G":
			if len(m.ports) > 0 {
				m.cursor = len(m.ports) - 1
				m.ensureVisible()
			}
			return m, nil

		case " ", "enter":
			if len(m.ports) == 0 {
				return m, nil
			}
			p := m.ports[m.cursor]
			switch p.Status {
			case PortInactive, PortFailed:
				m.ports[m.cursor].Status = PortForwarding
				m.ports[m.cursor].Error = ""
				return m, sshForward(m.host, m.controlPath, p.LocalPort, p.Port)
			case PortActive:
				return m, sshCancelForward(m.host, m.controlPath, p.LocalPort, p.Port)
			}
			return m, nil

		case "a":
			m.viewMode = ViewAddPort
			m.textInput.Focus()
			return m, m.textInput.Cursor.BlinkCmd()

		case "d":
			if len(m.ports) == 0 {
				return m, nil
			}
			p := m.ports[m.cursor]
			var cmd tea.Cmd
			if p.Status == PortActive {
				cmd = sshCancelForward(m.host, m.controlPath, p.LocalPort, p.Port)
			}
			m.ports = append(m.ports[:m.cursor], m.ports[m.cursor+1:]...)
			if m.cursor >= len(m.ports) && m.cursor > 0 {
				m.cursor--
			}
			m.ensureVisible()
			return m, cmd

		case "r":
			m.statusMsg = "Refreshing..."
			return m, sshDiscover(m.host, m.controlPath)

		case "f":
			// Forward all inactive/failed ports
			var cmds []tea.Cmd
			for i, p := range m.ports {
				if p.Status == PortInactive || p.Status == PortFailed {
					m.ports[i].Status = PortForwarding
					m.ports[i].Error = ""
					cmds = append(cmds, sshForward(m.host, m.controlPath, p.LocalPort, p.Port))
				}
			}
			if len(cmds) > 0 {
				m.statusMsg = fmt.Sprintf("Forwarding %d ports...", len(cmds))
				return m, tea.Batch(cmds...)
			}
			return m, nil

		case "s":
			// Stop all active forwards
			var cmds []tea.Cmd
			for _, p := range m.ports {
				if p.Status == PortActive {
					cmds = append(cmds, sshCancelForward(m.host, m.controlPath, p.LocalPort, p.Port))
				}
			}
			if len(cmds) > 0 {
				m.statusMsg = fmt.Sprintf("Stopping %d forwards...", len(cmds))
				return m, tea.Batch(cmds...)
			}
			return m, nil
		}
	}
	return m, nil
}

// --- Grid layout ---
//
// Ports are rendered in a column-major grid: column 0 fills top-to-bottom
// first, then column 1, etc. Groups of ports sharing a working directory
// are kept contiguous in the flat layout, separated by a "spacer" sentinel
// (port index = -1) so blank lines naturally appear between groups within
// the same column.

const (
	cellPadding    = 2 // spaces between cells horizontally
	procNameMaxLen = 12
)

// layoutSlot describes one position in the flattened grid sequence.
// portIdx == -1 means "spacer" (renders as blank cell, not selectable).
type layoutSlot struct {
	portIdx int
}

// buildLayout returns the flat slot sequence used for column-major rendering
// and for cursor navigation. Spacers separate groups of ports sharing a cwd.
func (m model) buildLayout() []layoutSlot {
	slots := make([]layoutSlot, 0, len(m.ports)+8)
	prevCwd := ""
	prevHasGroup := false
	for i, p := range m.ports {
		hasGroup := p.Cwd != ""
		if i > 0 {
			// Insert spacer when cwd changes between two grouped ports,
			// or when transitioning into/out of the ungrouped bucket.
			if hasGroup != prevHasGroup || (hasGroup && p.Cwd != prevCwd) {
				slots = append(slots, layoutSlot{portIdx: -1})
			}
		}
		slots = append(slots, layoutSlot{portIdx: i})
		prevCwd = p.Cwd
		prevHasGroup = hasGroup
	}
	return slots
}

// gridGeometry computes rows-per-column and number of columns based on
// terminal size, the number of slots, and the cell width.
func (m model) gridGeometry(slotCount int) (rows, cols, cellWidth int) {
	cellWidth = m.cellWidth()
	rows = m.gridRows()
	if rows <= 0 {
		rows = 1
	}
	if cellWidth <= 0 {
		cellWidth = 20
	}
	maxCols := 1
	if m.width > 0 {
		// 2-char left margin matches existing layout
		maxCols = (m.width - 2) / cellWidth
		if maxCols < 1 {
			maxCols = 1
		}
	}
	// Number of columns actually needed for slotCount items at `rows` per col.
	needed := (slotCount + rows - 1) / rows
	cols = needed
	if cols > maxCols {
		cols = maxCols
	}
	if cols < 1 {
		cols = 1
	}
	return rows, cols, cellWidth
}

// gridRows returns how many rows of port cells fit vertically.
func (m model) gridRows() int {
	// Reserve: title(2, PaddingBottom adds one) + blank-after-title(0)
	//        + detail(1) + scroll-indicator(1, reserved even if absent)
	//        + add-port(0-2) + status(0-2, PaddingTop adds one) + help(2)
	overhead := 2 /*title*/ + 1 /*detail*/ + 1 /*scroll-indicator slack*/ + 2 /*help*/
	if m.viewMode == ViewAddPort {
		overhead += 2
	}
	if m.statusMsg != "" {
		overhead += 2
	}
	avail := m.height - overhead
	if avail < 3 {
		avail = 3
	}
	return avail
}

// cellWidth returns the width (in cells / runes) of one grid cell. Each cell
// is "> [X] PPPPP  procname    " padded to a uniform width.
func (m model) cellWidth() int {
	// "> " (2) + "[X] " (4) + "PPPPP" (5) + "  " (2) + procname(<=procNameMaxLen) + padding
	w := 2 + 4 + 5 + 2 + procNameMaxLen + cellPadding
	return w
}

// slotForPort finds the layout slot index for a given port index.
func slotForPort(slots []layoutSlot, portIdx int) int {
	for i, s := range slots {
		if s.portIdx == portIdx {
			return i
		}
	}
	return -1
}

// gridPos returns the (col, row) of a slot index in column-major order.
func gridPos(slotIdx, rows int) (col, row int) {
	if rows <= 0 {
		return 0, 0
	}
	return slotIdx / rows, slotIdx % rows
}

// slotAt returns the slot index for a (col, row) in column-major order.
func slotAt(col, row, rows int) int {
	return col*rows + row
}

// moveCursor moves the cursor by (dx, dy) cells in the visual grid,
// skipping spacer slots.
func (m *model) moveCursor(dx, dy int) {
	if len(m.ports) == 0 {
		return
	}
	slots := m.buildLayout()
	rows, cols, _ := m.gridGeometry(len(slots))
	curSlot := slotForPort(slots, m.cursor)
	if curSlot < 0 {
		curSlot = 0
	}
	col, row := gridPos(curSlot, rows)
	totalCols := (len(slots) + rows - 1) / rows
	_ = cols // visible cols, not used for nav bound (we allow scrolling)

	// Try to step; if we land on a spacer or out-of-bounds, keep stepping
	// in the same direction until we hit a real port or run out of grid.
	for step := 0; step < rows*totalCols; step++ {
		row += dy
		col += dx
		if row < 0 || row >= rows || col < 0 || col >= totalCols {
			return // can't move further
		}
		idx := slotAt(col, row, rows)
		if idx < 0 || idx >= len(slots) {
			return
		}
		if slots[idx].portIdx >= 0 {
			m.cursor = slots[idx].portIdx
			m.ensureVisible()
			return
		}
		// landed on a spacer; continue in same direction
	}
}

// renderCell returns a fixed-width string for one grid cell. Spacer slots
// (portIdx == -1) render as a blank cell of the same width.
func (m model) renderCell(slots []layoutSlot, slotIdx, cellWidth int) string {
	if slotIdx < 0 || slotIdx >= len(slots) {
		return strings.Repeat(" ", cellWidth)
	}
	slot := slots[slotIdx]
	if slot.portIdx < 0 {
		return strings.Repeat(" ", cellWidth)
	}
	p := m.ports[slot.portIdx]
	selected := slot.portIdx == m.cursor

	cursor := "  "
	if selected {
		cursor = selectedStyle.Render("> ")
	}

	var status string
	switch p.Status {
	case PortInactive:
		status = dimStyle.Render("[ ]")
	case PortForwarding:
		status = lipgloss.NewStyle().Foreground(lipgloss.Color("11")).Render("[~]")
	case PortActive:
		status = activeStyle.Render("[*]")
	case PortFailed:
		status = errorStyle.Render("[!]")
	}

	portStr := fmt.Sprintf("%5d", p.Port)
	if selected {
		portStr = selectedStyle.Render(portStr)
	}

	proc := p.Process
	if proc == "" && !p.Discovered {
		proc = "(manual)"
	}
	if len(proc) > procNameMaxLen {
		proc = proc[:procNameMaxLen-1] + "…"
	}
	procPadded := fmt.Sprintf("%-*s", procNameMaxLen, proc)
	procRendered := dimStyle.Render(procPadded)

	// "> [X] PPPPP  procname  "
	cell := fmt.Sprintf("%s%s %s  %s%s", cursor, status, portStr, procRendered, strings.Repeat(" ", cellPadding))
	// Note: lipgloss styles add invisible ANSI codes; visible width is
	// constant by construction (fixed-width fields). Don't trim.
	return cell
}

// renderDetail returns a one-line description of the currently selected port
// (status, forward target, error, cwd). Empty string if nothing meaningful.
func (m model) renderDetail() string {
	if len(m.ports) == 0 || m.cursor < 0 || m.cursor >= len(m.ports) {
		return " "
	}
	p := m.ports[m.cursor]
	parts := []string{}
	if p.Status == PortActive {
		parts = append(parts, activeStyle.Render(fmt.Sprintf("-> localhost:%d", p.LocalPort)))
	}
	if p.Cwd != "" {
		parts = append(parts, dimStyle.Render("cwd: "+p.Cwd))
	}
	if p.Error != "" {
		parts = append(parts, errorStyle.Render(p.Error))
	}
	if len(parts) == 0 {
		return " "
	}
	return strings.Join(parts, "  ")
}

// ensureVisible adjusts m.scrollOffset (measured in columns) so the cursor's
// column is within the visible window.
func (m *model) ensureVisible() {
	if len(m.ports) == 0 {
		m.scrollOffset = 0
		return
	}
	slots := m.buildLayout()
	rows, cols, _ := m.gridGeometry(len(slots))
	curSlot := slotForPort(slots, m.cursor)
	if curSlot < 0 {
		return
	}
	col, _ := gridPos(curSlot, rows)
	if col < m.scrollOffset {
		m.scrollOffset = col
	}
	if col >= m.scrollOffset+cols {
		m.scrollOffset = col - cols + 1
	}
	if m.scrollOffset < 0 {
		m.scrollOffset = 0
	}
}

func (m model) View() string {
	if m.quitting {
		return ""
	}

	if m.connecting {
		return titleStyle.Render(fmt.Sprintf("  Connecting to %s...", m.host)) + "\n"
	}

	if m.err != nil {
		return errorStyle.Render(fmt.Sprintf("  Error: %s", m.err)) + "\n"
	}

	var b strings.Builder

	// Title
	activeCount := 0
	for _, p := range m.ports {
		if p.Status == PortActive {
			activeCount++
		}
	}
	title := fmt.Sprintf("  ports  %s", m.host)
	if activeCount > 0 {
		title += activeStyle.Render(fmt.Sprintf("  [%d active]", activeCount))
	}
	b.WriteString(titleStyle.Render(title))
	b.WriteString("\n")

	// Port grid
	if len(m.ports) == 0 {
		b.WriteString(dimStyle.Render("  No ports found. Press 'a' to add one manually."))
		b.WriteString("\n")
		// Empty detail line so layout stays stable.
		b.WriteString("\n")
	} else {
		slots := m.buildLayout()
		rows, cols, cellWidth := m.gridGeometry(len(slots))
		totalCols := (len(slots) + rows - 1) / rows

		// Clamp scroll offset.
		if m.scrollOffset+cols > totalCols {
			m.scrollOffset = totalCols - cols
		}
		if m.scrollOffset < 0 {
			m.scrollOffset = 0
		}

		// Render row-by-row, picking the right column from column-major layout.
		for r := 0; r < rows; r++ {
			var rowBuf strings.Builder
			rowBuf.WriteString("  ") // left margin
			for cOffset := 0; cOffset < cols; cOffset++ {
				c := m.scrollOffset + cOffset
				if c >= totalCols {
					break
				}
				idx := slotAt(c, r, rows)
				cell := m.renderCell(slots, idx, cellWidth)
				rowBuf.WriteString(cell)
			}
			b.WriteString(strings.TrimRight(rowBuf.String(), " "))
			b.WriteString("\n")
		}

		// Scroll indicators
		if m.scrollOffset > 0 || m.scrollOffset+cols < totalCols {
			var parts []string
			if m.scrollOffset > 0 {
				parts = append(parts, fmt.Sprintf("< %d cols", m.scrollOffset))
			}
			if m.scrollOffset+cols < totalCols {
				parts = append(parts, fmt.Sprintf("%d cols >", totalCols-m.scrollOffset-cols))
			}
			b.WriteString(dimStyle.Render("  " + strings.Join(parts, "  ")))
			b.WriteString("\n")
		}

		// Detail line for selected port (always rendered for layout stability).
		b.WriteString("  ")
		b.WriteString(m.renderDetail())
		b.WriteString("\n")
	}

	// Add port input
	if m.viewMode == ViewAddPort {
		b.WriteString("\n")
		b.WriteString(fmt.Sprintf("  Add port: %s", m.textInput.View()))
		b.WriteString("\n")
	}

	// Status bar
	if m.statusMsg != "" {
		b.WriteString(statusBarStyle.Render("  " + m.statusMsg))
		b.WriteString("\n")
	}

	// Help
	help := []string{
		"hjkl/arrows: move",
		"space/enter: toggle",
		"a: add",
		"d: remove",
		"r: refresh",
		"f: forward all",
		"s: stop all",
		"q: quit",
	}
	b.WriteString(helpStyle.Render("  " + strings.Join(help, "  |  ")))
	b.WriteString("\n")

	return b.String()
}

// --- Main ---

func usage() {
	fmt.Fprintf(os.Stderr, `ports - SSH port forwarding TUI

Usage:
  ports <host>             Start TUI, discover ports on <host>
  ports <host> <port>...   Forward specified ports immediately and start TUI

Examples:
  ports myserver
  ports dev 3000 5432 8080

The tool establishes an SSH ControlMaster connection and lets you
interactively toggle port forwards. Ports are discovered automatically
via 'ss' on the remote host, or can be added manually.
`)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	host := os.Args[1]
	if host == "-h" || host == "--help" {
		usage()
	}

	m := initialModel(host)

	// Parse any extra port args to pre-add and auto-forward
	var autoForwardPorts []int
	for _, arg := range os.Args[2:] {
		port, err := strconv.Atoi(arg)
		if err != nil || port < 1 || port > 65535 {
			fmt.Fprintf(os.Stderr, "Invalid port: %s\n", arg)
			os.Exit(1)
		}
		autoForwardPorts = append(autoForwardPorts, port)
	}

	// Add pre-specified ports
	for _, port := range autoForwardPorts {
		m.ports = append(m.ports, PortEntry{
			Port:       port,
			LocalPort:  port,
			Status:     PortInactive,
			Discovered: false,
		})
	}

	// Trap signals to clean up the control socket
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		sshCleanup(m.controlPath)
		os.Exit(0)
	}()

	p := tea.NewProgram(m, tea.WithAltScreen())

	finalModel, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
	}

	// Cleanup
	if fm, ok := finalModel.(model); ok {
		sshCleanup(fm.controlPath)
	} else {
		sshCleanup(m.controlPath)
	}
}
