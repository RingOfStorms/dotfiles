// Package alert monitors placed services and persists notification de-duplication.
package alert

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

type Config struct {
	URL       string
	DownAfter time.Duration
	Store     *store.Store
	Client    *http.Client
	Probe     func(context.Context, string) (time.Time, error)
}

type Monitor struct {
	cfg   Config
	open  map[string]store.AlertState
	mu    sync.RWMutex
	certs []state.Certificate
}

func New(ctx context.Context, cfg Config) (*Monitor, error) {
	if cfg.URL != "" {
		u, err := url.Parse(cfg.URL)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
			return nil, fmt.Errorf("ntfy URL must be an http(s) topic URL")
		}
	}
	if cfg.DownAfter <= 0 {
		return nil, fmt.Errorf("health down duration must be positive")
	}
	if cfg.Client == nil {
		cfg.Client = &http.Client{Timeout: 10 * time.Second}
	}
	if cfg.Probe == nil {
		cfg.Probe = probeCertificate
	}
	m := &Monitor{cfg: cfg, open: map[string]store.AlertState{}}
	rows, err := cfg.Store.AlertStates(ctx)
	if err != nil {
		return nil, err
	}
	for _, a := range rows {
		m.open[a.Kind+"/"+a.Subject] = a
	}
	return m, nil
}

func probeCertificate(ctx context.Context, raw string) (time.Time, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return time.Time{}, fmt.Errorf("invalid TLS URL %q", raw)
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	// Inspection only: expired certificates must still report their NotAfter.
	// No application data or credentials are sent on this connection.
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: &tls.Config{ServerName: u.Hostname(), InsecureSkipVerify: true}}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))
	if err != nil {
		return time.Time{}, err
	}
	defer conn.Close()
	return conn.(*tls.Conn).ConnectionState().PeerCertificates[0].NotAfter, nil
}

func (m *Monitor) Certificates() []state.Certificate {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return append([]state.Certificate(nil), m.certs...)
}

func (m *Monitor) send(ctx context.Context, a store.AlertState) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.cfg.URL, strings.NewReader(a.Body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", a.Title)
	req.Header.Set("Priority", "high")
	resp, err := m.cfg.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy: HTTP %d", resp.StatusCode)
	}
	return nil
}

// Check runs once. Only placed services are monitored. Unknown host state is
// unhealthy; missing backup stamps are stale after the same startup grace.
func (m *Monitor) Check(ctx context.Context, snapshot state.Merged, now time.Time) error {
	active := map[string]bool{}
	var first error
	record := func(err error) {
		if err != nil && first == nil {
			first = err
		}
	}
	condition := func(kind, subject, body string, delay time.Duration) {
		key := kind + "/" + subject
		active[key] = true
		a, ok := m.open[key]
		if !ok {
			a = store.AlertState{Kind: kind, Subject: subject, Title: "fleet-edge: " + kind + " " + subject, Since: now.Unix()}
		}
		a.Body = body
		if err := m.cfg.Store.PutAlertState(ctx, a); err != nil {
			record(err)
			return
		}
		m.open[key] = a
		if m.cfg.URL == "" || a.Notified != 0 || now.Sub(time.Unix(a.Since, 0)) < delay {
			return
		}
		if err := m.send(ctx, a); err != nil {
			record(err)
			return
		}
		a.Notified = now.Unix()
		m.open[key] = a
		record(m.cfg.Store.PutAlertState(ctx, a))
	}
	certURLs := map[string]bool{}
	for _, s := range snapshot.Services {
		if s.BoundHost == "" {
			continue
		}
		down := s.Active != "active"
		for _, r := range s.Routes {
			if strings.HasPrefix(r.URLStr(), "https://") {
				certURLs[r.URLStr()] = true
			}
			if r.Health == nil || *r.Health == "" || r.URLStr() == "" {
				continue
			}
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(r.URLStr(), "/")+*r.Health, nil)
			if err != nil {
				down = true
				continue
			}
			resp, err := m.cfg.Client.Do(req)
			if err != nil {
				down = true
				continue
			}
			resp.Body.Close()
			if resp.StatusCode < 200 || resp.StatusCode >= 400 {
				down = true
			}
		}
		if down {
			condition("health", s.Name, fmt.Sprintf("%s on %s has been unhealthy for at least %s", s.Name, s.BoundHost, m.cfg.DownAfter), m.cfg.DownAfter)
		}
		if s.Backup == "stale" {
			condition("backup", s.Name, fmt.Sprintf("%s on %s: backup stamp is %s old (limit 36h)", s.Name, s.BoundHost, s.BackupAge), 0)
		}
		if s.Backup == "none" {
			condition("backup", s.Name, s.Name+": no successful backup stamp for 36h", state.BackupStaleAfter)
		}
		if s.Backup == "unknown" {
			if _, ok := m.open["backup/"+s.Name]; ok {
				active["backup/"+s.Name] = true
			}
		}
	}
	certs := make([]state.Certificate, 0, len(certURLs))
	urls := make([]string, 0, len(certURLs))
	for u := range certURLs {
		urls = append(urls, u)
	}
	sort.Strings(urls)
	for _, u := range urls {
		expires, err := m.cfg.Probe(ctx, u)
		c := state.Certificate{URL: u, Expires: expires}
		if err != nil {
			c.Error = err.Error()
			active["certificate/"+u] = true
		} else {
			c.Expiring = expires.Sub(now) < 14*24*time.Hour
			if c.Expiring {
				condition("certificate", u, fmt.Sprintf("%s certificate expires %s (under 14 days)", u, expires.UTC().Format(time.RFC3339)), 0)
			}
		}
		certs = append(certs, c)
	}
	m.mu.Lock()
	m.certs = certs
	m.mu.Unlock()
	for key, a := range m.open {
		if !active[key] {
			if err := m.cfg.Store.DeleteAlertState(ctx, a.Kind, a.Subject); err != nil {
				record(err)
			} else {
				delete(m.open, key)
			}
		}
	}
	return first
}

func (m *Monitor) Run(ctx context.Context, source func(context.Context) state.Merged, onError func(error)) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		if err := m.Check(ctx, source(ctx), time.Now()); err != nil {
			onError(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
