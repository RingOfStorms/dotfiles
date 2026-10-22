package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SmartDrive holds normalized drive health attributes from `smartctl -j -a`.
type SmartDrive struct {
	Device              string `json:"device"`                        // e.g. "/dev/sda"
	Name                string `json:"name,omitempty"`                // e.g. "sda"
	Model               string `json:"model,omitempty"`               // e.g. "ST12000NT001-3LX101"
	Serial              string `json:"serial,omitempty"`              // e.g. "ZRT2GA17"
	Protocol            string `json:"protocol,omitempty"`            // "ATA" | "NVMe" | "SCSI"
	Rotational          bool   `json:"rotational,omitempty"`          // true for HDD
	CapacityBytes       uint64 `json:"capacityBytes,omitempty"`       // user_capacity.bytes
	Healthy             bool   `json:"healthy"`                       // smart_status.passed
	Standby             bool   `json:"standby,omitempty"`             // true if drive was in standby (-n standby)
	TempC               int    `json:"tempC,omitempty"`               // temperature.current
	PowerOnHours        uint64 `json:"powerOnHours,omitempty"`        // power_on_time.hours
	ReallocatedSectors  uint64 `json:"reallocatedSectors,omitempty"`  // ATA attr 5
	PendingSectors      uint64 `json:"pendingSectors,omitempty"`      // ATA attr 197
	UncorrectableErrors uint64 `json:"uncorrectableErrors,omitempty"` // ATA attr 198 / NVMe media_errors
	CRCErrors           uint64 `json:"crcErrors,omitempty"`           // ATA attr 199
	WearPercentUsed     int    `json:"wearPercentUsed,omitempty"`     // NVMe percentage_used (0-100)
	UpdatedAt           string `json:"updatedAt,omitempty"`
}

// Fail2banBan represents one active or historical ban record.
type Fail2banBan struct {
	Jail       string `json:"jail"`
	IP         string `json:"ip"`
	BannedAt   string `json:"bannedAt,omitempty"`
	BanSeconds int64  `json:"banSeconds,omitempty"`
	Failures   int    `json:"failures,omitempty"`
	Active     bool   `json:"active"`
}

// Fail2banJail represents one active fail2ban jail.
type Fail2banJail struct {
	Name            string   `json:"name"`
	CurrentlyBanned int      `json:"currentlyBanned"`
	TotalBanned     int      `json:"totalBanned"`
	CurrentlyFailed int      `json:"currentlyFailed,omitempty"`
	TotalFailed     int      `json:"totalFailed,omitempty"`
	BannedIPs       []string `json:"bannedIPs,omitempty"`
}

// Fail2banSummary holds the host's fail2ban state.
type Fail2banSummary struct {
	UpdatedAt  string         `json:"updatedAt,omitempty"`
	Jails      []Fail2banJail `json:"jails"`
	RecentBans []Fail2banBan  `json:"recentBans,omitempty"`
}

// rawSmartctlJSON matches the subset of `smartctl -j -a` output we normalize.
type rawSmartctlJSON struct {
	Device struct {
		Name     string `json:"name"`
		Protocol string `json:"protocol"`
	} `json:"device"`
	ModelName    string `json:"model_name"`
	SerialNumber string `json:"serial_number"`
	RotationRate int    `json:"rotation_rate"`
	UserCapacity struct {
		Bytes uint64 `json:"bytes"`
	} `json:"user_capacity"`
	SmartStatus struct {
		Passed *bool `json:"passed"`
	} `json:"smart_status"`
	PowerMode   string `json:"power_mode"`
	Temperature struct {
		Current int `json:"current"`
	} `json:"temperature"`
	PowerOnTime struct {
		Hours uint64 `json:"hours"`
	} `json:"power_on_time"`
	AtaSmartAttributes struct {
		Table []struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
			Raw  struct {
				Value  uint64 `json:"value"`
				String string `json:"string"`
			} `json:"raw"`
		} `json:"table"`
	} `json:"ata_smart_attributes"`
	NvmeSmartHealthInformationLog struct {
		Temperature    int    `json:"temperature"`
		PercentageUsed int    `json:"percentage_used"`
		PowerOnHours   uint64 `json:"power_on_hours"`
		MediaErrors    uint64 `json:"media_errors"`
		CriticalWarn   int    `json:"critical_warning"`
	} `json:"nvme_smart_health_information_log"`
	Messages []struct {
		String string `json:"string"`
	} `json:"messages"`
}

// ParseSmartctlJSON converts a single raw `smartctl -j -a` JSON output into a SmartDrive.
func ParseSmartctlJSON(devPath string, raw []byte, updatedAt string) (SmartDrive, bool) {
	var r rawSmartctlJSON
	if err := json.Unmarshal(raw, &r); err != nil {
		return SmartDrive{}, false
	}
	if devPath == "" {
		devPath = r.Device.Name
	}
	name := strings.TrimPrefix(devPath, "/dev/")
	sd := SmartDrive{
		Device:        devPath,
		Name:          name,
		Model:         strings.TrimSpace(r.ModelName),
		Serial:        strings.TrimSpace(r.SerialNumber),
		Protocol:      r.Device.Protocol,
		Rotational:    r.RotationRate > 0,
		CapacityBytes: r.UserCapacity.Bytes,
		Healthy:       true,
		TempC:         r.Temperature.Current,
		PowerOnHours:  r.PowerOnTime.Hours,
		UpdatedAt:     updatedAt,
	}
	if r.SmartStatus.Passed != nil {
		sd.Healthy = *r.SmartStatus.Passed
	}
	for _, msg := range r.Messages {
		low := strings.ToLower(msg.String)
		if strings.Contains(low, "standby") || strings.Contains(low, "sleep") {
			sd.Standby = true
		}
	}
	if strings.Contains(strings.ToLower(r.PowerMode), "standby") {
		sd.Standby = true
	}

	for _, attr := range r.AtaSmartAttributes.Table {
		// Use the leading integer from Raw.String when possible because Seagate/WD
		// sometimes pack multi-word counters into Raw.Value for non-error attrs.
		val := attr.Raw.Value
		if tok := firstToken(attr.Raw.String); tok != "" {
			if parsed, err := parseUintStrict(tok); err == nil {
				val = parsed
			}
		}
		switch attr.ID {
		case 5: // Reallocated_Sector_Ct
			sd.ReallocatedSectors = val
		case 197: // Current_Pending_Sector
			sd.PendingSectors = val
		case 198: // Offline_Uncorrectable
			sd.UncorrectableErrors = val
		case 199: // UDMA_CRC_Error_Count
			sd.CRCErrors = val
		case 9: // Power_On_Hours fallback
			if sd.PowerOnHours == 0 {
				sd.PowerOnHours = val
			}
		case 190, 194: // Temperature_Celsius fallback
			if sd.TempC == 0 && val > 0 && val < 120 {
				sd.TempC = int(val)
			}
		}
	}

	if r.Device.Protocol == "NVMe" || r.NvmeSmartHealthInformationLog.PowerOnHours > 0 || r.NvmeSmartHealthInformationLog.PercentageUsed > 0 {
		if sd.Protocol == "" {
			sd.Protocol = "NVMe"
		}
		if sd.TempC == 0 {
			sd.TempC = r.NvmeSmartHealthInformationLog.Temperature
		}
		if sd.PowerOnHours == 0 {
			sd.PowerOnHours = r.NvmeSmartHealthInformationLog.PowerOnHours
		}
		sd.WearPercentUsed = r.NvmeSmartHealthInformationLog.PercentageUsed
		sd.UncorrectableErrors += r.NvmeSmartHealthInformationLog.MediaErrors
		if r.NvmeSmartHealthInformationLog.CriticalWarn != 0 {
			sd.Healthy = false
		}
	}

	if sd.ReallocatedSectors > 0 || sd.PendingSectors > 0 || sd.UncorrectableErrors > 0 {
		sd.Healthy = false
	}

	if sd.Model == "" && sd.Serial == "" && !sd.Standby && sd.PowerOnHours == 0 && sd.TempC == 0 {
		return SmartDrive{}, false
	}
	return sd, true
}

func parseUintStrict(s string) (uint64, error) {
	var v uint64
	for i := range len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, os.ErrInvalid
		}
		v = v*10 + uint64(s[i]-'0')
	}
	return v, nil
}

// smartSnapshotFile supports either pre-normalized `{"drives":[...]}` or a
// directory/map of raw `smartctl -j` blobs written by fleet-agent-smart.timer.
type smartSnapshotFile struct {
	UpdatedAt string                     `json:"updatedAt"`
	Drives    []SmartDrive               `json:"drives"`
	Raw       map[string]json.RawMessage `json:"raw"`
}

func readSmartSnapshot(stateDir string) []SmartDrive {
	if stateDir == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "smart.json"))
	if err != nil {
		return nil
	}
	var snap smartSnapshotFile
	if err := json.Unmarshal(b, &snap); err != nil {
		return nil
	}
	out := append([]SmartDrive(nil), snap.Drives...)
	for dev, raw := range snap.Raw {
		if sd, ok := ParseSmartctlJSON(dev, raw, snap.UpdatedAt); ok {
			out = append(out, sd)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Device < out[j].Device })
	return out
}

func readFail2banSnapshot(stateDir string) *Fail2banSummary {
	if stateDir == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "fail2ban.json"))
	if err != nil {
		return nil
	}
	var f2b Fail2banSummary
	if err := json.Unmarshal(b, &f2b); err != nil {
		return nil
	}
	sort.Slice(f2b.Jails, func(i, j int) bool { return f2b.Jails[i].Name < f2b.Jails[j].Name })
	return &f2b
}
