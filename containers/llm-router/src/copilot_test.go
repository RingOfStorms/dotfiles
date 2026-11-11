package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The gateway must accept the credential shapes it can find in the wild: a
// bare token file (what the device login writes) and the github-copilot
// hosts.json/apps.json files that carry a per-host oauth_token.
func TestReadCopilotToken(t *testing.T) {
	dir := t.TempDir()

	bare := filepath.Join(dir, "bare")
	if err := os.WriteFile(bare, []byte("gho_abc123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := readCopilotToken(bare); err != nil || got != "gho_abc123" {
		t.Fatalf("bare file: got %q, %v", got, err)
	}

	hosts := filepath.Join(dir, "hosts.json")
	body := `{"github.com":{"oauth_token":"gho_fromjson","user":"josh"},
	          "github.com:Iv1.deadbeef":{"oauth_token":"gho_other"}}`
	if err := os.WriteFile(hosts, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readCopilotToken(hosts)
	if err != nil {
		t.Fatalf("hosts.json: %v", err)
	}
	if got != "gho_fromjson" && got != "gho_other" {
		t.Fatalf("hosts.json: unexpected token %q", got)
	}

	// A config directory is searched for hosts.json before apps.json.
	cfgDir := filepath.Join(dir, "copilot")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "apps.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readCopilotToken(cfgDir); err != nil {
		t.Fatalf("directory: %v", err)
	}

	emptyDir := filepath.Join(dir, "empty-config")
	if err := os.MkdirAll(emptyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "empty"), []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "other.json"), []byte(`{"gitlab.com":{"oauth_token":"x"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{
		"missing":   filepath.Join(dir, "nope"),
		"empty":     filepath.Join(dir, "empty"),
		"no github": filepath.Join(dir, "other.json"),
		"empty dir": emptyDir,
	} {
		if got, err := readCopilotToken(path); err == nil {
			t.Errorf("%s: expected an error, got %q", name, got)
		}
	}
}

// token() must surface the pending device-login instructions when there is no
// credential on disk, so /health tells the operator what to do.
func TestCopilotTokenReportsPendingLogin(t *testing.T) {
	a := newCopilotAuth(filepath.Join(t.TempDir(), "token"))
	a.userCode = "ABCD-1234"
	a.verifyURL = "https://github.com/login/device"
	_, err := a.token()
	if err == nil {
		t.Fatal("expected an error without a token file")
	}
	want := "authorize at https://github.com/login/device with code ABCD-1234"
	if got := a.loginHint(); got != want {
		t.Fatalf("loginHint: got %q, want %q", got, want)
	}
}

// writeTokenFile must leave a 0600 file (and no temp file behind) that the
// next boot can read back.
func TestWriteTokenFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "copilot-token")
	if err := writeTokenFile(path, "gho_written"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("mode: got %04o, want 0600", perm)
	}
	if entries, err := os.ReadDir(filepath.Dir(path)); err != nil || len(entries) != 1 {
		t.Fatalf("leftover temp file: %v %d entries", err, len(entries))
	}
	if got, err := readCopilotToken(path); err != nil || got != "gho_written" {
		t.Fatalf("round trip: got %q, %v", got, err)
	}
}

func TestLoadUpstreamsResolvesEnvironmentURLs(t *testing.T) {
	t.Setenv("TEST_UPSTREAM_URL", "https://example.test/api")
	path := filepath.Join(t.TempDir(), "upstreams.json")
	if err := os.WriteFile(path, []byte(`[{"name":"private","type":"litellm","base_url_env":"TEST_UPSTREAM_URL","api_key_env":"TEST_UPSTREAM_KEY"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := loadUpstreams(path)
	if err != nil {
		t.Fatalf("load upstream config: %v", err)
	}
	if len(got) != 1 || got[0].Name != "private" || got[0].Type != "litellm" || got[0].BaseURL != "https://example.test/api" || got[0].BaseURLEnv != "" || got[0].APIKeyEnv != "TEST_UPSTREAM_KEY" {
		t.Fatalf("environment URL not resolved and normalized: %+v", got)
	}
}

func TestLoadUpstreamsRejectsInvalidConfiguration(t *testing.T) {
	t.Setenv("VALID_UPSTREAM_URL", "https://valid.example/v1")
	t.Setenv("EMPTY_UPSTREAM_URL", "")
	secretURL := "http://private.example:badport/private/path"
	t.Setenv("INVALID_UPSTREAM_URL", secretURL)
	tests := []struct {
		name string
		json string
	}{
		{name: "malformed JSON", json: `[{"name":`},
		{name: "unknown type", json: `[{"name":"x","type":"not-a-provider","base_url":"https://example.test"}]`},
		{name: "duplicate names", json: `[{"name":"x","type":"litellm","base_url":"https://one.test"},{"name":"x","type":"litellm","base_url":"https://two.test"}]`},
		{name: "invalid URL", json: `[{"name":"x","type":"litellm","base_url":"not a URL"}]`},
		{name: "missing URL environment", json: `[{"name":"x","type":"litellm","base_url_env":"MISSING_UPSTREAM_URL"}]`},
		{name: "missing URL", json: `[{"name":"x","type":"litellm"}]`},
		{name: "conflicting URL sources", json: `[{"name":"x","type":"litellm","base_url":"https://one.test","base_url_env":"VALID_UPSTREAM_URL"}]`},
		{name: "empty URL environment", json: `[{"name":"x","type":"litellm","base_url_env":"EMPTY_UPSTREAM_URL"}]`},
		{name: "invalid environment URL", json: `[{"name":"x","type":"litellm","base_url_env":"INVALID_UPSTREAM_URL"}]`},
		{name: "OpenRouter requires API key env", json: `[{"name":"router","type":"openrouter","base_url":"https://example.test/api/v1"}]`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "upstreams.json")
			if err := os.WriteFile(path, []byte(tt.json), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := loadUpstreams(path); err == nil {
				t.Fatal("loadUpstreams succeeded, want configuration error")
			} else if strings.Contains(err.Error(), secretURL) {
				t.Errorf("configuration error exposed upstream URL: %v", err)
			}
		})
	}
}

func TestValidateUpstreamsAcceptsSeveralIdentitiesPerType(t *testing.T) {
	got, err := validateUpstreams([]upstreamConfig{
		{Name: "one", Type: "litellm", BaseURL: "http://one.example/v1"},
		{Name: "two", Type: "litellm", BaseURL: "http://two.example/v1"},
		{Name: "region", Type: "openrouter", BaseURL: "https://openrouter.example/api/v1", APIKeyEnv: "REGION_KEY"},
		{Name: "github", Type: "copilot", BaseURL: "https://copilot.example"},
	})
	if err != nil {
		t.Fatalf("multiple upstream identities should be valid: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("validated upstream count = %d, want four", len(got))
	}
}
