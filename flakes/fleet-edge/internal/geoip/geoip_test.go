package geoip

import (
	"bytes"
	"compress/gzip"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, name string, body []byte, gz bool) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if gz {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		if _, err := zw.Write(body); err != nil {
			t.Fatal(err)
		}
		if err := zw.Close(); err != nil {
			t.Fatal(err)
		}
		body = buf.Bytes()
	}
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

const boundaryCSV = "8.8.7.0,8.8.7.255,DE\n8.8.8.0,8.8.8.127,US\n8.8.8.128,8.8.8.255,CA\n8.8.9.0,8.8.9.255,FR\n"

func TestLookupBoundaries(t *testing.T) {
	db, err := Load(write(t, "dbip.csv", []byte(boundaryCSV), false))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ ip, want string }{
		{"8.8.7.255", "DE"},
		{"8.8.8.0", "US"},
		{"8.8.8.127", "US"}, // last address of the US row
		{"8.8.8.128", "CA"}, // first address of the next row
		{"8.8.8.255", "CA"},
		{"8.8.9.0", "FR"},
	} {
		got, ok := db.LookupString(tc.ip)
		if !ok || got != tc.want {
			t.Errorf("%s = %q,%v want %q", tc.ip, got, ok, tc.want)
		}
	}
	// One address outside every row, on both sides.
	for _, ip := range []string{"8.8.6.255", "8.8.10.0", "1.1.1.1"} {
		if cc, ok := db.LookupString(ip); ok {
			t.Errorf("%s resolved to %q, want unknown", ip, cc)
		}
	}
	// Private and reserved space is never answered, even if a file claims it.
	if cc, ok := db.Lookup(netip.MustParseAddr("10.0.0.1")); ok {
		t.Errorf("private address resolved to %q", cc)
	}
}

func TestGzipFile(t *testing.T) {
	plain, err := Load(write(t, "dbip.csv", []byte(boundaryCSV), false))
	if err != nil {
		t.Fatal(err)
	}
	zipped, err := Load(write(t, "dbip.csv.gz", []byte(boundaryCSV), true))
	if err != nil {
		t.Fatal(err)
	}
	v4p, v6p := plain.Ranges()
	v4z, v6z := zipped.Ranges()
	if v4p != v4z || v6p != v6z {
		t.Fatalf("ranges csv=%d/%d gz=%d/%d", v4p, v6p, v4z, v6z)
	}
	if cc, ok := zipped.LookupString("8.8.8.128"); !ok || cc != "CA" {
		t.Errorf("gz lookup = %q,%v want CA", cc, ok)
	}
}

func TestRejectsMalformedFiles(t *testing.T) {
	cases := map[string]string{
		"inverted":  "8.8.8.128,8.8.8.0,US\n",
		"bad code":  "8.8.8.0,8.8.8.255,usa\n",
		"bad addr":  "8.8.8.0,nope,US\n",
		"ZZ":        "8.8.8.0,8.8.8.255,ZZ\n",
		"short row": "8.8.8.0,8.8.8.255\n",
		"overlap":   "8.8.8.0,8.8.8.200,US\n8.8.8.100,8.8.8.255,CA\n",
		"mixed":     "8.8.8.0,2606:4700::ffff,US\n",
	}
	for name, body := range cases {
		if _, err := Load(write(t, "dbip.csv", []byte(body), false)); err == nil {
			t.Errorf("%s: file accepted", name)
		}
	}
	// A header is the one tolerated non-record.
	if _, err := Load(write(t, "dbip.csv", []byte("ip_start,ip_end,country\n"+boundaryCSV), false)); err != nil {
		t.Errorf("header rejected: %v", err)
	}
	if _, err := Load(filepath.Join(t.TempDir(), "missing.csv")); err == nil {
		t.Error("missing file accepted")
	}
}
