package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

var supervisorBaseURL = "http://supervisor"

func supervisorToken() string {
	return strings.TrimSpace(os.Getenv("SUPERVISOR_TOKEN"))
}

// collectSupervisorUnits queries Home Assistant Supervisor when running inside
// a Home Assistant OS add-on (`SUPERVISOR_TOKEN` is set) and returns core,
// supervisor, host, and installed add-ons as HostUnits.
func collectSupervisorUnits(ctx context.Context) map[string]StatusService {
	tok := supervisorToken()
	if tok == "" {
		return nil
	}

	units := map[string]StatusService{
		"homeassistant": {
			Unit:    "homeassistant.service",
			Active:  "active",
			Enabled: true,
			Kind:    "host",
		},
		"supervisor": {
			Unit:    "supervisor.service",
			Active:  "active",
			Enabled: true,
			Kind:    "host",
		},
		"host": {
			Unit:    "host.service",
			Active:  "active",
			Enabled: true,
			Kind:    "host",
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, supervisorBaseURL+"/addons", nil)
	if err != nil {
		return units
	}
	req.Header.Set("Authorization", "Bearer "+tok)

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return units
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return units
	}

	var payload struct {
		Data struct {
			Addons []struct {
				Slug  string `json:"slug"`
				State string `json:"state"`
			} `json:"addons"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return units
	}

	for _, a := range payload.Data.Addons {
		slug := strings.TrimSpace(a.Slug)
		if !svcNameRe.MatchString(slug) {
			continue
		}
		active := "inactive"
		if a.State == "started" {
			active = "active"
		} else if a.State == "error" || a.State == "failed" {
			active = "failed"
		}
		key := "addon_" + slug
		units[key] = StatusService{
			Unit:    key + ".service",
			Active:  active,
			Enabled: true,
			Kind:    "host",
		}
	}
	return units
}

var (
	haHostLogRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+\S+\s+([^\[:\s]+)(?:\[\d+\])?:\s*(.*)$`)
	haCoreLogRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+\([^)]*\)\s+\[([^\]]+)\]\s*(.*)$`)
	ansiRe      = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)
)

func querySupervisorLogs(ctx context.Context, host, target string, lines int, grepStr string) (LogsResponse, bool, error) {
	tok := supervisorToken()
	if tok == "" {
		return LogsResponse{}, false, nil
	}

	short := strings.TrimSuffix(target, ".service")
	var endpoint string
	var defaultUnit string

	switch short {
	case "homeassistant", "core":
		endpoint = "/core/logs"
		defaultUnit = "homeassistant"
	case "supervisor":
		endpoint = "/supervisor/logs"
		defaultUnit = "supervisor"
	case "host", "fleet-agent", "sshd", "tailscaled":
		endpoint = "/host/logs"
		defaultUnit = short
	default:
		if slug, ok := strings.CutPrefix(short, "addon_"); ok && svcNameRe.MatchString(slug) {
			endpoint = "/addons/" + slug + "/logs"
			defaultUnit = slug
		} else if svcNameRe.MatchString(short) {
			endpoint = "/addons/" + short + "/logs"
			defaultUnit = short
		} else {
			return LogsResponse{}, false, nil
		}
	}

	url := fmt.Sprintf("%s%s?lines=%d", supervisorBaseURL, endpoint, lines)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return LogsResponse{}, true, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "text/plain")

	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return LogsResponse{}, true, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return LogsResponse{}, true, fmt.Errorf("supervisor %s returned HTTP %d: %s", endpoint, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return LogsResponse{}, true, err
	}

	entries := parseSupervisorLogLines(string(raw), defaultUnit, grepStr, lines)
	return LogsResponse{
		Host:    host,
		Target:  target,
		Kind:    "unit",
		Entries: entries,
	}, true, nil
}

func parseSupervisorLogLines(raw, defaultUnit, grepSubstr string, maxLines int) []LogEntry {
	var entries []LogEntry
	needle := strings.ToLower(strings.TrimSpace(grepSubstr))
	sc := bufio.NewScanner(strings.NewReader(raw))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)

	for sc.Scan() {
		line := strings.TrimRight(ansiRe.ReplaceAllString(sc.Text(), ""), "\r\n")
		if strings.TrimSpace(line) == "" {
			continue
		}
		if needle != "" && !strings.Contains(strings.ToLower(line), needle) {
			continue
		}

		entry := LogEntry{
			Unit:     defaultUnit,
			Priority: 6,
			Message:  line,
		}

		if m := haCoreLogRe.FindStringSubmatch(line); m != nil {
			entry.Time = m[1]
			entry.Priority = levelToPriority(m[2])
			entry.Unit = m[3]
			entry.Message = m[4]
		} else if m := haHostLogRe.FindStringSubmatch(line); m != nil {
			entry.Time = m[1]
			entry.Unit = m[2]
			entry.Message = m[3]
			entry.Priority = inferPriority(entry.Message)
		} else {
			entry.Priority = inferPriority(line)
		}
		entries = append(entries, entry)
	}

	if maxLines > 0 && len(entries) > maxLines {
		entries = entries[len(entries)-maxLines:]
	}
	return entries
}

func levelToPriority(lvl string) int {
	switch strings.ToUpper(lvl) {
	case "CRITICAL", "FATAL":
		return 2
	case "ERROR":
		return 3
	case "WARNING", "WARN":
		return 4
	case "NOTICE":
		return 5
	case "DEBUG":
		return 7
	default:
		return 6
	}
}

func inferPriority(msg string) int {
	low := strings.ToLower(msg)
	switch {
	case strings.Contains(low, "level=error") || strings.Contains(low, " error:") || strings.Contains(low, "[error]"):
		return 3
	case strings.Contains(low, "level=warn") || strings.Contains(low, " warning:") || strings.Contains(low, "[warn]"):
		return 4
	default:
		return 6
	}
}
