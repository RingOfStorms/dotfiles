package agent

import (
	"bufio"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// BcachefsDevice describes one member disk inside a bcachefs pool.
type BcachefsDevice struct {
	Name            string `json:"name"`                      // e.g. "sda"
	Label           string `json:"label,omitempty"`           // e.g. "hdd.0"
	State           string `json:"state,omitempty"`           // "rw", "ro", "evacuating", "spare"
	Durability      int    `json:"durability,omitempty"`      // typically 1
	CapacityBytes   uint64 `json:"capacityBytes"`             // bucket_size * nbuckets
	UsedBytes       uint64 `json:"usedBytes"`                 // non-free buckets * bucket_size
	FreeBytes       uint64 `json:"freeBytes"`                 // free buckets * bucket_size
	FragmentedBytes uint64 `json:"fragmentedBytes,omitempty"` // fragmented bytes
	ReadErrors      uint64 `json:"readErrors,omitempty"`
	WriteErrors     uint64 `json:"writeErrors,omitempty"`
	ChecksumErrors  uint64 `json:"checksumErrors,omitempty"`
}

// BcachefsPool holds detailed bcachefs pool metrics, separating raw device
// capacity from usable logical capacity under replication.
type BcachefsPool struct {
	UUID                string           `json:"uuid"`
	Version             string           `json:"version,omitempty"`
	DataReplicas        float64          `json:"dataReplicas"`         // e.g. 2.0 on NAS pool, 1.0 on single disk
	MetadataReplicas    float64          `json:"metadataReplicas"`     // e.g. 2.0
	RawTotalBytes       uint64           `json:"rawTotalBytes"`        // sum of device capacities
	RawUsedBytes        uint64           `json:"rawUsedBytes"`         // raw allocated bytes (incl. replicas & reserved)
	RawFreeBytes        uint64           `json:"rawFreeBytes"`         // raw free bytes
	OnlineReservedBytes uint64           `json:"onlineReservedBytes"`  // online reserved bytes
	UsableTotalBytes    uint64           `json:"usableTotalBytes"`     // rawTotal / dataReplicas
	LogicalUsedBytes    uint64           `json:"logicalUsedBytes"`     // logical user data + btree bytes (or rawUsed / dataReplicas)
	EffectiveFreeBytes  uint64           `json:"effectiveFreeBytes"`   // usableTotal - logicalUsed
	BtreeBytes          uint64           `json:"btreeBytes,omitempty"` // btree metadata bytes
	UserDataBytes       uint64           `json:"userDataBytes,omitempty"`
	CachedBytes         uint64           `json:"cachedBytes,omitempty"`
	ReservedBytes       uint64           `json:"reservedBytes,omitempty"`
	CompressionRatio    float64          `json:"compressionRatio,omitempty"`    // uncompressed / compressed (>1.0 when saving space)
	UncompressedBytes   uint64           `json:"uncompressedBytes,omitempty"`   // from compression stats
	CompressedBytes     uint64           `json:"compressedBytes,omitempty"`     // from compression stats
	Degraded            bool             `json:"degraded,omitempty"`            // true if any device != rw or errors > 0
	TotalReadErrors     uint64           `json:"totalReadErrors,omitempty"`     // sum across devices
	TotalWriteErrors    uint64           `json:"totalWriteErrors,omitempty"`    // sum across devices
	TotalChecksumErrors uint64           `json:"totalChecksumErrors,omitempty"` // sum across devices
	Devices             []BcachefsDevice `json:"devices,omitempty"`             // member devices
}

// bcachefsTimerFile is the optional JSON file written by fleet-agent-bcachefs.timer
// containing raw `bcachefs fs usage -b <mount>` output per mountpoint or UUID.
type bcachefsTimerSnapshot struct {
	Pools map[string]struct {
		UUID      string `json:"uuid"`
		Mount     string `json:"mount"`
		UsageText string `json:"usageText"`
	} `json:"pools"`
}

// collectBcachefsPools reads /sys/fs/bcachefs/<uuid> and merges optional
// `bcachefs fs usage` text snapshots from stateDir/bcachefs.json.
func collectBcachefsPools(sysDir, stateDir string) map[string]BcachefsPool {
	pools := map[string]BcachefsPool{}

	var timerSnap bcachefsTimerSnapshot
	if stateDir != "" {
		if b, err := os.ReadFile(filepath.Join(stateDir, "bcachefs.json")); err == nil {
			_ = json.Unmarshal(b, &timerSnap)
		}
	}

	fsDirs, _ := filepath.Glob(filepath.Join(sysDir, "fs/bcachefs/*-*"))
	sort.Strings(fsDirs)
	for _, dir := range fsDirs {
		st, err := os.Stat(dir)
		if err != nil || !st.IsDir() {
			continue
		}
		uuid := filepath.Base(dir)
		p := readSysfsBcachefsPool(dir, uuid)
		if timerSnap.Pools != nil {
			if ts, ok := timerSnap.Pools[uuid]; ok && ts.UsageText != "" {
				ApplyBcachefsUsageText(&p, ts.UsageText)
			}
		}
		recomputeBcachefsDerived(&p)
		pools[uuid] = p
	}

	// Also allow timer snapshot pools even if sysfs wasn't present (e.g. in tests).
	for k, ts := range timerSnap.Pools {
		uuid := ts.UUID
		if uuid == "" {
			uuid = k
		}
		if _, exists := pools[uuid]; !exists && ts.UsageText != "" {
			p := BcachefsPool{UUID: uuid}
			ApplyBcachefsUsageText(&p, ts.UsageText)
			recomputeBcachefsDerived(&p)
			pools[uuid] = p
		}
	}

	return pools
}

func readSysfsBcachefsPool(dir, uuid string) BcachefsPool {
	p := BcachefsPool{
		UUID:             uuid,
		Version:          firstToken(readTrimmed(filepath.Join(dir, "version_major"))) + "." + firstToken(readTrimmed(filepath.Join(dir, "version_minor"))),
		DataReplicas:     parseFloatDefault(firstToken(readTrimmed(filepath.Join(dir, "options/data_replicas"))), 1.0),
		MetadataReplicas: parseFloatDefault(firstToken(readTrimmed(filepath.Join(dir, "options/metadata_replicas"))), 1.0),
	}
	if p.Version == "." {
		p.Version = firstToken(readTrimmed(filepath.Join(dir, "options/version_upgrade")))
		if p.Version == "compatible" || p.Version == "none" {
			p.Version = ""
		}
	}

	devDirs, _ := filepath.Glob(filepath.Join(dir, "dev-*"))
	sort.Strings(devDirs)
	for _, dd := range devDirs {
		dev := BcachefsDevice{
			Label:      firstToken(readTrimmed(filepath.Join(dd, "label"))),
			State:      firstToken(readTrimmed(filepath.Join(dd, "state"))),
			Durability: int(parseUintDefault(firstToken(readTrimmed(filepath.Join(dd, "durability"))), 1)),
		}
		if link, err := os.Readlink(filepath.Join(dd, "block")); err == nil {
			dev.Name = filepath.Base(link)
		} else {
			dev.Name = filepath.Base(dd)
		}
		bucketSize := parseByteSize(readTrimmed(filepath.Join(dd, "bucket_size")))
		nbuckets := parseUintDefault(firstToken(readTrimmed(filepath.Join(dd, "nbuckets"))), 0)
		if bucketSize > 0 && nbuckets > 0 {
			dev.CapacityBytes = bucketSize * nbuckets
		}
		if freeBuckets, ok := parseAvailableBuckets(readTrimmed(filepath.Join(dd, "freelist_wait"))); ok && bucketSize > 0 {
			dev.FreeBytes = freeBuckets * bucketSize
		}
		parseIoErrors(readTrimmed(filepath.Join(dd, "io_errors")), &dev)
		if dev.State != "" && dev.State != "rw" && dev.State != "read-write" {
			p.Degraded = true
		}
		p.TotalReadErrors += dev.ReadErrors
		p.TotalWriteErrors += dev.WriteErrors
		p.TotalChecksumErrors += dev.ChecksumErrors
		p.RawTotalBytes += dev.CapacityBytes
		p.Devices = append(p.Devices, dev)
	}
	return p
}

func parseAvailableBuckets(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseUint(firstToken(s), 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func parseIoErrors(s string, dev *BcachefsDevice) {
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		k := strings.TrimSuffix(fields[0], ":")
		v, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch k {
		case "read":
			dev.ReadErrors = v
		case "write":
			dev.WriteErrors = v
		case "checksum":
			dev.ChecksumErrors = v
		}
	}
}

// ApplyBcachefsUsageText parses the output of `bcachefs fs usage` (either raw
// byte mode or human-readable mode) into Pool and per-device statistics.
func ApplyBcachefsUsageText(p *BcachefsPool, text string) {
	devByName := map[string]*BcachefsDevice{}
	for i := range p.Devices {
		devByName[p.Devices[i].Name] = &p.Devices[i]
	}

	var curDev *BcachefsDevice
	inCompression := false
	var compUnc, compCom uint64

	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		rawLine := sc.Text()
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}

		// Top-level key: value lines
		if !strings.HasPrefix(rawLine, " ") && !strings.HasPrefix(rawLine, "\t") {
			inCompression = false
			curDev = nil

			if strings.HasPrefix(line, "Compression:") {
				inCompression = true
				continue
			}
			// Device header: e.g. "hdd.0 (device 0):             sda              rw"
			// or "/dev/sda (device 0): ..."
			if strings.Contains(line, "(device ") {
				fields := strings.Fields(line)
				label := fields[0]
				devName := strings.TrimPrefix(label, "/dev/")
				state := ""
				if len(fields) >= 4 {
					state = fields[len(fields)-1]
					cand := strings.TrimPrefix(fields[len(fields)-2], "/dev/")
					if !strings.HasSuffix(cand, "):") {
						devName = cand
					}
				}
				if existing, ok := devByName[devName]; ok {
					curDev = existing
					if curDev.Label == "" && !strings.HasPrefix(label, "/dev/") {
						curDev.Label = label
					}
					if state != "" {
						curDev.State = state
					}
				} else {
					p.Devices = append(p.Devices, BcachefsDevice{
						Name:  devName,
						Label: label,
						State: state,
					})
					curDev = &p.Devices[len(p.Devices)-1]
					devByName[devName] = curDev
				}
				continue
			}

			k, v, ok := strings.Cut(line, ":")
			if ok {
				val := parseByteSize(strings.TrimSpace(v))
				switch strings.TrimSpace(k) {
				case "Capacity":
					if val > 0 {
						p.RawTotalBytes = val
					}
				case "Used":
					if val > 0 {
						p.RawUsedBytes = val
					}
				case "Online reserved":
					p.OnlineReservedBytes = val
				}
			}
			continue
		}

		// Indented lines
		if inCompression {
			fields := strings.Fields(line)
			// e.g. "zstd   1.20T   2.40T   128k" (type, compressed, uncompressed, avg extent)
			if len(fields) >= 3 && fields[0] != "type" {
				c := parseByteSize(fields[1])
				u := parseByteSize(fields[2])
				if c > 0 && u > 0 {
					compCom += c
					compUnc += u
				}
			}
			continue
		}

		if curDev != nil {
			// Per-device table rows:
			// data  bytes  buckets  fragmented
			// free: 5.10T  10444800
			// capacity: 12.0T 24576000
			k, rest, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			k = strings.TrimSpace(k)
			fields := strings.Fields(rest)
			if len(fields) == 0 {
				continue
			}
			val := parseByteSize(fields[0])
			switch k {
			case "free":
				curDev.FreeBytes = val
			case "capacity":
				if val > 0 {
					curDev.CapacityBytes = val
				}
			default:
				if len(fields) >= 3 {
					curDev.FragmentedBytes += parseByteSize(fields[2])
				}
			}
			continue
		}

		// Accounting / replicas lines:
		// e.g. "btree: 2/2 [sda sdb] 42.0G" or "user: 2/2 [sda sdb] 18.4T"
		// or "replicas: btree: 2/2 [sda sdb] 42.0G"
		k, rest, ok := strings.Cut(line, ":")
		if ok {
			k = strings.TrimSpace(k)
			fields := strings.Fields(rest)
			if len(fields) > 0 {
				// First token may be "2/2" or "1/1" (replicas) or byte value
				if slashIdx := strings.IndexByte(fields[0], '/'); slashIdx > 0 {
					repNum, err := strconv.ParseFloat(fields[0][:slashIdx], 64)
					if err == nil && repNum >= 1 {
						if k == "user" && repNum > p.DataReplicas {
							p.DataReplicas = repNum
						}
						if k == "btree" && repNum > p.MetadataReplicas {
							p.MetadataReplicas = repNum
						}
					}
					rawBytes := parseByteSize(fields[len(fields)-1])
					switch k {
					case "btree":
						p.BtreeBytes += rawBytes
					case "user":
						p.UserDataBytes += rawBytes
					case "cached":
						p.CachedBytes += rawBytes
					}
				} else if strings.HasPrefix(k, "reserved") {
					p.ReservedBytes += parseByteSize(fields[len(fields)-1])
				}
			}
		}
	}

	if compCom > 0 && compUnc > 0 {
		p.CompressedBytes = compCom
		p.UncompressedBytes = compUnc
		p.CompressionRatio = math.Round((float64(compUnc)/float64(compCom))*100) / 100
	}
}

func recomputeBcachefsDerived(p *BcachefsPool) {
	if p.DataReplicas < 1.0 {
		p.DataReplicas = 1.0
	}
	if p.MetadataReplicas < 1.0 {
		p.MetadataReplicas = p.DataReplicas
	}

	var sumCap, sumFree uint64
	for i := range p.Devices {
		d := &p.Devices[i]
		if d.CapacityBytes >= d.FreeBytes && d.FreeBytes > 0 {
			d.UsedBytes = d.CapacityBytes - d.FreeBytes
		}
		sumCap += d.CapacityBytes
		sumFree += d.FreeBytes
		if d.State != "" && d.State != "rw" && d.State != "read-write" {
			p.Degraded = true
		}
	}
	if p.RawTotalBytes == 0 && sumCap > 0 {
		p.RawTotalBytes = sumCap
	}
	if p.RawUsedBytes == 0 && sumCap > sumFree && sumFree > 0 {
		p.RawUsedBytes = sumCap - sumFree
	}
	if p.RawTotalBytes >= p.RawUsedBytes {
		p.RawFreeBytes = p.RawTotalBytes - p.RawUsedBytes
	}

	if p.RawTotalBytes > 0 {
		p.UsableTotalBytes = uint64(float64(p.RawTotalBytes) / p.DataReplicas)
	}
	if p.UserDataBytes > 0 || p.BtreeBytes > 0 {
		logicalUser := uint64(float64(p.UserDataBytes) / p.DataReplicas)
		logicalBtree := uint64(float64(p.BtreeBytes) / p.MetadataReplicas)
		p.LogicalUsedBytes = logicalUser + logicalBtree
		// If rawUsed / dataReplicas is larger (due to reserved/other blocks), use rawUsed / dataReplicas for conservative capacity bar.
		rawScaled := uint64(float64(p.RawUsedBytes) / p.DataReplicas)
		if rawScaled > p.LogicalUsedBytes {
			p.LogicalUsedBytes = rawScaled
		}
	} else if p.RawUsedBytes > 0 {
		p.LogicalUsedBytes = uint64(float64(p.RawUsedBytes) / p.DataReplicas)
	}
	if p.UsableTotalBytes >= p.LogicalUsedBytes {
		p.EffectiveFreeBytes = p.UsableTotalBytes - p.LogicalUsedBytes
	}
	if p.TotalReadErrors > 0 || p.TotalWriteErrors > 0 || p.TotalChecksumErrors > 0 {
		p.Degraded = true
	}
}

func firstToken(s string) string {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

func parseUintDefault(s string, def uint64) uint64 {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return def
	}
	return v
}

func parseFloatDefault(s string, def float64) float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return def
	}
	return v
}

// parseByteSize parses integers or unit-suffixed strings ("512k", "12.0T", "42.5 GiB", "1048576").
func parseByteSize(s string) uint64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	fields := strings.Fields(s)
	tok := fields[0]
	if v, err := strconv.ParseUint(tok, 10, 64); err == nil {
		return v
	}
	// Split numeric prefix and unit suffix
	i := 0
	for i < len(tok) && ((tok[i] >= '0' && tok[i] <= '9') || tok[i] == '.') {
		i++
	}
	if i == 0 {
		return 0
	}
	num, err := strconv.ParseFloat(tok[:i], 64)
	if err != nil || num < 0 {
		return 0
	}
	unit := strings.ToUpper(strings.TrimSpace(tok[i:]))
	if unit == "" && len(fields) > 1 {
		unit = strings.ToUpper(fields[1])
	}
	unit = strings.TrimSuffix(unit, "IB")
	unit = strings.TrimSuffix(unit, "B")
	var mult float64 = 1
	switch unit {
	case "K":
		mult = 1 << 10
	case "M":
		mult = 1 << 20
	case "G":
		mult = 1 << 30
	case "T":
		mult = 1 << 40
	case "P":
		mult = 1 << 50
	}
	return uint64(num * mult)
}
