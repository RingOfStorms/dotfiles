package agent

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SystemMetrics holds host-wide CPU, load, memory, swap, and kernel metadata.
type SystemMetrics struct {
	Kernel         string  `json:"kernel,omitempty"`
	UptimeSec      int64   `json:"uptimeSec"`
	Load1          float64 `json:"load1"`
	Load5          float64 `json:"load5"`
	Load15         float64 `json:"load15"`
	CPUPercent     float64 `json:"cpuPercent"`
	CPUCores       int     `json:"cpuCores,omitempty"`
	MemTotalBytes  uint64  `json:"memTotalBytes"`
	MemAvailBytes  uint64  `json:"memAvailBytes"`
	MemUsedBytes   uint64  `json:"memUsedBytes"`
	SwapTotalBytes uint64  `json:"swapTotalBytes"`
	SwapUsedBytes  uint64  `json:"swapUsedBytes"`
}

// DiskRate holds per-block-device throughput in bytes/sec.
type DiskRate struct {
	ReadBytesPerSec  uint64 `json:"readBytesPerSec"`
	WriteBytesPerSec uint64 `json:"writeBytesPerSec"`
}

// NetRate holds per-interface throughput in bytes/sec.
type NetRate struct {
	RxBytesPerSec uint64 `json:"rxBytesPerSec"`
	TxBytesPerSec uint64 `json:"txBytesPerSec"`
}

// TempReading holds one hardware temperature sensor reading.
type TempReading struct {
	Sensor  string  `json:"sensor"`
	Celsius float64 `json:"celsius"`
}

var (
	procRoot = "/proc"
	sysRoot  = "/sys"
)

type cpuTimes struct {
	total uint64
	idle  uint64
}

type diskCounter struct {
	readBytes  uint64
	writeBytes uint64
}

type netCounter struct {
	rxBytes uint64
	txBytes uint64
}

// Sampler maintains rolling counter snapshots to compute instantaneous rates
// (CPU %, disk B/s, network B/s) without blocking HTTP requests.
type Sampler struct {
	mu       sync.RWMutex
	lastAt   time.Time
	lastCPU  cpuTimes
	lastDisk map[string]diskCounter
	lastNet  map[string]netCounter

	cpuPct   float64
	cpuCores int
	diskIO   map[string]DiskRate
	netIO    map[string]NetRate
}

func NewSampler() *Sampler {
	s := &Sampler{
		diskIO: map[string]DiskRate{},
		netIO:  map[string]NetRate{},
	}
	s.SampleAt(time.Now())
	return s
}

func (s *Sampler) SampleAt(now time.Time) {
	cpu, cores, okCPU := readProcStat(procRoot)
	disks := readProcDiskstats(procRoot)
	nets := readProcNetDev(procRoot)

	s.mu.Lock()
	defer s.mu.Unlock()

	if cores > 0 {
		s.cpuCores = cores
	}
	dt := now.Sub(s.lastAt).Seconds()
	if !s.lastAt.IsZero() && dt > 0.05 {
		if okCPU && cpu.total > s.lastCPU.total {
			dTotal := float64(cpu.total - s.lastCPU.total)
			dIdle := float64(cpu.idle - s.lastCPU.idle)
			if dTotal > 0 {
				pct := (1.0 - dIdle/dTotal) * 100.0
				if pct < 0 {
					pct = 0
				} else if pct > 100 {
					pct = 100
				}
				s.cpuPct = float64(int(pct*10+0.5)) / 10.0
			}
		}
		diskIO := make(map[string]DiskRate, len(disks))
		for dev, cur := range disks {
			if prev, ok := s.lastDisk[dev]; ok {
				var r, w uint64
				if cur.readBytes >= prev.readBytes {
					r = uint64(float64(cur.readBytes-prev.readBytes) / dt)
				}
				if cur.writeBytes >= prev.writeBytes {
					w = uint64(float64(cur.writeBytes-prev.writeBytes) / dt)
				}
				diskIO[dev] = DiskRate{ReadBytesPerSec: r, WriteBytesPerSec: w}
			}
		}
		s.diskIO = diskIO

		netIO := make(map[string]NetRate, len(nets))
		for ifc, cur := range nets {
			if prev, ok := s.lastNet[ifc]; ok {
				var rx, tx uint64
				if cur.rxBytes >= prev.rxBytes {
					rx = uint64(float64(cur.rxBytes-prev.rxBytes) / dt)
				}
				if cur.txBytes >= prev.txBytes {
					tx = uint64(float64(cur.txBytes-prev.txBytes) / dt)
				}
				netIO[ifc] = NetRate{RxBytesPerSec: rx, TxBytesPerSec: tx}
			}
		}
		s.netIO = netIO
	}
	if okCPU {
		s.lastCPU = cpu
	}
	s.lastDisk = disks
	s.lastNet = nets
	s.lastAt = now
}

func (s *Sampler) Snapshot() (SystemMetrics, map[string]DiskRate, map[string]NetRate, []TempReading) {
	// If more than 2 seconds elapsed since last sample, refresh synchronously so
	// even a sampler without a background ticker produces live rates on poll.
	s.mu.RLock()
	age := time.Since(s.lastAt)
	s.mu.RUnlock()
	if age >= 2*time.Second {
		s.SampleAt(time.Now())
	}

	s.mu.RLock()
	cpuPct := s.cpuPct
	cores := s.cpuCores
	diskIO := make(map[string]DiskRate, len(s.diskIO))
	for k, v := range s.diskIO {
		diskIO[k] = v
	}
	netIO := make(map[string]NetRate, len(s.netIO))
	for k, v := range s.netIO {
		netIO[k] = v
	}
	s.mu.RUnlock()

	sys := readSystemMetrics(procRoot, cpuPct, cores)
	temps := readHwmonTemps(sysRoot)
	return sys, diskIO, netIO, temps
}

func readProcStat(root string) (cpuTimes, int, bool) {
	f, err := os.Open(filepath.Join(root, "stat"))
	if err != nil {
		return cpuTimes{}, 0, false
	}
	defer f.Close()

	var ct cpuTimes
	var ok bool
	cores := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "cpu ") {
			fields := strings.Fields(line)
			if len(fields) < 5 {
				continue
			}
			var vals []uint64
			for _, s := range fields[1:] {
				v, err := strconv.ParseUint(s, 10, 64)
				if err != nil {
					break
				}
				vals = append(vals, v)
				ct.total += v
			}
			if len(vals) >= 4 {
				ct.idle = vals[3]
				if len(vals) >= 5 {
					ct.idle += vals[4] // iowait
				}
				ok = true
			}
		} else if len(line) > 3 && strings.HasPrefix(line, "cpu") && line[3] >= '0' && line[3] <= '9' {
			cores++
		}
	}
	return ct, cores, ok
}

func readSystemMetrics(root string, cpuPct float64, cores int) SystemMetrics {
	m := SystemMetrics{
		CPUPercent: cpuPct,
		CPUCores:   cores,
	}
	if b, err := os.ReadFile(filepath.Join(root, "sys/kernel/osrelease")); err == nil {
		m.Kernel = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile(filepath.Join(root, "uptime")); err == nil {
		fields := strings.Fields(string(b))
		if len(fields) > 0 {
			if up, err := strconv.ParseFloat(fields[0], 64); err == nil {
				m.UptimeSec = int64(up)
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(root, "loadavg")); err == nil {
		fields := strings.Fields(string(b))
		if len(fields) >= 3 {
			m.Load1, _ = strconv.ParseFloat(fields[0], 64)
			m.Load5, _ = strconv.ParseFloat(fields[1], 64)
			m.Load15, _ = strconv.ParseFloat(fields[2], 64)
		}
	}
	if f, err := os.Open(filepath.Join(root, "meminfo")); err == nil {
		defer f.Close()
		var memTotal, memAvail, memFree, buffers, cached, swapTotal, swapFree uint64
		var hasAvail bool
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			k, rest, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			fields := strings.Fields(rest)
			if len(fields) == 0 {
				continue
			}
			kb, err := strconv.ParseUint(fields[0], 10, 64)
			if err != nil {
				continue
			}
			bytesVal := kb * 1024
			switch k {
			case "MemTotal":
				memTotal = bytesVal
			case "MemAvailable":
				memAvail = bytesVal
				hasAvail = true
			case "MemFree":
				memFree = bytesVal
			case "Buffers":
				buffers = bytesVal
			case "Cached":
				cached = bytesVal
			case "SwapTotal":
				swapTotal = bytesVal
			case "SwapFree":
				swapFree = bytesVal
			}
		}
		if !hasAvail {
			memAvail = memFree + buffers + cached
		}
		m.MemTotalBytes = memTotal
		m.MemAvailBytes = memAvail
		if memTotal >= memAvail {
			m.MemUsedBytes = memTotal - memAvail
		}
		m.SwapTotalBytes = swapTotal
		if swapTotal >= swapFree {
			m.SwapUsedBytes = swapTotal - swapFree
		}
	}
	return m
}

func isWholeBlockDevice(name string) bool {
	if strings.HasPrefix(name, "loop") || strings.HasPrefix(name, "ram") ||
		strings.HasPrefix(name, "zram") || strings.HasPrefix(name, "dm-") ||
		strings.HasPrefix(name, "sr") || strings.HasPrefix(name, "fd") {
		return false
	}
	// nvme0n1 is a whole disk; nvme0n1p1 is a partition.
	if strings.HasPrefix(name, "nvme") || strings.HasPrefix(name, "mmcblk") {
		idx := strings.LastIndexByte(name, 'p')
		if idx > 0 {
			allDigits := true
			for i := idx + 1; i < len(name); i++ {
				if name[i] < '0' || name[i] > '9' {
					allDigits = false
					break
				}
			}
			if allDigits && idx > 4 {
				return false
			}
		}
		return true
	}
	// sda, vda, xvda: trailing digits mean partition (sda1).
	if strings.HasPrefix(name, "sd") || strings.HasPrefix(name, "vd") || strings.HasPrefix(name, "xvd") || strings.HasPrefix(name, "hd") {
		last := name[len(name)-1]
		return last < '0' || last > '9'
	}
	return false
}

func readProcDiskstats(root string) map[string]diskCounter {
	out := map[string]diskCounter{}
	f, err := os.Open(filepath.Join(root, "diskstats"))
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 10 {
			continue
		}
		dev := fields[2]
		if !isWholeBlockDevice(dev) {
			continue
		}
		sectorsRead, err1 := strconv.ParseUint(fields[5], 10, 64)
		sectorsWritten, err2 := strconv.ParseUint(fields[9], 10, 64)
		if err1 == nil && err2 == nil {
			out[dev] = diskCounter{
				readBytes:  sectorsRead * 512,
				writeBytes: sectorsWritten * 512,
			}
		}
	}
	return out
}

func isMonitoredNetDev(name string) bool {
	if name == "lo" || strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "ve-") ||
		strings.HasPrefix(name, "br-") || strings.HasPrefix(name, "podman") ||
		strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "virbr") ||
		strings.HasPrefix(name, "fleet-") {
		return false
	}
	return true
}

func readProcNetDev(root string) map[string]netCounter {
	out := map[string]netCounter{}
	f, err := os.Open(filepath.Join(root, "net/dev"))
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		ifc, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		ifc = strings.TrimSpace(ifc)
		if !isMonitoredNetDev(ifc) {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) < 9 {
			continue
		}
		rx, err1 := strconv.ParseUint(fields[0], 10, 64)
		tx, err2 := strconv.ParseUint(fields[8], 10, 64)
		if err1 == nil && err2 == nil {
			out[ifc] = netCounter{rxBytes: rx, txBytes: tx}
		}
	}
	return out
}
