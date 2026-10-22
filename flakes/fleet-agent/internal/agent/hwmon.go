package agent

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

func readHwmonTemps(sysDir string) []TempReading {
	var out []TempReading
	seen := map[string]bool{}

	hwmonGlob, _ := filepath.Glob(filepath.Join(sysDir, "class/hwmon/hwmon*"))
	sort.Strings(hwmonGlob)
	for _, dir := range hwmonGlob {
		chip := readTrimmed(filepath.Join(dir, "name"))
		if chip == "" {
			chip = filepath.Base(dir)
		}
		inputs, _ := filepath.Glob(filepath.Join(dir, "temp*_input"))
		sort.Strings(inputs)
		for _, inp := range inputs {
			raw, err := strconv.ParseInt(readTrimmed(inp), 10, 64)
			if err != nil || raw <= 0 || raw > 150000 {
				continue
			}
			prefix := strings.TrimSuffix(inp, "_input")
			label := readTrimmed(prefix + "_label")
			sensor := chip
			if label != "" {
				sensor = chip + ":" + label
			}
			c := float64(raw) / 1000.0
			c = float64(int(c*10+0.5)) / 10.0
			if !seen[sensor] {
				seen[sensor] = true
				out = append(out, TempReading{Sensor: sensor, Celsius: c})
			}
		}
	}

	if len(out) == 0 {
		zones, _ := filepath.Glob(filepath.Join(sysDir, "class/thermal/thermal_zone*"))
		sort.Strings(zones)
		for _, z := range zones {
			raw, err := strconv.ParseInt(readTrimmed(filepath.Join(z, "temp")), 10, 64)
			if err != nil || raw <= 0 || raw > 150000 {
				continue
			}
			tType := readTrimmed(filepath.Join(z, "type"))
			if tType == "" {
				tType = filepath.Base(z)
			}
			c := float64(raw) / 1000.0
			c = float64(int(c*10+0.5)) / 10.0
			out = append(out, TempReading{Sensor: tType, Celsius: c})
		}
	}
	return out
}

func readTrimmed(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
