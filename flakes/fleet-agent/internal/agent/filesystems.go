package agent

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// FilesystemMount describes one mounted filesystem (or deduplicated bcachefs pool).
type FilesystemMount struct {
	Mount      string        `json:"mount"`
	Label      string        `json:"label,omitempty"`
	Device     string        `json:"device,omitempty"`
	FSType     string        `json:"fstype"`
	Subvolumes []string      `json:"subvolumes,omitempty"` // e.g. ["/", "/nix", "/persist", "/.snapshots"] on bcachefs root
	TotalBytes uint64        `json:"totalBytes"`           // usable total bytes (for bcachefs: UsableTotalBytes; otherwise statfs blocks)
	UsedBytes  uint64        `json:"usedBytes"`            // usable/logical used bytes
	AvailBytes uint64        `json:"availBytes"`           // effective available bytes
	Bcachefs   *BcachefsPool `json:"bcachefs,omitempty"`   // non-nil when fstype == "bcachefs"
}

type rawMountEntry struct {
	device string
	mount  string
	fstype string
}

var statfsFunc = func(path string) (total, used, avail uint64, ok bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil || st.Blocks == 0 {
		return 0, 0, 0, false
	}
	bsize := uint64(st.Bsize)
	total = st.Blocks * bsize
	free := st.Bfree * bsize
	avail = st.Bavail * bsize
	if total >= free {
		used = total - free
	}
	return total, used, avail, true
}

func isRealFSType(fstype string) bool {
	switch fstype {
	case "bcachefs", "ext4", "ext3", "xfs", "btrfs", "zfs", "f2fs", "vfat", "ntfs", "fuse.mergerfs":
		return true
	}
	return false
}

func shouldSkipMount(mount, fstype string, explicit map[string]string) bool {
	if _, ok := explicit[mount]; ok {
		return false
	}
	if !isRealFSType(fstype) {
		return true
	}
	if mount == "/boot" || strings.HasPrefix(mount, "/boot/") ||
		strings.HasPrefix(mount, "/var/lib/nixos-containers/") ||
		strings.HasPrefix(mount, "/var/lib/containers/") ||
		strings.HasPrefix(mount, "/run/") ||
		strings.HasPrefix(mount, "/nix/store") {
		return true
	}
	return false
}

// collectFilesystems reads /proc/mounts, deduplicates multi-subvolume bcachefs
// mounts by pool device/UUID, and enriches bcachefs pools with sysfs/usage stats.
func collectFilesystems(procDir, sysDir, stateDir string, configuredMounts []string) []FilesystemMount {
	explicit := map[string]string{} // mount -> custom label
	for _, spec := range configuredMounts {
		m, lbl, ok := strings.Cut(spec, ":")
		if !ok {
			m, lbl = spec, ""
			if parts := strings.SplitN(spec, "__", 2); len(parts) == 2 {
				m, lbl = parts[0], parts[1]
			}
		}
		m = strings.TrimSpace(m)
		if m != "" {
			explicit[m] = strings.TrimSpace(lbl)
		}
	}

	mounts := readProcMounts(procDir)
	bchPools := collectBcachefsPools(sysDir, stateDir)

	// Map block device name (e.g. "sda") -> bcachefs UUID from sysfs pools.
	devToUUID := map[string]string{}
	for uuid, pool := range bchPools {
		for _, d := range pool.Devices {
			if d.Name != "" {
				devToUUID[d.Name] = uuid
			}
		}
	}

	var out []FilesystemMount
	bchGroupIdx := map[string]int{} // bcachefs pool key (UUID or device string) -> index in out
	seenMount := map[string]bool{}

	for _, rm := range mounts {
		if seenMount[rm.mount] || shouldSkipMount(rm.mount, rm.fstype, explicit) {
			continue
		}
		seenMount[rm.mount] = true

		if rm.fstype == "bcachefs" {
			poolUUID := resolveBcachefsUUID(rm.device, devToUUID, bchPools)
			groupKey := poolUUID
			if groupKey == "" {
				groupKey = rm.device
			}
			if idx, exists := bchGroupIdx[groupKey]; exists {
				out[idx].Subvolumes = append(out[idx].Subvolumes, rm.mount)
				// Prefer "/" or "/data" as primary Mount display name
				if rm.mount == "/" || (rm.mount == "/data" && out[idx].Mount != "/") {
					out[idx].Mount = rm.mount
					if lbl := explicit[rm.mount]; lbl != "" {
						out[idx].Label = lbl
					}
				}
				continue
			}

			total, used, avail, ok := statfsFunc(rm.mount)
			var pool *BcachefsPool
			if p, found := bchPools[poolUUID]; found {
				cp := p
				if cp.RawTotalBytes == 0 && ok {
					cp.RawTotalBytes = total
					cp.RawUsedBytes = used
					cp.RawFreeBytes = avail
					recomputeBcachefsDerived(&cp)
				}
				pool = &cp
			} else if ok {
				cp := BcachefsPool{
					UUID:             poolUUID,
					DataReplicas:     1.0,
					MetadataReplicas: 1.0,
					RawTotalBytes:    total,
					RawUsedBytes:     used,
					RawFreeBytes:     avail,
				}
				recomputeBcachefsDerived(&cp)
				pool = &cp
			}

			fsm := FilesystemMount{
				Mount:      rm.mount,
				Label:      mountLabel(rm.mount, explicit),
				Device:     rm.device,
				FSType:     "bcachefs",
				Subvolumes: []string{rm.mount},
				TotalBytes: total,
				UsedBytes:  used,
				AvailBytes: avail,
				Bcachefs:   pool,
			}
			if pool != nil && pool.UsableTotalBytes > 0 {
				fsm.TotalBytes = pool.UsableTotalBytes
				fsm.UsedBytes = pool.LogicalUsedBytes
				fsm.AvailBytes = pool.EffectiveFreeBytes
			}
			bchGroupIdx[groupKey] = len(out)
			out = append(out, fsm)
			continue
		}

		total, used, avail, ok := statfsFunc(rm.mount)
		if !ok {
			continue
		}
		out = append(out, FilesystemMount{
			Mount:      rm.mount,
			Label:      mountLabel(rm.mount, explicit),
			Device:     rm.device,
			FSType:     rm.fstype,
			TotalBytes: total,
			UsedBytes:  used,
			AvailBytes: avail,
		})
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Mount == "/" {
			return true
		}
		if out[j].Mount == "/" {
			return false
		}
		return out[i].Mount < out[j].Mount
	})
	return out
}

func resolveBcachefsUUID(deviceSpec string, devToUUID map[string]string, pools map[string]BcachefsPool) string {
	// deviceSpec in /proc/mounts for bcachefs is "/dev/sda:/dev/sdb:..." or "/dev/disk/by-uuid/<uuid>"
	for _, part := range strings.Split(deviceSpec, ":") {
		part = strings.TrimSpace(part)
		base := filepath.Base(part)
		if _, ok := pools[base]; ok {
			return base
		}
		if uuid, ok := devToUUID[base]; ok {
			return uuid
		}
		// Partition -> parent disk (e.g. sda2 -> sda, nvme0n1p2 -> nvme0n1)
		parent := parentDiskName(base)
		if uuid, ok := devToUUID[parent]; ok {
			return uuid
		}
	}
	return ""
}

func parentDiskName(dev string) string {
	if strings.HasPrefix(dev, "nvme") || strings.HasPrefix(dev, "mmcblk") {
		if idx := strings.LastIndexByte(dev, 'p'); idx > 4 {
			return dev[:idx]
		}
		return dev
	}
	return strings.TrimRight(dev, "0123456789")
}

func mountLabel(mount string, explicit map[string]string) string {
	if lbl := explicit[mount]; lbl != "" {
		return lbl
	}
	if mount == "/" {
		return "root"
	}
	return strings.TrimPrefix(mount, "/")
}

func readProcMounts(procDir string) []rawMountEntry {
	var out []rawMountEntry
	f, err := os.Open(filepath.Join(procDir, "mounts"))
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 3 {
			continue
		}
		out = append(out, rawMountEntry{
			device: fields[0],
			mount:  fields[1],
			fstype: fields[2],
		})
	}
	return out
}
