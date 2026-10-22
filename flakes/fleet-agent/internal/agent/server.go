package agent

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// StatusDoc is the JSON response served by GET /status.json on port 9101.
// It remains backwards-compatible with the original `{host, time, services}`
// schema while adding host telemetry, bcachefs pools, SMART, and fail2ban.
type StatusDoc struct {
	Host        string                   `json:"host"`
	Time        string                   `json:"time"`
	Services    map[string]StatusService `json:"services"`
	HostUnits   map[string]StatusService `json:"hostUnits,omitempty"`
	System      *SystemMetrics           `json:"system,omitempty"`
	Filesystems []FilesystemMount        `json:"filesystems,omitempty"`
	DiskIO      map[string]DiskRate      `json:"diskIO,omitempty"`
	NetIO       map[string]NetRate       `json:"netIO,omitempty"`
	Temps       []TempReading            `json:"temps,omitempty"`
	Smart       []SmartDrive             `json:"smart,omitempty"`
	Fail2ban    *Fail2banSummary         `json:"fail2ban,omitempty"`
}

// Config configures the per-host fleet-agent server.
type Config struct {
	Listen        string
	Host          string
	StateDir      string   // default /run/fleet-agent
	Mounts        []string // optional mount:label pairs
	ExtraUnits    []string // host systemd units to report and allow logs for
	EnableMetrics bool     // collect /proc, /sys, filesystems, snapshots
}

// buildStatus constructs a pure StatusDoc for unit tests and compatibility checks.
func buildStatus(host string, now time.Time, units map[string]string, states map[string]string, linked func(string) bool, backups map[string]time.Time) StatusDoc {
	d := StatusDoc{
		Host:     host,
		Time:     now.UTC().Format(time.RFC3339),
		Services: map[string]StatusService{},
	}
	for n, u := range units {
		ss := StatusService{
			Unit:    u,
			Active:  normActive(states[u]),
			Enabled: linked(bootLink(u)),
		}
		if t, ok := backups[n]; ok {
			ss.LastBackup = t.UTC().Format(time.RFC3339)
		}
		d.Services[n] = ss
	}
	return d
}

// Handler builds the HTTP mux for `/status.json` and `/logs.json`.
func Handler(cfg Config, sampler *Sampler) http.Handler {
	if sampler == nil && cfg.EnableMetrics {
		sampler = NewSampler()
	}
	mux := http.NewServeMux()

	mux.HandleFunc("/status.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		svcs, hostUnits, err := collectUnits(ctx, cfg.ExtraUnits)
		if err != nil {
			http.Error(w, "status unavailable", http.StatusServiceUnavailable)
			fmt.Fprintln(os.Stderr, err)
			return
		}
		d := StatusDoc{
			Host:      cfg.Host,
			Time:      time.Now().UTC().Format(time.RFC3339),
			Services:  svcs,
			HostUnits: hostUnits,
		}
		if len(d.HostUnits) == 0 {
			d.HostUnits = nil
		}

		if cfg.EnableMetrics && sampler != nil {
			sys, diskIO, netIO, temps := sampler.Snapshot()
			d.System = &sys
			if len(diskIO) > 0 {
				d.DiskIO = diskIO
			}
			if len(netIO) > 0 {
				d.NetIO = netIO
			}
			if len(temps) > 0 {
				d.Temps = temps
			}
			d.Filesystems = collectFilesystems(procRoot, sysRoot, cfg.StateDir, cfg.Mounts)
			d.Smart = readSmartSnapshot(cfg.StateDir)
			d.Fail2ban = readFail2banSnapshot(cfg.StateDir)
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(d)
	})

	mux.HandleFunc("/logs.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		q := r.URL.Query()
		target := strings.TrimSpace(q.Get("target"))
		if target == "" {
			target = strings.TrimSpace(q.Get("unit"))
		}
		if target == "" {
			http.Error(w, "missing target parameter", http.StatusBadRequest)
			return
		}
		kind := strings.TrimSpace(q.Get("kind"))
		lines := 100
		if lStr := q.Get("lines"); lStr != "" {
			if n, err := strconv.Atoi(lStr); err == nil && n > 0 {
				lines = n
			}
		}
		prio := strings.TrimSpace(q.Get("priority"))
		grepStr := strings.TrimSpace(q.Get("grep"))

		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		res, err := queryLogs(ctx, cfg.Host, target, kind, lines, prio, grepStr, cfg.ExtraUnits)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(res)
	})

	return mux
}

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			*m = append(*m, part)
		}
	}
	return nil
}

// Run parses CLI flags for `fleet agent` and runs the HTTP server.
func Run(args []string) error {
	fs := flag.NewFlagSet("fleet agent", flag.ContinueOnError)
	listen := fs.String("listen", "", "ADDR:PORT to bind to (required)")
	host := fs.String("host", "", "host name (default: os.Hostname)")
	stateDir := fs.String("state-dir", "/run/fleet-agent", "directory holding companion timer JSON snapshots")
	sampleInterval := fs.Duration("sample-interval", 5*time.Second, "background /proc rate sampling interval")
	var mounts multiFlag
	var extraUnits multiFlag
	fs.Var(&mounts, "mount", "mount[:label] to monitor (repeatable or comma-separated)")
	fs.Var(&extraUnits, "unit", "extra host systemd unit to monitor and allow logs for (repeatable or comma-separated)")

	if err := fs.Parse(args); err != nil {
		return err
	}
	if *listen == "" {
		return fmt.Errorf("agent needs --listen ADDR:PORT")
	}
	if *host == "" {
		h, err := os.Hostname()
		if err != nil {
			return err
		}
		*host = h
	}

	sampler := NewSampler()
	if *sampleInterval > 0 {
		go func() {
			t := time.NewTicker(*sampleInterval)
			defer t.Stop()
			for now := range t.C {
				sampler.SampleAt(now)
			}
		}()
	}

	cfg := Config{
		Listen:        *listen,
		Host:          *host,
		StateDir:      *stateDir,
		Mounts:        mounts,
		ExtraUnits:    extraUnits,
		EnableMetrics: true,
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           Handler(cfg, sampler),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	fmt.Fprintf(os.Stderr, "fleet-agent: %s on http://%s/status.json\n", cfg.Host, cfg.Listen)
	return srv.ListenAndServe()
}
