package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// LogEntry is one structured journald line returned by GET /logs.json.
type LogEntry struct {
	Time     string `json:"time"`
	Unit     string `json:"unit,omitempty"`
	Priority int    `json:"priority"`
	Message  string `json:"message"`
}

// LogsResponse is the JSON payload returned by GET /logs.json.
type LogsResponse struct {
	Host    string     `json:"host"`
	Target  string     `json:"target"`
	Kind    string     `json:"kind"` // "guest" | "unit"
	Entries []LogEntry `json:"entries"`
}

var (
	nspawnRootDir     = "/var/lib/nixos-containers"
	containersDataDir = "/srv/containers"
)

var runJournalctl = func(ctx context.Context, args []string) ([]byte, error) {
	c := exec.CommandContext(ctx, "journalctl", args...)
	var out bytes.Buffer
	c.Stdout = &out
	err := c.Run()
	return out.Bytes(), err
}

// findGuestJournalDir locates the journal directory for an nspawn container
// (`kind == "nixos"`) so `fleet-agent` (with SupplementaryGroups = ["systemd-journal"])
// can read guest application logs directly via `journalctl -D <dir>` without
// needing CAP_SYS_ADMIN (`-M`). Falls back to `-M` if no readable directory exists.
func findGuestJournalDir(svc string) string {
	if !svcNameRe.MatchString(svc) {
		return ""
	}
	candidates := []string{
		filepath.Join(nspawnRootDir, svc, "var/log/journal"),
		filepath.Join(nspawnRootDir, svc, "run/log/journal"),
		filepath.Join(containersDataDir, svc, "nixos/var/log/journal"),
	}
	for _, base := range candidates {
		if entries, err := os.ReadDir(base); err == nil {
			for _, e := range entries {
				if e.IsDir() && len(e.Name()) >= 16 {
					return filepath.Join(base, e.Name())
				}
			}
			return base
		}
	}
	return ""
}

func queryLogs(ctx context.Context, host, target, kind string, lines int, priority, grepStr string, extraUnits []string) (LogsResponse, error) {
	if lines <= 0 {
		lines = 100
	} else if lines > 1000 {
		lines = 1000
	}
	if res, handled, err := querySupervisorLogs(ctx, host, target, lines, grepStr); handled {
		return res, err
	}

	units := installedUnits()
	allowedExtra := map[string]string{}
	for _, u := range extraUnits {
		full := u
		if !strings.HasSuffix(full, ".service") {
			full += ".service"
		}
		short := strings.TrimSuffix(full, ".service")
		allowedExtra[short] = full
		allowedExtra[full] = full
	}

	var jArgs []string
	resolvedKind := kind

	if u, isContainer := units[target]; isContainer {
		isNspawn := strings.HasPrefix(u, "container@")
		if resolvedKind == "" {
			if isNspawn {
				resolvedKind = "guest"
			} else {
				resolvedKind = "unit"
			}
		}
		if resolvedKind == "guest" && isNspawn {
			if dir := findGuestJournalDir(target); dir != "" {
				jArgs = []string{"-D", dir}
			} else {
				jArgs = []string{"-M", target}
			}
		} else {
			resolvedKind = "unit"
			jArgs = []string{"-u", u}
		}
	} else if fullUnit, isExtra := allowedExtra[target]; isExtra {
		resolvedKind = "unit"
		jArgs = []string{"-u", fullUnit}
	} else {
		return LogsResponse{}, fmt.Errorf("target %q is not an installed service or allowed unit", target)
	}

	jArgs = append(jArgs, "--no-pager", "-o", "json", "-n", strconv.Itoa(lines))
	if priority != "" {
		switch priority {
		case "0", "1", "2", "3", "4", "5", "6", "7", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug":
			jArgs = append(jArgs, "-p", priority)
		}
	}

	raw, err := runJournalctl(ctx, jArgs)
	if err != nil && len(raw) == 0 {
		return LogsResponse{}, err
	}

	entries := parseJournalJSONLines(raw, grepStr)
	return LogsResponse{
		Host:    host,
		Target:  target,
		Kind:    resolvedKind,
		Entries: entries,
	}, nil
}

func parseJournalJSONLines(raw []byte, grepSubstr string) []LogEntry {
	entries := []LogEntry{}
	needle := strings.ToLower(strings.TrimSpace(grepSubstr))
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			continue
		}
		msg := extractJournalMessage(m["MESSAGE"])
		if needle != "" && !strings.Contains(strings.ToLower(msg), needle) {
			continue
		}
		ts := ""
		if usStr, ok := m["__REALTIME_TIMESTAMP"].(string); ok {
			if us, err := strconv.ParseInt(usStr, 10, 64); err == nil {
				ts = time.UnixMicro(us).UTC().Format(time.RFC3339)
			}
		}
		prio := 6
		if pStr, ok := m["PRIORITY"].(string); ok {
			if p, err := strconv.Atoi(pStr); err == nil {
				prio = p
			}
		}
		unit, _ := m["_SYSTEMD_UNIT"].(string)
		if unit == "" {
			unit, _ = m["SYSLOG_IDENTIFIER"].(string)
		}
		entries = append(entries, LogEntry{
			Time:     ts,
			Unit:     unit,
			Priority: prio,
			Message:  msg,
		})
	}
	return entries
}

func extractJournalMessage(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case []any:
		b := make([]byte, 0, len(x))
		for _, elem := range x {
			if f, ok := elem.(float64); ok {
				b = append(b, byte(int(f)))
			}
		}
		return string(b)
	default:
		return ""
	}
}
