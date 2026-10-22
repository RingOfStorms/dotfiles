// Package store implements fleet-edge's historical time-series storage,
// last-known host state cache (for sleeping laptops/workstations), automatic
// tier rollups (30s -> 5m -> 1h), and Beszel data.db import.
//
// It uses the standard `sqlite3` CLI via os/exec so `fleet-edge` remains a
// pure stdlib Go binary with `vendorHash = null` and zero CGo dependencies.
package store

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const schemaSQL = `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS host_samples (
  host          TEXT NOT NULL,
  recorded_host TEXT NOT NULL,
  ts            INTEGER NOT NULL,
  tier          TEXT NOT NULL,
  cpu_pct       REAL,
  cpu_max       REAL,
  load1         REAL,
  mem_used      INTEGER,
  mem_total     INTEGER,
  swap_used     INTEGER,
  net_rx_bps    INTEGER,
  net_tx_bps    INTEGER,
  disk_r_bps    INTEGER,
  disk_w_bps    INTEGER,
  temp_max_c    REAL,
  PRIMARY KEY (host, tier, ts)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS fs_samples (
  host           TEXT NOT NULL,
  mount          TEXT NOT NULL,
  fstype         TEXT NOT NULL,
  ts             INTEGER NOT NULL,
  tier           TEXT NOT NULL,
  used_bytes     INTEGER,
  total_bytes    INTEGER,
  raw_used_bytes INTEGER,
  raw_cap_bytes  INTEGER,
  PRIMARY KEY (host, mount, tier, ts)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS host_last_state (
  host       TEXT PRIMARY KEY,
  last_seen  INTEGER NOT NULL,
  status_doc TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS host_events (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  host   TEXT NOT NULL,
  ts     INTEGER NOT NULL,
  kind   TEXT NOT NULL,
  detail TEXT NOT NULL
);
`

// Sample represents one time-series point for a host.
type Sample struct {
	Host         string  `json:"host"`
	RecordedHost string  `json:"recordedHost"`
	TS           int64   `json:"ts"`
	Tier         string  `json:"tier"`
	CPUPct       float64 `json:"cpuPct"`
	CPUMax       float64 `json:"cpuMax"`
	Load1        float64 `json:"load1"`
	MemUsed      uint64  `json:"memUsed"`
	MemTotal     uint64  `json:"memTotal"`
	SwapUsed     uint64  `json:"swapUsed"`
	NetRxBps     uint64  `json:"netRxBps"`
	NetTxBps     uint64  `json:"netTxBps"`
	DiskRBps     uint64  `json:"diskRBps"`
	DiskWBps     uint64  `json:"diskWBps"`
	TempMaxC     float64 `json:"tempMaxC"`
}

// FSSample represents one filesystem usage point for a host mount.
type FSSample struct {
	Host         string `json:"host"`
	Mount        string `json:"mount"`
	FSType       string `json:"fstype"`
	TS           int64  `json:"ts"`
	Tier         string `json:"tier"`
	UsedBytes    uint64 `json:"usedBytes"`
	TotalBytes   uint64 `json:"totalBytes"`
	RawUsedBytes uint64 `json:"rawUsedBytes,omitempty"`
	RawCapBytes  uint64 `json:"rawCapBytes,omitempty"`
}

// LastState holds the persisted last-known status.json for an offline host.
type LastState struct {
	Host      string          `json:"host"`
	LastSeen  time.Time       `json:"lastSeen"`
	StatusRaw json.RawMessage `json:"statusDoc"`
}

// Event represents a timeline annotation (e.g. "migrated from h002").
type Event struct {
	ID     int64  `json:"id"`
	Host   string `json:"host"`
	TS     int64  `json:"ts"`
	Kind   string `json:"kind"`
	Detail string `json:"detail"`
}

// Store manages the SQLite metrics database.
type Store struct {
	dbPath     string
	sqliteBin  string
	mu         sync.Mutex
	lastRollup time.Time
}

// Open initializes or opens the SQLite metrics database at dbPath.
func Open(dbPath string) (*Store, error) {
	if dbPath == "" {
		return nil, fmt.Errorf("empty database path")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o750); err != nil {
		return nil, fmt.Errorf("mkdir db dir: %w", err)
	}
	bin, err := exec.LookPath("sqlite3")
	if err != nil {
		bin = "sqlite3"
	}
	s := &Store{
		dbPath:    dbPath,
		sqliteBin: bin,
	}
	if err := s.execSQL(context.Background(), schemaSQL); err != nil {
		return nil, fmt.Errorf("init schema: %w", err)
	}
	return s, nil
}

func (s *Store) execSQL(ctx context.Context, sqlText string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.execSQLLocked(ctx, sqlText)
}

func (s *Store) execSQLLocked(ctx context.Context, sqlText string) error {
	cmd := exec.CommandContext(ctx, s.sqliteBin, "-bail", "-cmd", ".timeout 5000", s.dbPath)
	cmd.Stdin = strings.NewReader(sqlText + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sqlite3 exec: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func (s *Store) queryJSON(ctx context.Context, sqlQuery string, dest any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cmd := exec.CommandContext(ctx, s.sqliteBin, "-json", "-cmd", ".timeout 5000", s.dbPath, sqlQuery)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sqlite3 query: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	out := bytes.TrimSpace(stdout.Bytes())
	if len(out) == 0 {
		return nil
	}
	return json.Unmarshal(out, dest)
}

// RecordPoll writes a host sample, filesystem samples, and updates host_last_state
// in a single transaction. It also runs periodic rollups once per hour.
func (s *Store) RecordPoll(ctx context.Context, sample Sample, fsSamples []FSSample, rawStatusJSON []byte) error {
	if s == nil {
		return nil
	}
	if sample.Tier == "" {
		sample.Tier = "30s"
	}
	if sample.RecordedHost == "" {
		sample.RecordedHost = sample.Host
	}

	var b strings.Builder
	b.WriteString("BEGIN TRANSACTION;\n")
	fmt.Fprintf(&b,
		"INSERT OR REPLACE INTO host_samples (host, recorded_host, ts, tier, cpu_pct, cpu_max, load1, mem_used, mem_total, swap_used, net_rx_bps, net_tx_bps, disk_r_bps, disk_w_bps, temp_max_c) VALUES (%s, %s, %d, %s, %.4f, %.4f, %.4f, %d, %d, %d, %d, %d, %d, %d, %.2f);\n",
		sqlQuote(sample.Host),
		sqlQuote(sample.RecordedHost),
		sample.TS,
		sqlQuote(sample.Tier),
		sample.CPUPct,
		sample.CPUMax,
		sample.Load1,
		sample.MemUsed,
		sample.MemTotal,
		sample.SwapUsed,
		sample.NetRxBps,
		sample.NetTxBps,
		sample.DiskRBps,
		sample.DiskWBps,
		sample.TempMaxC,
	)

	for _, fs := range fsSamples {
		tier := fs.Tier
		if tier == "" {
			tier = sample.Tier
		}
		fmt.Fprintf(&b,
			"INSERT OR REPLACE INTO fs_samples (host, mount, fstype, ts, tier, used_bytes, total_bytes, raw_used_bytes, raw_cap_bytes) VALUES (%s, %s, %s, %d, %s, %d, %d, %d, %d);\n",
			sqlQuote(sample.Host),
			sqlQuote(fs.Mount),
			sqlQuote(fs.FSType),
			sample.TS,
			sqlQuote(tier),
			fs.UsedBytes,
			fs.TotalBytes,
			fs.RawUsedBytes,
			fs.RawCapBytes,
		)
	}

	if len(rawStatusJSON) > 0 {
		fmt.Fprintf(&b,
			"INSERT OR REPLACE INTO host_last_state (host, last_seen, status_doc) VALUES (%s, %d, %s);\n",
			sqlQuote(sample.Host),
			sample.TS,
			sqlQuote(string(rawStatusJSON)),
		)
	}
	b.WriteString("COMMIT;\n")

	if err := s.execSQL(ctx, b.String()); err != nil {
		return err
	}

	now := time.Unix(sample.TS, 0)
	s.mu.Lock()
	needRollup := s.lastRollup.IsZero() || now.Sub(s.lastRollup) >= time.Hour
	if needRollup {
		s.lastRollup = now
	}
	s.mu.Unlock()

	if needRollup {
		_ = s.Rollup(ctx, now)
	}
	return nil
}

// Rollup downsamples 30s -> 5m (older than 7d) and 5m -> 1h (older than 90d),
// pruning raw rows older than their retention window.
func (s *Store) Rollup(ctx context.Context, now time.Time) error {
	if s == nil {
		return nil
	}
	cutoff7d := now.Add(-7 * 24 * time.Hour).Unix()
	cutoff90d := now.Add(-90 * 24 * time.Hour).Unix()
	cutoff5y := now.Add(-5 * 365 * 24 * time.Hour).Unix()

	sqlText := fmt.Sprintf(`
BEGIN TRANSACTION;

INSERT OR REPLACE INTO host_samples (host, recorded_host, ts, tier, cpu_pct, cpu_max, load1, mem_used, mem_total, swap_used, net_rx_bps, net_tx_bps, disk_r_bps, disk_w_bps, temp_max_c)
SELECT
  host,
  MAX(recorded_host),
  (ts / 300) * 300 AS bucket_ts,
  '5m',
  AVG(cpu_pct),
  MAX(cpu_max),
  AVG(load1),
  CAST(AVG(mem_used) AS INTEGER),
  MAX(mem_total),
  CAST(AVG(swap_used) AS INTEGER),
  CAST(AVG(net_rx_bps) AS INTEGER),
  CAST(AVG(net_tx_bps) AS INTEGER),
  CAST(AVG(disk_r_bps) AS INTEGER),
  CAST(AVG(disk_w_bps) AS INTEGER),
  MAX(temp_max_c)
FROM host_samples
WHERE tier = '30s' AND ts < %d
GROUP BY host, bucket_ts;

DELETE FROM host_samples WHERE tier = '30s' AND ts < %d;

INSERT OR REPLACE INTO host_samples (host, recorded_host, ts, tier, cpu_pct, cpu_max, load1, mem_used, mem_total, swap_used, net_rx_bps, net_tx_bps, disk_r_bps, disk_w_bps, temp_max_c)
SELECT
  host,
  MAX(recorded_host),
  (ts / 3600) * 3600 AS bucket_ts,
  '1h',
  AVG(cpu_pct),
  MAX(cpu_max),
  AVG(load1),
  CAST(AVG(mem_used) AS INTEGER),
  MAX(mem_total),
  CAST(AVG(swap_used) AS INTEGER),
  CAST(AVG(net_rx_bps) AS INTEGER),
  CAST(AVG(net_tx_bps) AS INTEGER),
  CAST(AVG(disk_r_bps) AS INTEGER),
  CAST(AVG(disk_w_bps) AS INTEGER),
  MAX(temp_max_c)
FROM host_samples
WHERE tier = '5m' AND ts < %d
GROUP BY host, bucket_ts;

DELETE FROM host_samples WHERE tier = '5m' AND ts < %d;
DELETE FROM host_samples WHERE tier = '1h' AND ts < %d;

INSERT OR REPLACE INTO fs_samples (host, mount, fstype, ts, tier, used_bytes, total_bytes, raw_used_bytes, raw_cap_bytes)
SELECT
  host,
  mount,
  MAX(fstype),
  (ts / 300) * 300 AS bucket_ts,
  '5m',
  CAST(AVG(used_bytes) AS INTEGER),
  MAX(total_bytes),
  CAST(AVG(raw_used_bytes) AS INTEGER),
  MAX(raw_cap_bytes)
FROM fs_samples
WHERE tier = '30s' AND ts < %d
GROUP BY host, mount, bucket_ts;

DELETE FROM fs_samples WHERE tier = '30s' AND ts < %d;

INSERT OR REPLACE INTO fs_samples (host, mount, fstype, ts, tier, used_bytes, total_bytes, raw_used_bytes, raw_cap_bytes)
SELECT
  host,
  mount,
  MAX(fstype),
  (ts / 3600) * 3600 AS bucket_ts,
  '1h',
  CAST(AVG(used_bytes) AS INTEGER),
  MAX(total_bytes),
  CAST(AVG(raw_used_bytes) AS INTEGER),
  MAX(raw_cap_bytes)
FROM fs_samples
WHERE tier = '5m' AND ts < %d
GROUP BY host, mount, bucket_ts;

DELETE FROM fs_samples WHERE tier = '5m' AND ts < %d;
DELETE FROM fs_samples WHERE tier = '1h' AND ts < %d;

COMMIT;
`, cutoff7d, cutoff7d, cutoff90d, cutoff90d, cutoff5y, cutoff7d, cutoff7d, cutoff90d, cutoff90d, cutoff5y)

	return s.execSQL(ctx, sqlText)
}

// QuerySamples returns samples for host (and any aliases in `aliases`) over
// [sinceTS, untilTS], ordered by timestamp ascending.
func (s *Store) QuerySamples(ctx context.Context, host string, aliases []string, sinceTS, untilTS int64) ([]Sample, error) {
	if s == nil {
		return nil, nil
	}
	hosts := append([]string{host}, aliases...)
	inList := sqlInList(hosts)
	span := untilTS - sinceTS

	// Pick tiers appropriate for the requested window so we seamlessly span
	// 1h -> 5m -> 30s without returning 20,000 raw points for a 1-year chart.
	var tierFilter string
	switch {
	case span <= 7*24*3600:
		tierFilter = "tier IN ('30s', '5m', '1h')"
	case span <= 90*24*3600:
		tierFilter = "tier IN ('5m', '1h', '30s')"
	default:
		tierFilter = "tier IN ('1h', '5m', '30s')"
	}

	q := fmt.Sprintf(`
SELECT
  host,
  recorded_host AS recordedHost,
  ts,
  tier,
  COALESCE(cpu_pct, 0) AS cpuPct,
  COALESCE(cpu_max, 0) AS cpuMax,
  COALESCE(load1, 0) AS load1,
  COALESCE(mem_used, 0) AS memUsed,
  COALESCE(mem_total, 0) AS memTotal,
  COALESCE(swap_used, 0) AS swapUsed,
  COALESCE(net_rx_bps, 0) AS netRxBps,
  COALESCE(net_tx_bps, 0) AS netTxBps,
  COALESCE(disk_r_bps, 0) AS diskRBps,
  COALESCE(disk_w_bps, 0) AS diskWBps,
  COALESCE(temp_max_c, 0) AS tempMaxC
FROM host_samples
WHERE host IN (%s) AND ts >= %d AND ts <= %d AND %s
ORDER BY ts ASC;
`, inList, sinceTS, untilTS, tierFilter)

	var rows []Sample
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return nil, err
	}
	// Deduplicate identical timestamps across tiers (prefer finer tier).
	byTS := make(map[int64]Sample, len(rows))
	for _, r := range rows {
		if existing, ok := byTS[r.TS]; ok {
			if tierRank(r.Tier) >= tierRank(existing.Tier) {
				continue
			}
		}
		byTS[r.TS] = r
	}
	out := make([]Sample, 0, len(byTS))
	for _, r := range byTS {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TS < out[j].TS })
	return out, nil
}

func tierRank(t string) int {
	switch t {
	case "30s":
		return 0
	case "5m":
		return 1
	case "1h":
		return 2
	default:
		return 3
	}
}

// QueryFSSamples returns filesystem usage history for host over [sinceTS, untilTS].
func (s *Store) QueryFSSamples(ctx context.Context, host string, aliases []string, sinceTS, untilTS int64) ([]FSSample, error) {
	if s == nil {
		return nil, nil
	}
	hosts := append([]string{host}, aliases...)
	q := fmt.Sprintf(`
SELECT
  host,
  mount,
  fstype,
  ts,
  tier,
  COALESCE(used_bytes, 0) AS usedBytes,
  COALESCE(total_bytes, 0) AS totalBytes,
  COALESCE(raw_used_bytes, 0) AS rawUsedBytes,
  COALESCE(raw_cap_bytes, 0) AS rawCapBytes
FROM fs_samples
WHERE host IN (%s) AND ts >= %d AND ts <= %d
ORDER BY ts ASC;
`, sqlInList(hosts), sinceTS, untilTS)

	var rows []FSSample
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

// LoadAllLastStates returns the persisted last-known status.json for every host.
func (s *Store) LoadAllLastStates(ctx context.Context) (map[string]LastState, error) {
	if s == nil {
		return nil, nil
	}
	var rows []struct {
		Host      string `json:"host"`
		LastSeen  int64  `json:"lastSeen"`
		StatusDoc string `json:"statusDoc"`
	}
	q := `SELECT host, last_seen AS lastSeen, status_doc AS statusDoc FROM host_last_state;`
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return nil, err
	}
	out := make(map[string]LastState, len(rows))
	for _, r := range rows {
		out[r.Host] = LastState{
			Host:      r.Host,
			LastSeen:  time.Unix(r.LastSeen, 0).UTC(),
			StatusRaw: json.RawMessage(r.StatusDoc),
		}
	}
	return out, nil
}

// QueryEvents returns host_events for host (and aliases).
func (s *Store) QueryEvents(ctx context.Context, host string, aliases []string) ([]Event, error) {
	if s == nil {
		return nil, nil
	}
	hosts := append([]string{host}, aliases...)
	q := fmt.Sprintf(`
SELECT id, host, ts, kind, detail
FROM host_events
WHERE host IN (%s)
ORDER BY ts ASC;
`, sqlInList(hosts))
	var rows []Event
	if err := s.queryJSON(ctx, q, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

// RecordEvent inserts a timeline event if an identical (host, ts, kind) does not exist.
func (s *Store) RecordEvent(ctx context.Context, host string, ts int64, kind, detail string) error {
	if s == nil {
		return nil
	}
	q := fmt.Sprintf(`
INSERT INTO host_events (host, ts, kind, detail)
SELECT %s, %d, %s, %s
WHERE NOT EXISTS (
  SELECT 1 FROM host_events WHERE host = %s AND ts = %d AND kind = %s
);
`, sqlQuote(host), ts, sqlQuote(kind), sqlQuote(detail), sqlQuote(host), ts, sqlQuote(kind))
	return s.execSQL(ctx, q)
}

// ImportBeszel imports historical system_stats from a Beszel PocketBase SQLite
// database (`data.db`), mapping any retired host names via `hostMap` (e.g.
// `map["h002"] = "h004"`). It also records a `host_events` cutover marker when
// a mapped host transitions to its successor.
func (s *Store) ImportBeszel(ctx context.Context, beszelDBPath string, hostMap map[string]string) (int, error) {
	if s == nil {
		return 0, fmt.Errorf("nil store")
	}
	if _, err := os.Stat(beszelDBPath); err != nil {
		return 0, fmt.Errorf("beszel db %s: %w", beszelDBPath, err)
	}

	// Read systems and system_stats from Beszel's SQLite DB.
	cmd := exec.CommandContext(ctx, s.sqliteBin, "-json", beszelDBPath, `
SELECT
  s.name AS host,
  st.type AS stat_type,
  st.created AS created,
  st.stats AS stats
FROM system_stats st
JOIN systems s ON st.system = s.id
ORDER BY st.created ASC;
`)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return 0, fmt.Errorf("query beszel db: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}

	var rawRows []struct {
		Host     string `json:"host"`
		StatType string `json:"stat_type"`
		Created  string `json:"created"`
		Stats    string `json:"stats"`
	}
	if out := bytes.TrimSpace(stdout.Bytes()); len(out) > 0 {
		if err := json.Unmarshal(out, &rawRows); err != nil {
			return 0, fmt.Errorf("unmarshal beszel rows: %w", err)
		}
	}

	type beszelStats struct {
		CPU   float64            `json:"cpu"`
		CPUM  float64            `json:"cpum"`
		Mem   float64            `json:"mem"` // GB
		MemU  float64            `json:"mu"`  // GB
		SwapU float64            `json:"su"`  // GB
		Disk  float64            `json:"d"`   // GB total
		DiskU float64            `json:"du"`  // GB used
		DiskR float64            `json:"dr"`  // MB/s read
		DiskW float64            `json:"dw"`  // MB/s write
		NetS  float64            `json:"ns"`  // MB/s sent
		NetR  float64            `json:"nr"`  // MB/s recv
		Load  []float64          `json:"la"`  // [load1, load5, load15]
		Temps map[string]float64 `json:"t"`
	}

	const gbBytes = 1024 * 1024 * 1024
	const mbBytes = 1024 * 1024

	var sqlBuf strings.Builder
	sqlBuf.WriteString("BEGIN TRANSACTION;\n")

	imported := 0
	lastOldHostTS := map[string]int64{} // oldHost -> max timestamp

	for _, row := range rawRows {
		ts := parseBeszelTime(row.Created)
		if ts <= 0 {
			continue
		}
		var bs beszelStats
		if err := json.Unmarshal([]byte(row.Stats), &bs); err != nil {
			continue
		}
		recordedHost := row.Host
		canonHost := recordedHost
		if mapped, ok := hostMap[recordedHost]; ok && mapped != "" {
			canonHost = mapped
			if ts > lastOldHostTS[recordedHost] {
				lastOldHostTS[recordedHost] = ts
			}
		}

		tier := mapBeszelTier(row.StatType)
		cpuMax := bs.CPUM
		if cpuMax == 0 {
			cpuMax = bs.CPU
		}
		var load1 float64
		if len(bs.Load) > 0 {
			load1 = bs.Load[0]
		}
		var maxTemp float64
		for _, tc := range bs.Temps {
			if tc > maxTemp {
				maxTemp = tc
			}
		}

		memTotal := uint64(bs.Mem * gbBytes)
		memUsed := uint64(bs.MemU * gbBytes)
		swapUsed := uint64(bs.SwapU * gbBytes)
		netRx := uint64(bs.NetR * mbBytes)
		netTx := uint64(bs.NetS * mbBytes)
		diskR := uint64(bs.DiskR * mbBytes)
		diskW := uint64(bs.DiskW * mbBytes)

		fmt.Fprintf(&sqlBuf,
			"INSERT OR REPLACE INTO host_samples (host, recorded_host, ts, tier, cpu_pct, cpu_max, load1, mem_used, mem_total, swap_used, net_rx_bps, net_tx_bps, disk_r_bps, disk_w_bps, temp_max_c) VALUES (%s, %s, %d, %s, %.4f, %.4f, %.4f, %d, %d, %d, %d, %d, %d, %d, %.2f);\n",
			sqlQuote(canonHost),
			sqlQuote(recordedHost),
			ts,
			sqlQuote(tier),
			bs.CPU,
			cpuMax,
			load1,
			memUsed,
			memTotal,
			swapUsed,
			netRx,
			netTx,
			diskR,
			diskW,
			maxTemp,
		)

		if bs.Disk > 0 {
			fmt.Fprintf(&sqlBuf,
				"INSERT OR REPLACE INTO fs_samples (host, mount, fstype, ts, tier, used_bytes, total_bytes, raw_used_bytes, raw_cap_bytes) VALUES (%s, '/', 'root', %d, %s, %d, %d, 0, 0);\n",
				sqlQuote(canonHost),
				ts,
				sqlQuote(tier),
				uint64(bs.DiskU*gbBytes),
				uint64(bs.Disk*gbBytes),
			)
		}
		imported++
	}

	for oldHost, maxTS := range lastOldHostTS {
		newHost := hostMap[oldHost]
		detail := fmt.Sprintf("Migrated from %s to %s", oldHost, newHost)
		fmt.Fprintf(&sqlBuf,
			"INSERT INTO host_events (host, ts, kind, detail) SELECT %s, %d, 'host_replaced', %s WHERE NOT EXISTS (SELECT 1 FROM host_events WHERE host = %s AND kind = 'host_replaced' AND detail = %s);\n",
			sqlQuote(newHost),
			maxTS,
			sqlQuote(detail),
			sqlQuote(newHost),
			sqlQuote(detail),
		)
	}

	sqlBuf.WriteString("COMMIT;\n")
	if err := s.execSQL(ctx, sqlBuf.String()); err != nil {
		return 0, err
	}
	return imported, nil
}

func parseBeszelTime(s string) int64 {
	s = strings.TrimSpace(s)
	for _, layout := range []string{
		"2006-01-02 15:04:05.999Z07:00",
		"2006-01-02 15:04:05.999Z",
		"2006-01-02 15:04:05Z",
		time.RFC3339,
		"2006-01-02 15:04:05",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC().Unix()
		}
	}
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n
	}
	return 0
}

func mapBeszelTier(statType string) string {
	switch statType {
	case "1m":
		return "30s"
	case "10m", "20m":
		return "5m"
	case "120m", "480m":
		return "1h"
	default:
		return "5m"
	}
}

func sqlQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func sqlInList(items []string) string {
	if len(items) == 0 {
		return "''"
	}
	quoted := make([]string, len(items))
	for i, it := range items {
		quoted[i] = sqlQuote(it)
	}
	return strings.Join(quoted, ", ")
}
