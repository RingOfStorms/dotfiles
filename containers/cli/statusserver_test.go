package main

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

func TestStatusEndpoint(t *testing.T) {
	root := t.TempDir()
	oldM, oldG, oldS, oldB := mutableUnits, gcrootDir, systemctlShow, backupStampDir
	t.Cleanup(func() { mutableUnits, gcrootDir, systemctlShow, backupStampDir = oldM, oldG, oldS, oldB })
	mutableUnits, gcrootDir, backupStampDir = filepath.Join(root, "m"), filepath.Join(root, "g"), filepath.Join(root, "b")
	for _, d := range []string{mutableUnits + "/machines.target.wants", mutableUnits + "/multi-user.target.wants", gcrootDir, backupStampDir} {
		os.MkdirAll(d, 0o755)
	}
	os.WriteFile(mutableUnits+"/container@atuin.service", nil, 0o644)
	os.WriteFile(mutableUnits+"/container@.service", nil, 0o644)         // template: skipped
	os.WriteFile(mutableUnits+"/container@bad name.service", nil, 0o644) // bad name: skipped
	os.Symlink("../container@atuin.service", mutableUnits+"/machines.target.wants/container@atuin.service")
	os.Symlink("/nix/store/x", gcrootDir+"/searx")
	os.WriteFile(backupStampDir+"/atuin", []byte("time=2026-10-22T08:00:00Z snapshot=abc123 host=h001\n"), 0o644)
	os.WriteFile(backupStampDir+"/searx", []byte("garbage\n"), 0o644) // malformed: reported as never
	var asked []string
	systemctlShow = func(_ context.Context, units []string) (string, error) {
		asked = units
		return "Id=container@atuin.service\nActiveState=active\n\nId=fleet-searx.service\nActiveState=inactive\n", nil
	}
	srv := httptest.NewServer(statusHandler("h001"))
	defer srv.Close()

	res, err := http.Get(srv.URL + "/status.json?unit=evil")
	if err != nil {
		t.Fatal(err)
	}
	var d statusDoc
	json.NewDecoder(res.Body).Decode(&d)
	res.Body.Close()
	if res.Header.Get("Content-Type") != "application/json" || d.Host != "h001" || len(d.Services) != 2 ||
		d.Services["atuin"] != (statusService{Unit: "container@atuin.service", Active: "active", Enabled: true, LastBackup: "2026-10-22T08:00:00Z"}) ||
		d.Services["searx"] != (statusService{Unit: "fleet-searx.service", Active: "inactive", Enabled: false}) {
		t.Errorf("doc: %+v", d)
	}
	if len(asked) != 2 || asked[0] != "container@atuin.service" || asked[1] != "fleet-searx.service" {
		t.Errorf("systemctl asked for %v", asked)
	}

	res, _ = http.Post(srv.URL+"/status.json", "text/plain", nil)
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST: %d", res.StatusCode)
	}
	res, _ = http.Get(srv.URL + "/other")
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("other path: %d", res.StatusCode)
	}
}
