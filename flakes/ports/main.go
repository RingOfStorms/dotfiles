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
		return discoverResultMsg{ports: ports, err: nil}
	}
}

func parseListeningPorts(output string) []PortEntry {
	seen := make(map[int]string)
	// Match port from ss output: patterns like *:8080, 0.0.0.0:3000, [::]:5432, 127.0.0.1:9090
	portRe := regexp.MustCompile(`(?:[\d.*]+|\[?::[\].]?):(\d+)\s`)
	// Match process name from ss -p: users:(("name",...))
	procRe := regexp.MustCompile(`users:\(\("([^"]+)"`)

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
		procMatch := procRe.FindStringSubmatch(line)
		if len(procMatch) > 1 {
			proc = procMatch[1]
		}
		if _, exists := seen[port]; !exists {
			seen[port] = proc
		}
	}

	var entries []PortEntry
	for port, proc := range seen {
		entries = append(entries, PortEntry{
			Port:       port,
			Process:    proc,
			Status:     PortInactive,
			LocalPort:  port,
			Discovered: true,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Port < entries[j].Port
	})
	return entries
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
				sort.Slice(m.ports, func(i, j int) bool {
					return m.ports[i].Port < m.ports[j].Port
				})
				// Move cursor to the new entry
				for i, p := range m.ports {
					if p.Port == port {
						m.cursor = i
						break
					}
				}
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
			if m.cursor > 0 {
				m.cursor--
			}
			m.ensureVisible()
			return m, nil

		case "down", "j":
			if m.cursor < len(m.ports)-1 {
				m.cursor++
			}
			m.ensureVisible()
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

func (m *model) ensureVisible() {
	maxVisible := m.maxVisiblePorts()
	if maxVisible <= 0 {
		return
	}
	if m.cursor < m.scrollOffset {
		m.scrollOffset = m.cursor
	}
	if m.cursor >= m.scrollOffset+maxVisible {
		m.scrollOffset = m.cursor - maxVisible + 1
	}
}

func (m model) maxVisiblePorts() int {
	// Reserve lines for: title(2) + status(2) + help(~6) + add-port(2) + padding
	overhead := 14
	avail := m.height - overhead
	if avail < 3 {
		avail = 3
	}
	return avail
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

	// Port list
	if len(m.ports) == 0 {
		b.WriteString(dimStyle.Render("  No ports found. Press 'a' to add one manually."))
		b.WriteString("\n")
	} else {
		maxVisible := m.maxVisiblePorts()
		end := m.scrollOffset + maxVisible
		if end > len(m.ports) {
			end = len(m.ports)
		}

		if m.scrollOffset > 0 {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  ... %d more above ...", m.scrollOffset)))
			b.WriteString("\n")
		}

		for i := m.scrollOffset; i < end; i++ {
			p := m.ports[i]
			cursor := "  "
			if i == m.cursor {
				cursor = "> "
			}

			// Status indicator
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
			if i == m.cursor {
				portStr = selectedStyle.Render(portStr)
				cursor = selectedStyle.Render("> ")
			}

			line := fmt.Sprintf("%s%s %s", cursor, status, portStr)

			if p.Process != "" {
				line += dimStyle.Render(fmt.Sprintf("  %s", p.Process))
			}
			if !p.Discovered {
				line += dimStyle.Render("  (manual)")
			}
			if p.Status == PortActive {
				line += activeStyle.Render(fmt.Sprintf("  -> localhost:%d", p.LocalPort))
			}
			if p.Error != "" {
				line += errorStyle.Render(fmt.Sprintf("  %s", p.Error))
			}

			b.WriteString(line)
			b.WriteString("\n")
		}

		if end < len(m.ports) {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  ... %d more below ...", len(m.ports)-end)))
			b.WriteString("\n")
		}
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
		"space/enter: toggle",
		"a: add port",
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
