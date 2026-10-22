package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBuildStatusJSON(t *testing.T) {
	units := map[string]string{"zitadel": "container@zitadel.service", "searx": "fleet-searx.service", "sec": "container@sec.service"}
	states := map[string]string{"container@zitadel.service": "active", "fleet-searx.service": "failed", "container@sec.service": "deactivating"}
	linked := func(p string) bool { return p == mutableUnits+"/machines.target.wants/container@zitadel.service" }
	d := buildStatus("h001", time.Date(2026, 10, 17, 12, 0, 0, 0, time.FixedZone("x", 3600)), units, states, linked,
		map[string]time.Time{"zitadel": time.Date(2026, 10, 17, 3, 5, 0, 0, time.FixedZone("y", -5*3600))})
	b, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"host":"h001","time":"2026-10-17T11:00:00Z","services":{` +
		`"searx":{"unit":"fleet-searx.service","active":"failed","enabled":false},` +
		`"sec":{"unit":"container@sec.service","active":"inactive","enabled":false},` +
		`"zitadel":{"unit":"container@zitadel.service","active":"active","enabled":true,"lastBackup":"2026-10-17T08:05:00Z"}}}`
	if string(b) != want {
		t.Fatalf("got  %s\nwant %s", b, want)
	}
	empty, _ := json.Marshal(buildStatus("h", time.Unix(0, 0), nil, nil, linked, nil))
	if string(empty) != `{"host":"h","time":"1970-01-01T00:00:00Z","services":{}}` {
		t.Errorf("empty: %s", empty)
	}
}

func TestParseShow(t *testing.T) {
	got := parseShow("Id=container@a.service\nActiveState=active\n\nActiveState=failed\nId=fleet-b.service\n\nId=container@c.service\nActiveState=inactive\n")
	want := map[string]string{"container@a.service": "active", "fleet-b.service": "failed", "container@c.service": "inactive"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s=%q want %q", k, got[k], v)
		}
	}
}

func TestStatusEndpointAndMetrics(t *testing.T) {
	root := t.TempDir()
	oldM, oldG, oldS, oldB := mutableUnits, gcrootDir, systemctlShow, backupStampDir
	oldP, oldSys, oldStatfs := procRoot, sysRoot, statfsFunc
	t.Cleanup(func() {
		mutableUnits, gcrootDir, systemctlShow, backupStampDir = oldM, oldG, oldS, oldB
		procRoot, sysRoot, statfsFunc = oldP, oldSys, oldStatfs
	})

	mutableUnits = filepath.Join(root, "m")
	gcrootDir = filepath.Join(root, "g")
	backupStampDir = filepath.Join(root, "b")
	procRoot = filepath.Join(root, "proc")
	sysRoot = filepath.Join(root, "sys")
	stateDir := filepath.Join(root, "state")

	for _, d := range []string{
		mutableUnits + "/machines.target.wants",
		mutableUnits + "/multi-user.target.wants",
		gcrootDir,
		backupStampDir,
		procRoot + "/net",
		procRoot + "/sys/kernel",
		sysRoot + "/class/hwmon/hwmon0",
		sysRoot + "/fs/bcachefs/53a26b95-941b-4f41-b049-c166905ed8c2/options",
		sysRoot + "/fs/bcachefs/53a26b95-941b-4f41-b049-c166905ed8c2/dev-0",
		sysRoot + "/fs/bcachefs/53a26b95-941b-4f41-b049-c166905ed8c2/dev-1",
		stateDir,
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	// Units & backup stamps
	os.WriteFile(mutableUnits+"/container@atuin.service", nil, 0o644)
	os.WriteFile(mutableUnits+"/container@.service", nil, 0o644)
	os.Symlink("../container@atuin.service", mutableUnits+"/machines.target.wants/container@atuin.service")
	os.Symlink("/nix/store/x", gcrootDir+"/searx")
	os.WriteFile(backupStampDir+"/atuin", []byte("time=2026-10-22T08:00:00Z snapshot=abc123 host=h001\n"), 0o644)

	// Synthetic /proc
	os.WriteFile(procRoot+"/sys/kernel/osrelease", []byte("6.18.56\n"), 0o644)
	os.WriteFile(procRoot+"/uptime", []byte("86400.50 172000.00\n"), 0o644)
	os.WriteFile(procRoot+"/loadavg", []byte("0.42 0.35 0.28 1/420 12345\n"), 0o644)
	os.WriteFile(procRoot+"/meminfo", []byte("MemTotal:       33554432 kB\nMemFree:         8388608 kB\nMemAvailable:   25165824 kB\nSwapTotal:       8388608 kB\nSwapFree:        8388608 kB\n"), 0o644)
	os.WriteFile(procRoot+"/stat", []byte("cpu  1000 0 500 8500 0 0 0 0 0 0\ncpu0 500 0 250 4250 0 0 0 0 0 0\ncpu1 500 0 250 4250 0 0 0 0 0 0\n"), 0o644)
	os.WriteFile(procRoot+"/diskstats", []byte("   8       0 sda 100 0 2000 0 50 0 1000 0 0 0 0\n   8       1 sda1 10 0 200 0 5 0 100 0 0 0 0\n"), 0o644)
	os.WriteFile(procRoot+"/net/dev", []byte("Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0\nenp3s0: 100000 100 0 0 0 0 0 0 50000 50 0 0 0 0 0 0\n"), 0o644)

	// Synthetic /proc/mounts with bcachefs subvolumes sharing a pool + /data pool
	os.WriteFile(procRoot+"/mounts", []byte(
		"/dev/nvme0n1p2 / bcachefs rw,relatime 0 0\n"+
			"/dev/nvme0n1p2 /nix bcachefs rw,relatime 0 0\n"+
			"/dev/nvme0n1p2 /persist bcachefs rw,relatime 0 0\n"+
			"/dev/sda:/dev/sdb /data bcachefs rw,relatime 0 0\n",
	), 0o644)

	// Synthetic hwmon
	os.WriteFile(sysRoot+"/class/hwmon/hwmon0/name", []byte("k10temp\n"), 0o644)
	os.WriteFile(sysRoot+"/class/hwmon/hwmon0/temp1_label", []byte("Tctl\n"), 0o644)
	os.WriteFile(sysRoot+"/class/hwmon/hwmon0/temp1_input", []byte("44500\n"), 0o644)

	// Synthetic bcachefs sysfs + usage snapshot for /data (replicas=2)
	bchDir := sysRoot + "/fs/bcachefs/53a26b95-941b-4f41-b049-c166905ed8c2"
	os.WriteFile(bchDir+"/version_major", []byte("1\n"), 0o644)
	os.WriteFile(bchDir+"/version_minor", []byte("39\n"), 0o644)
	os.WriteFile(bchDir+"/options/data_replicas", []byte("2\n"), 0o644)
	os.WriteFile(bchDir+"/options/metadata_replicas", []byte("2\n"), 0o644)
	os.Symlink("/sys/class/block/sda", bchDir+"/dev-0/block")
	os.WriteFile(bchDir+"/dev-0/label", []byte("hdd.0\n"), 0o644)
	os.WriteFile(bchDir+"/dev-0/state", []byte("rw\n"), 0o644)
	os.Symlink("/sys/class/block/sdb", bchDir+"/dev-1/block")
	os.WriteFile(bchDir+"/dev-1/label", []byte("hdd.1\n"), 0o644)
	os.WriteFile(bchDir+"/dev-1/state", []byte("rw\n"), 0o644)

	bchSnap := `{"pools":{"53a26b95-941b-4f41-b049-c166905ed8c2":{"uuid":"53a26b95-941b-4f41-b049-c166905ed8c2","mount":"/data","usageText":"Filesystem: 53a26b95-941b-4f41-b049-c166905ed8c2\nCapacity:               24000000000000\nUsed:                   10000000000000\nOnline reserved:        100000000000\n\nData type       Required/total  Devices             Bytes\n  btree:        2/2             [sda sdb]    20000000000\n  user:         2/2             [sda sdb]   9800000000000\n\nCompression:\n  type              compressed    uncompressed     average extent size\n  zstd           4000000000000   6000000000000                    128k\n\nhdd.0 (device 0):               sda              rw\n                                data         buckets    fragmented\n  free:                7000000000000        14000000\n  capacity:           12000000000000        24000000\n\nhdd.1 (device 1):               sdb              rw\n                                data         buckets    fragmented\n  free:                7000000000000        14000000\n  capacity:           12000000000000        24000000\n"}}}`
	os.WriteFile(stateDir+"/bcachefs.json", []byte(bchSnap), 0o644)

	// Synthetic SMART & Fail2ban snapshots
	smartSnap := `{"updatedAt":"2026-10-22T12:00:00Z","raw":{"/dev/sda":{"device":{"name":"/dev/sda","protocol":"ATA"},"model_name":"ST12000NT001","serial_number":"ZRT2GA17","rotation_rate":7200,"smart_status":{"passed":true},"temperature":{"current":34},"power_on_time":{"hours":12340},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","raw":{"value":0,"string":"0"}},{"id":197,"name":"Current_Pending_Sector","raw":{"value":0,"string":"0"}}]}}}}`
	os.WriteFile(stateDir+"/smart.json", []byte(smartSnap), 0o644)
	f2bSnap := `{"updatedAt":"2026-10-22T12:00:00Z","jails":[{"name":"sshd","currentlyBanned":1,"totalBanned":12,"bannedIPs":["203.0.113.9"]}],"recentBans":[{"jail":"sshd","ip":"203.0.113.9","bannedAt":"2026-10-22T11:50:00Z","banSeconds":3600,"failures":5,"active":true}]}`
	os.WriteFile(stateDir+"/fail2ban.json", []byte(f2bSnap), 0o644)

	statfsFunc = func(path string) (uint64, uint64, uint64, bool) {
		switch path {
		case "/", "/nix", "/persist":
			return 500_000_000_000, 120_000_000_000, 380_000_000_000, true
		case "/data":
			return 24_000_000_000_000, 10_000_000_000_000, 14_000_000_000_000, true
		}
		return 0, 0, 0, false
	}

	systemctlShow = func(_ context.Context, _ []string) (string, error) {
		return "Id=container@atuin.service\nActiveState=active\n\nId=fleet-searx.service\nActiveState=inactive\n\nId=nginx.service\nActiveState=active\n", nil
	}

	sampler := NewSampler()
	// Advance counters 1 second later
	os.WriteFile(procRoot+"/stat", []byte("cpu  1200 0 600 9200 0 0 0 0 0 0\ncpu0 600 0 300 4600 0 0 0 0 0 0\ncpu1 600 0 300 4600 0 0 0 0 0 0\n"), 0o644)
	os.WriteFile(procRoot+"/diskstats", []byte("   8       0 sda 110 0 4000 0 60 0 2000 0 0 0 0\n"), 0o644)
	os.WriteFile(procRoot+"/net/dev", []byte("Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\nenp3s0: 200000 200 0 0 0 0 0 0 90000 90 0 0 0 0 0 0\n"), 0o644)
	sampler.SampleAt(time.Now().Add(1 * time.Second))

	cfg := Config{
		Host:          "h004",
		StateDir:      stateDir,
		Mounts:        []string{"/data:Data"},
		ExtraUnits:    []string{"nginx.service"},
		EnableMetrics: true,
	}
	srv := httptest.NewServer(Handler(cfg, sampler))
	defer srv.Close()

	res, err := http.Get(srv.URL + "/status.json")
	if err != nil {
		t.Fatal(err)
	}
	var d StatusDoc
	if err := json.NewDecoder(res.Body).Decode(&d); err != nil {
		t.Fatal(err)
	}
	res.Body.Close()

	if d.Host != "h004" || len(d.Services) != 2 || d.HostUnits["nginx"].Active != "active" {
		t.Fatalf("unexpected services/hostUnits: %+v", d)
	}
	if d.System == nil || d.System.CPUPercent != 30.0 || d.System.CPUCores != 2 || d.System.Kernel != "6.18.56" {
		t.Fatalf("unexpected system metrics: %+v", d.System)
	}
	// 3 subvolumes on nvme0n1p2 should deduplicate into "/", plus "/data" = 2 filesystems total.
	if len(d.Filesystems) != 2 {
		t.Fatalf("expected 2 deduplicated filesystems, got %d: %+v", len(d.Filesystems), d.Filesystems)
	}
	if len(d.Filesystems[0].Subvolumes) != 3 {
		t.Errorf("expected 3 subvolumes on /, got %v", d.Filesystems[0].Subvolumes)
	}
	dataFS := d.Filesystems[1]
	if dataFS.Mount != "/data" || dataFS.Label != "Data" || dataFS.Bcachefs == nil {
		t.Fatalf("unexpected /data fs: %+v", dataFS)
	}
	if dataFS.Bcachefs.DataReplicas != 2.0 || dataFS.TotalBytes != 12_000_000_000_000 || dataFS.UsedBytes != 5_000_000_000_000 {
		t.Errorf("bcachefs usable calculation wrong: total=%d used=%d pool=%+v", dataFS.TotalBytes, dataFS.UsedBytes, dataFS.Bcachefs)
	}
	if dataFS.Bcachefs.CompressionRatio != 1.5 || len(dataFS.Bcachefs.Devices) != 2 {
		t.Errorf("bcachefs compression/devices wrong: %+v", dataFS.Bcachefs)
	}
	if len(d.Smart) != 1 || d.Smart[0].Serial != "ZRT2GA17" || !d.Smart[0].Healthy || d.Smart[0].TempC != 34 {
		t.Errorf("unexpected smart: %+v", d.Smart)
	}
	if d.Fail2ban == nil || len(d.Fail2ban.Jails) != 1 || d.Fail2ban.Jails[0].CurrentlyBanned != 1 {
		t.Errorf("unexpected fail2ban: %+v", d.Fail2ban)
	}
}

func TestLogsEndpointGuestVsUnit(t *testing.T) {
	root := t.TempDir()
	oldM, oldG, oldN, oldJ := mutableUnits, gcrootDir, nspawnRootDir, runJournalctl
	t.Cleanup(func() {
		mutableUnits, gcrootDir, nspawnRootDir, runJournalctl = oldM, oldG, oldN, oldJ
	})
	mutableUnits = filepath.Join(root, "m")
	gcrootDir = filepath.Join(root, "g")
	nspawnRootDir = filepath.Join(root, "nspawn")
	os.MkdirAll(mutableUnits, 0o755)
	os.MkdirAll(gcrootDir, 0o755)
	guestJDir := filepath.Join(nspawnRootDir, "jellyfin/var/log/journal/0123456789abcdef0123456789abcdef")
	os.MkdirAll(guestJDir, 0o755)
	os.WriteFile(mutableUnits+"/container@jellyfin.service", nil, 0o644)
	os.Symlink("/nix/store/x", gcrootDir+"/searx")

	var gotArgs []string
	runJournalctl = func(_ context.Context, args []string) ([]byte, error) {
		gotArgs = args
		return []byte(`{"__REALTIME_TIMESTAMP":"1761134400000000","PRIORITY":"6","_SYSTEMD_UNIT":"jellyfin.service","MESSAGE":"Server ready"}` + "\n"), nil
	}

	srv := httptest.NewServer(Handler(Config{Host: "h001", ExtraUnits: []string{"nginx.service"}}, nil))
	defer srv.Close()

	// 1. Default for nspawn container -> guest journal directory (-D)
	res, err := http.Get(srv.URL + "/logs.json?target=jellyfin&lines=50")
	if err != nil {
		t.Fatal(err)
	}
	var lr LogsResponse
	json.NewDecoder(res.Body).Decode(&lr)
	res.Body.Close()
	if lr.Kind != "guest" || len(lr.Entries) != 1 || lr.Entries[0].Message != "Server ready" {
		t.Fatalf("guest logs: %+v", lr)
	}
	if len(gotArgs) < 2 || gotArgs[0] != "-D" || gotArgs[1] != guestJDir {
		t.Fatalf("expected journalctl -D %s, got %v", guestJDir, gotArgs)
	}

	// 2. Explicit kind=unit for nspawn container -> outer supervisor unit (-u container@jellyfin.service)
	res, _ = http.Get(srv.URL + "/logs.json?target=jellyfin&kind=unit")
	res.Body.Close()
	if len(gotArgs) < 2 || gotArgs[0] != "-u" || gotArgs[1] != "container@jellyfin.service" {
		t.Fatalf("expected journalctl -u container@jellyfin.service, got %v", gotArgs)
	}

	// 3. Disallowed unit is rejected
	res, _ = http.Get(srv.URL + "/logs.json?target=secret-unit.service")
	res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for disallowed unit, got %d", res.StatusCode)
	}
}
