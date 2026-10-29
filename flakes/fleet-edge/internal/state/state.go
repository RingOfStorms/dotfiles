// Package state polls each host's status endpoint and merges the results
// with the static inventory and SQLite historical store into the data the
// dashboard renders.
package state

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

// ServiceStatus is one entry of a host status response's "services" map.
type ServiceStatus struct {
	Unit       string `json:"unit"`
	Active     string `json:"active"`
	Enabled    bool   `json:"enabled"`
	Kind       string `json:"kind,omitempty"`
	LastBackup string `json:"lastBackup,omitempty"`
}

// BackupStaleAfter: a service whose last successful backup is older than
// this is flagged stale (the nightly job missed at least one run).
const BackupStaleAfter = 36 * time.Hour

// SystemMetrics holds host-wide CPU, load, memory, swap, and uptime metrics.
type SystemMetrics struct {
	Kernel         string  `json:"kernel,omitempty"`
	UptimeSec      uint64  `json:"uptimeSec"`
	Load1          float64 `json:"load1"`
	Load5          float64 `json:"load5"`
	Load15         float64 `json:"load15"`
	CPUCores       int     `json:"cpuCores,omitempty"`
	CPUPercent     float64 `json:"cpuPercent"`
	MemTotalBytes  uint64  `json:"memTotalBytes"`
	MemUsedBytes   uint64  `json:"memUsedBytes"`
	MemAvailBytes  uint64  `json:"memAvailBytes"`
	SwapTotalBytes uint64  `json:"swapTotalBytes"`
	SwapUsedBytes  uint64  `json:"swapUsedBytes"`
}

// BcachefsDevice describes one member disk inside a bcachefs pool.
type BcachefsDevice struct {
	Name          string `json:"name"`
	Label         string `json:"label"`
	State         string `json:"state"`
	SizeBytes     uint64 `json:"sizeBytes"`
	CapacityBytes uint64 `json:"capacityBytes,omitempty"`
	UsedBytes     uint64 `json:"usedBytes"`
	FreeBytes     uint64 `json:"freeBytes"`
	BucketSize    uint64 `json:"bucketSize,omitempty"`
	IOErrorsRead  uint64 `json:"ioErrorsRead"`
	IOErrorsWrite uint64 `json:"ioErrorsWrite"`
	IOErrorsCsum  uint64 `json:"ioErrorsChecksum"`
}

// BcachefsCompression reports pool compression ratio.
type BcachefsCompression struct {
	Type              string `json:"type"`
	CompressedBytes   uint64 `json:"compressedBytes"`
	UncompressedBytes uint64 `json:"uncompressedBytes"`
}

// BcachefsDataTypeBreakdown reports raw bytes per data type (user, btree, cached, etc.).
type BcachefsDataTypeBreakdown struct {
	Type     string `json:"type"`
	Replicas string `json:"replicas,omitempty"`
	Devices  string `json:"devices,omitempty"`
	Bytes    uint64 `json:"bytes"`
}

// BcachefsInfo holds detailed bcachefs pool health and capacity metrics.
type BcachefsInfo struct {
	UUID                string                      `json:"uuid,omitempty"`
	Version             string                      `json:"version,omitempty"`
	Degraded            bool                        `json:"degraded,omitempty"`
	RawCapacityBytes    uint64                      `json:"rawCapacityBytes"`
	RawTotalBytes       uint64                      `json:"rawTotalBytes,omitempty"`
	RawUsedBytes        uint64                      `json:"rawUsedBytes"`
	RawReservedBytes    uint64                      `json:"rawReservedBytes"`
	OnlineReservedBytes uint64                      `json:"onlineReservedBytes,omitempty"`
	UsableTotalBytes    uint64                      `json:"usableTotalBytes"`
	UsableUsedBytes     uint64                      `json:"usableUsedBytes"`
	LogicalUsedBytes    uint64                      `json:"logicalUsedBytes,omitempty"`
	UsableFreeBytes     uint64                      `json:"usableFreeBytes"`
	EffectiveFreeBytes  uint64                      `json:"effectiveFreeBytes,omitempty"`
	DataReplicas        float64                     `json:"dataReplicas"`
	MetadataReplicas    float64                     `json:"metadataReplicas"`
	Compression         *BcachefsCompression        `json:"compression,omitempty"`
	DataTypes           []BcachefsDataTypeBreakdown `json:"dataTypes,omitempty"`
	Devices             []BcachefsDevice            `json:"devices,omitempty"`
}

// FilesystemMount describes one mounted filesystem (or deduplicated bcachefs pool).
type FilesystemMount struct {
	Mount       string        `json:"mount"`
	Submounts   []string      `json:"submounts,omitempty"`
	Device      string        `json:"device"`
	FSType      string        `json:"fstype"`
	UUID        string        `json:"uuid,omitempty"`
	TotalBytes  uint64        `json:"totalBytes"`
	UsedBytes   uint64        `json:"usedBytes"`
	AvailBytes  uint64        `json:"availBytes"`
	UsedPercent float64       `json:"usedPercent"`
	Bcachefs    *BcachefsInfo `json:"bcachefs,omitempty"`
}

// DiskIORate holds rolling read/write throughput for a block device.
type DiskIORate struct {
	ReadBytesPerSec  uint64 `json:"readBytesPerSec"`
	WriteBytesPerSec uint64 `json:"writeBytesPerSec"`
}

// NetIORate holds rolling rx/tx throughput for a network interface.
type NetIORate struct {
	RxBytesPerSec uint64 `json:"rxBytesPerSec"`
	TxBytesPerSec uint64 `json:"txBytesPerSec"`
}

// TempSensor represents one hwmon temperature reading.
type TempSensor struct {
	Sensor  string  `json:"sensor"`
	Label   string  `json:"label,omitempty"`
	Celsius float64 `json:"celsius"`
}

// MaxPrimaryTempC returns the headline host temperature from a set of hwmon
// sensor readings, filtering out known secondary hotspot / VRAM / auxiliary
// controller sensors that otherwise run hotter than the primary package
// reading and would make the headline number misleadingly alarming:
//
//   - amdgpu: only "amdgpu:edge" (or an unlabeled "amdgpu") is considered;
//     "amdgpu:junction" and "amdgpu:mem" are internal hotspot/VRAM readings.
//   - nvme: only "nvme:Composite" (or an unlabeled "nvme") is considered;
//     "nvme:Sensor 1/2/3" are auxiliary controller sensors.
//   - k10temp: if any Tccd*/Tdie reading is present, "k10temp:Tctl" (a
//     fan-control target, not actual die temp) is ignored. If Tctl is the
//     only k10temp sensor present, it is used as a fallback.
//
// If filtering would leave no sensors at all, it falls back to the max of
// all readings so a host is never reported with zero temperature.
func MaxPrimaryTempC(temps []TempSensor) float64 {
	hasK10DieTemp := false
	for _, t := range temps {
		if strings.HasPrefix(t.Sensor, "k10temp:Tccd") || t.Sensor == "k10temp:Tdie" {
			hasK10DieTemp = true
			break
		}
	}

	var max float64
	found := false
	for _, t := range temps {
		switch {
		case t.Sensor == "amdgpu:junction" || t.Sensor == "amdgpu:mem":
			continue
		case strings.HasPrefix(t.Sensor, "nvme:") && t.Sensor != "nvme:Composite":
			continue
		case t.Sensor == "k10temp:Tctl" && hasK10DieTemp:
			continue
		}
		found = true
		if t.Celsius > max {
			max = t.Celsius
		}
	}
	if !found {
		for _, t := range temps {
			if t.Celsius > max {
				max = t.Celsius
			}
		}
	}
	return max
}

// SmartDrive holds normalized drive health attributes from `smartctl -j -a`.
type SmartDrive struct {
	Device              string `json:"device"`
	Model               string `json:"model,omitempty"`
	Serial              string `json:"serial,omitempty"`
	Protocol            string `json:"protocol,omitempty"`
	RotationRate        int    `json:"rotationRate,omitempty"`
	Healthy             bool   `json:"healthy"`
	Standby             bool   `json:"standby"`
	TempC               int    `json:"tempC,omitempty"`
	PowerOnHours        uint64 `json:"powerOnHours,omitempty"`
	ReallocatedSectors  uint64 `json:"reallocatedSectors"`
	PendingSectors      uint64 `json:"pendingSectors"`
	UncorrectableErrors uint64 `json:"uncorrectableErrors"`
	WearPercentUsed     int    `json:"wearPercentUsed,omitempty"`
	MediaErrors         uint64 `json:"mediaErrors,omitempty"`
	UpdatedAt           string `json:"updatedAt,omitempty"`
}

// Fail2banJail summarizes one active fail2ban jail.
type Fail2banJail struct {
	Name            string   `json:"name"`
	CurrentlyBanned int      `json:"currentlyBanned"`
	TotalBanned     int      `json:"totalBanned"`
	BannedIPs       []string `json:"bannedIPs"`
}

// Fail2banBanEvent represents one historical or active ban record.
type Fail2banBanEvent struct {
	Jail       string `json:"jail"`
	IP         string `json:"ip"`
	BannedAt   string `json:"bannedAt"`
	BanSeconds int64  `json:"banSeconds"`
	Failures   int    `json:"failures"`
	Active     bool   `json:"active"`
}

// Fail2banSummary holds active jails and recent ban events.
type Fail2banSummary struct {
	UpdatedAt  string             `json:"updatedAt,omitempty"`
	Jails      []Fail2banJail     `json:"jails"`
	RecentBans []Fail2banBanEvent `json:"recentBans,omitempty"`
}

// HostStatus is the full JSON document a host's status endpoint returns.
type HostStatus struct {
	Host        string                   `json:"host"`
	Time        string                   `json:"time"`
	Services    map[string]ServiceStatus `json:"services"`
	HostUnits   map[string]ServiceStatus `json:"hostUnits,omitempty"`
	System      *SystemMetrics           `json:"system,omitempty"`
	Filesystems []FilesystemMount        `json:"filesystems,omitempty"`
	DiskIO      map[string]DiskIORate    `json:"diskIO,omitempty"`
	NetIO       map[string]NetIORate     `json:"netIO,omitempty"`
	Temps       []TempSensor             `json:"temps,omitempty"`
	Smart       []SmartDrive             `json:"smart,omitempty"`
	Fail2ban    *Fail2banSummary         `json:"fail2ban,omitempty"`
}

// HostPoll records the outcome of the most recent poll of one host.
type HostPoll struct {
	Host     string      `json:"host"`
	URL      string      `json:"url"`
	OK       bool        `json:"ok"`
	Error    string      `json:"error,omitempty"`
	PolledAt time.Time   `json:"polledAt"`
	Status   *HostStatus `json:"status,omitempty"`
}

// ServiceView is one row of the merged dashboard state.
type ServiceView struct {
	Name         string            `json:"name"`
	Kind         string            `json:"kind"`
	Description  string            `json:"description"`
	DeclaredHost string            `json:"declaredHost"`
	Active       string            `json:"active"` // "unknown" if no data
	Enabled      *bool             `json:"enabled,omitempty"`
	Unit         string            `json:"unit,omitempty"`
	Routes       []inventory.Route `json:"routes"`
	Backup       string            `json:"backup"`
	LastBackup   *time.Time        `json:"lastBackup,omitempty"`
	BackupAge    string            `json:"backupAge,omitempty"`
}

// HostView is one row/card of the /hosts page.
type HostView struct {
	Host        string      `json:"host"`
	OverlayIP   string      `json:"overlayIp"`
	LanIP       string      `json:"lanIp"`
	Role        string      `json:"role"`
	AlwaysOn    bool        `json:"alwaysOn"`
	Replaces    []string    `json:"replaces,omitempty"`
	Reachable   bool        `json:"reachable"`
	HasEndpoint bool        `json:"hasEndpoint"`
	StateBadge  string      `json:"stateBadge"` // "online", "down", "sleeping", "no-endpoint"
	LastSeen    time.Time   `json:"lastSeen,omitempty"`
	LastSeenAge string      `json:"lastSeenAge,omitempty"`
	Error       string      `json:"error,omitempty"`
	PolledAt    time.Time   `json:"polledAt"`
	Status      *HostStatus `json:"status,omitempty"`
	MaxTempC    float64     `json:"maxTempC,omitempty"`
	SmartOK     int         `json:"smartOk"`
	SmartTotal  int         `json:"smartTotal"`
	SmartFailed int         `json:"smartFailed"`
	BannedCount int         `json:"bannedCount"`

	// ContainerHost is true when the inventory declares the host runs
	// containers: it is listed in containerHosts, or at least one service is
	// declared on it (an unplaced service, host = "", declares nothing). A host
	// that only answers polls stays false; it is a declaration, not something a
	// poll can add or remove.
	ContainerHost bool `json:"containerHost"`
}

// Merged is the full state served by /api/state.json and rendered by the
// templates.
type Merged struct {
	GeneratedAt time.Time     `json:"generatedAt"`
	Services    []ServiceView `json:"services"`
	Hosts       []HostView    `json:"hosts"`
}

// Poller periodically fetches every host's status endpoint, persists metrics to
// SQLite (if configured), and keeps the latest Merged view available via Current.
type Poller struct {
	inv        *inventory.Inventory
	urlTmpl    string
	httpClient *http.Client
	store      *store.Store

	mu         sync.RWMutex
	polls      map[string]HostPoll // keyed by host name
	lastStates map[string]lastKnownHost
}

type lastKnownHost struct {
	LastSeen time.Time
	Status   *HostStatus
}

// NewPoller builds a poller for inv, substituting {overlayIp} (and
// {lanIp}, {host} for flexibility) into urlTmpl per host.
func NewPoller(inv *inventory.Inventory, urlTmpl string, timeout time.Duration) *Poller {
	return &Poller{
		inv:        inv,
		urlTmpl:    urlTmpl,
		httpClient: &http.Client{Timeout: timeout},
		polls:      map[string]HostPoll{},
		lastStates: map[string]lastKnownHost{},
	}
}

// SetStore attaches a SQLite store to persist time-series samples and preload
// last-known host states across restarts.
func (p *Poller) SetStore(st *store.Store) {
	p.mu.Lock()
	p.store = st
	p.mu.Unlock()
	if st == nil {
		return
	}
	if loaded, err := st.LoadAllLastStates(context.Background()); err == nil {
		p.mu.Lock()
		for host, ls := range loaded {
			var doc HostStatus
			if err := json.Unmarshal(ls.StatusRaw, &doc); err == nil {
				normalizeHostStatus(&doc)
				p.lastStates[host] = lastKnownHost{
					LastSeen: ls.LastSeen,
					Status:   &doc,
				}
			}
		}
		p.mu.Unlock()
	}
}

// Store returns the attached SQLite store (or nil).
func (p *Poller) Store() *store.Store {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.store
}

// Inventory returns the static inventory.
func (p *Poller) Inventory() *inventory.Inventory {
	return p.inv
}

// StatusURLFor returns the resolved status.json URL for host.
func (p *Poller) StatusURLFor(host string) (string, bool) {
	if p.inv == nil {
		return "", false
	}
	h, ok := p.inv.Hosts[host]
	if !ok {
		return "", false
	}
	return hostURL(p.urlTmpl, host, h), true
}

func hostURL(tmpl, host string, h inventory.Host) string {
	overlay := ""
	if h.OverlayIP != nil {
		overlay = *h.OverlayIP
	}
	lan := ""
	if h.LanIP != nil {
		lan = *h.LanIP
	}
	r := strings.NewReplacer(
		"{overlayIp}", overlay,
		"{lanIp}", lan,
		"{host}", host,
	)
	return r.Replace(tmpl)
}

// PollOnce fetches every host's status endpoint once and updates state.
func (p *Poller) PollOnce(ctx context.Context) {
	var wg sync.WaitGroup
	for _, name := range p.inv.PolledHosts() {
		name, h := name, p.inv.Hosts[name]
		wg.Add(1)
		go func() {
			defer wg.Done()
			p.pollHost(ctx, name, h)
		}()
	}
	wg.Wait()
}

func (p *Poller) pollHost(ctx context.Context, name string, h inventory.Host) {
	url := hostURL(p.urlTmpl, name, h)
	now := time.Now().UTC()
	poll := HostPoll{Host: name, URL: url, PolledAt: now}

	// Intermittent laptops/workstations get a short 1.2s timeout so sleeping
	// machines never slow down a poll cycle.
	reqCtx := ctx
	var cancel context.CancelFunc
	if !h.IsAlwaysOn() {
		reqCtx, cancel = context.WithTimeout(ctx, 1200*time.Millisecond)
		defer cancel()
	}

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll, nil)
		return
	}
	resp, err := p.httpClient.Do(req)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll, nil)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		poll.Error = fmt.Sprintf("status %d", resp.StatusCode)
		p.setPoll(name, poll, nil)
		return
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		poll.Error = err.Error()
		p.setPoll(name, poll, nil)
		return
	}
	var st HostStatus
	if err := json.Unmarshal(body, &st); err != nil {
		poll.Error = fmt.Sprintf("bad json: %v", err)
		p.setPoll(name, poll, nil)
		return
	}
	normalizeHostStatus(&st)
	poll.OK = true
	poll.Status = &st
	p.setPoll(name, poll, body)
}

// normalizeHostStatus canonicalizes legacy bcachefs/filesystem fields in-place
// before a HostStatus is published to Poller state or converted into store samples.
func normalizeHostStatus(st *HostStatus) {
	if st == nil {
		return
	}
	for i := range st.Filesystems {
		fs := &st.Filesystems[i]
		if fs.Bcachefs != nil {
			bch := fs.Bcachefs
			if bch.RawCapacityBytes == 0 && bch.RawTotalBytes > 0 {
				bch.RawCapacityBytes = bch.RawTotalBytes
			}
			if bch.RawReservedBytes == 0 && bch.OnlineReservedBytes > 0 {
				bch.RawReservedBytes = bch.OnlineReservedBytes
			}
			if bch.UsableUsedBytes == 0 && bch.LogicalUsedBytes > 0 {
				bch.UsableUsedBytes = bch.LogicalUsedBytes
			}
			if bch.UsableFreeBytes == 0 && bch.EffectiveFreeBytes > 0 {
				bch.UsableFreeBytes = bch.EffectiveFreeBytes
			}
			for j := range bch.Devices {
				d := &bch.Devices[j]
				if d.SizeBytes == 0 && d.CapacityBytes > 0 {
					d.SizeBytes = d.CapacityBytes
				}
			}
		}
		if fs.UsedPercent == 0 && fs.UsedBytes > 0 && fs.TotalBytes > 0 {
			fs.UsedPercent = (float64(fs.UsedBytes) / float64(fs.TotalBytes)) * 100
		}
	}
}

// cloneNormalizedHostStatus returns a deep copy of st with normalized fields so
// callers of Current()/Merge() never mutate shared pointers or alias slices.
func cloneNormalizedHostStatus(st *HostStatus) *HostStatus {
	if st == nil {
		return nil
	}
	cp := *st
	if len(st.Filesystems) > 0 {
		cp.Filesystems = make([]FilesystemMount, len(st.Filesystems))
		for i, fs := range st.Filesystems {
			if len(fs.Submounts) > 0 {
				fs.Submounts = append([]string(nil), fs.Submounts...)
			}
			if fs.Bcachefs != nil {
				bch := *fs.Bcachefs
				if bch.Compression != nil {
					comp := *bch.Compression
					bch.Compression = &comp
				}
				if len(bch.DataTypes) > 0 {
					bch.DataTypes = append([]BcachefsDataTypeBreakdown(nil), bch.DataTypes...)
				}
				if len(bch.Devices) > 0 {
					bch.Devices = append([]BcachefsDevice(nil), bch.Devices...)
				}
				fs.Bcachefs = &bch
			}
			cp.Filesystems[i] = fs
		}
	}
	normalizeHostStatus(&cp)
	return &cp
}

func (p *Poller) setPoll(name string, poll HostPoll, rawJSON []byte) {
	if poll.Status != nil {
		normalizeHostStatus(poll.Status)
	}
	p.mu.Lock()
	p.polls[name] = poll
	if poll.OK && poll.Status != nil {
		p.lastStates[name] = lastKnownHost{
			LastSeen: poll.PolledAt,
			Status:   poll.Status,
		}
	}
	st := p.store
	p.mu.Unlock()

	if poll.OK && poll.Status != nil && st != nil {
		sample, fsSamples := buildStoreSamples(name, poll.PolledAt, poll.Status)
		_ = st.RecordPoll(context.Background(), sample, fsSamples, rawJSON)
	}
}

func buildStoreSamples(host string, polledAt time.Time, st *HostStatus) (store.Sample, []store.FSSample) {
	ts := polledAt.Unix()
	s := store.Sample{
		Host:         host,
		RecordedHost: host,
		TS:           ts,
		Tier:         "30s",
	}
	if st.System != nil {
		s.CPUPct = st.System.CPUPercent
		s.CPUMax = st.System.CPUPercent
		s.Load1 = st.System.Load1
		s.MemUsed = st.System.MemUsedBytes
		s.MemTotal = st.System.MemTotalBytes
		s.SwapUsed = st.System.SwapUsedBytes
	}
	for _, nr := range st.NetIO {
		s.NetRxBps += nr.RxBytesPerSec
		s.NetTxBps += nr.TxBytesPerSec
	}
	for _, dr := range st.DiskIO {
		s.DiskRBps += dr.ReadBytesPerSec
		s.DiskWBps += dr.WriteBytesPerSec
	}
	s.TempMaxC = MaxPrimaryTempC(st.Temps)

	var fsOut []store.FSSample
	for _, fs := range st.Filesystems {
		row := store.FSSample{
			Host:       host,
			Mount:      fs.Mount,
			FSType:     fs.FSType,
			TS:         ts,
			Tier:       "30s",
			UsedBytes:  fs.UsedBytes,
			TotalBytes: fs.TotalBytes,
		}
		if fs.Bcachefs != nil {
			row.RawUsedBytes = fs.Bcachefs.RawUsedBytes
			row.RawCapBytes = fs.Bcachefs.RawCapacityBytes
			if row.RawCapBytes == 0 {
				row.RawCapBytes = fs.Bcachefs.RawTotalBytes
			}
		}
		fsOut = append(fsOut, row)
	}
	return s, fsOut
}

// Run polls every interval until ctx is cancelled. It polls once
// immediately before the first sleep.
func (p *Poller) Run(ctx context.Context, interval time.Duration) {
	p.PollOnce(ctx)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.PollOnce(ctx)
		}
	}
}

// Current merges the latest polls with the static inventory into the
// dashboard view. Safe to call concurrently with Run.
func (p *Poller) Current() Merged {
	p.mu.RLock()
	polls := make(map[string]HostPoll, len(p.polls))
	for k, v := range p.polls {
		polls[k] = v
	}
	last := make(map[string]lastKnownHost, len(p.lastStates))
	for k, v := range p.lastStates {
		last[k] = v
	}
	p.mu.RUnlock()

	return mergeWithLast(p.inv, polls, last, time.Now())
}

// Merge combines inventory with a set of host polls (keyed by host name)
// into the dashboard view. Exported standalone for testing without a
// running Poller.
func Merge(inv *inventory.Inventory, polls map[string]HostPoll) Merged {
	return MergeAt(inv, polls, time.Now())
}

// MergeAt is Merge with an explicit clock (backup ages).
func MergeAt(inv *inventory.Inventory, polls map[string]HostPoll, now time.Time) Merged {
	return mergeWithLast(inv, polls, nil, now)
}

func mergeWithLast(inv *inventory.Inventory, polls map[string]HostPoll, last map[string]lastKnownHost, now time.Time) Merged {
	m := Merged{GeneratedAt: now.UTC()}

	svcNames := make([]string, 0, len(inv.Services))
	for name := range inv.Services {
		svcNames = append(svcNames, name)
	}
	sort.Strings(svcNames)

	for _, name := range svcNames {
		svc := inv.Services[name]
		view := ServiceView{
			Name:         name,
			Kind:         svc.Kind,
			Description:  svc.Description,
			DeclaredHost: svc.Host,
			Active:       "unknown",
			Backup:       "unknown",
		}
		routeNames := make([]string, 0, len(svc.Routes))
		for rn := range svc.Routes {
			routeNames = append(routeNames, rn)
		}
		sort.Strings(routeNames)
		for _, rn := range routeNames {
			view.Routes = append(view.Routes, svc.Routes[rn])
		}
		if poll, ok := polls[svc.Host]; ok && poll.OK && poll.Status != nil {
			if ss, ok := poll.Status.Services[name]; ok {
				view.Active = ss.Active
				enabled := ss.Enabled
				view.Enabled = &enabled
				view.Unit = ss.Unit
				view.Backup = "none"
				if t, err := time.Parse(time.RFC3339, ss.LastBackup); err == nil {
					t = t.UTC()
					age := now.Sub(t)
					view.LastBackup, view.BackupAge, view.Backup = &t, FormatAge(age), "ok"
					if age > BackupStaleAfter {
						view.Backup = "stale"
					}
				}
			}
		}
		m.Services = append(m.Services, view)
	}

	polled := map[string]bool{}
	for _, n := range inv.PolledHosts() {
		polled[n] = true
	}

	// Container hosts are declared, not observed: the inventory names them, or
	// a service is declared on them. A host that only answers polls stays
	// false; a declared container host stays true with zero containers.
	containerHost := map[string]bool{}
	for _, n := range inv.ContainerHosts {
		containerHost[n] = true
	}
	for _, svc := range inv.Services {
		if svc.Host != "" {
			containerHost[svc.Host] = true
		}
	}

	hostNames := make([]string, 0, len(inv.Hosts))
	for name := range inv.Hosts {
		hostNames = append(hostNames, name)
	}
	sort.Strings(hostNames)

	for _, name := range hostNames {
		h := inv.Hosts[name]
		role := h.Role
		if role == "" {
			role = "server"
		}
		hv := HostView{
			Host:          name,
			Role:          role,
			AlwaysOn:      h.IsAlwaysOn(),
			Replaces:      h.Replaces,
			HasEndpoint:   polled[name],
			ContainerHost: containerHost[name],
			StateBadge:    "no-endpoint",
		}
		if h.OverlayIP != nil {
			hv.OverlayIP = *h.OverlayIP
		}
		if h.LanIP != nil {
			hv.LanIP = *h.LanIP
		}
		if hv.HasEndpoint {
			if !hv.AlwaysOn {
				hv.StateBadge = "sleeping"
			} else {
				hv.StateBadge = "down"
			}
		}
		if poll, ok := polls[name]; ok && hv.HasEndpoint {
			hv.Reachable = poll.OK
			hv.Error = poll.Error
			hv.PolledAt = poll.PolledAt
			if poll.OK {
				hv.StateBadge = "online"
				hv.LastSeen = poll.PolledAt
				hv.LastSeenAge = FormatAge(now.Sub(poll.PolledAt))
				hv.Status = cloneNormalizedHostStatus(poll.Status)
			}
		}
		if hv.Status == nil && last != nil {
			if lk, ok := last[name]; ok && lk.Status != nil {
				hv.Status = cloneNormalizedHostStatus(lk.Status)
				hv.LastSeen = lk.LastSeen
				if !lk.LastSeen.IsZero() {
					hv.LastSeenAge = FormatAge(now.Sub(lk.LastSeen))
				}
			}
		}
		if hv.Status != nil {
			hv.MaxTempC = MaxPrimaryTempC(hv.Status.Temps)
			for _, d := range hv.Status.Smart {
				hv.SmartTotal++
				if d.Healthy {
					hv.SmartOK++
				} else {
					hv.SmartFailed++
				}
			}
			if hv.Status.Fail2ban != nil {
				for _, j := range hv.Status.Fail2ban.Jails {
					hv.BannedCount += j.CurrentlyBanned
				}
			}
		}
		m.Hosts = append(m.Hosts, hv)
	}

	return m
}

// FormatAge renders a duration coarsely: "<1m", "42m", "5h", "2d 3h".
// Negative ages (clock skew) count as zero.
func FormatAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	days := int(d / (24 * time.Hour))
	h := int((d % (24 * time.Hour)) / time.Hour)
	if h == 0 {
		return fmt.Sprintf("%dd", days)
	}
	return fmt.Sprintf("%dd %dh", days, h)
}
