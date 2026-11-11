package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// GitHub Copilot authentication. The Copilot API accepts a GitHub OAuth token
// (gho_…) directly as its bearer; the short-lived Copilot token that the
// /copilot_internal/v2/token exchange hands out is not needed, and that
// endpoint answers 403 to a plain OAuth token anyway.
//
// The token is obtained through the Copilot device flow and stored locally,
// allowing the gateway to authenticate without a separate credential service.
const copilotOAuthClientID = "Iv1.b507a08c87ecfe98" // VS Code Copilot plugin

type copilotAuth struct {
	path   string // token file inside the state dir
	client *http.Client

	mu      sync.Mutex
	value   string
	expires time.Time

	// pending is the device code currently awaiting approval, so a login that
	// is already in flight is not restarted on every catalog refresh.
	deviceCode string
	userCode   string
	verifyURL  string
	nextPoll   time.Time
	interval   time.Duration
	failed     string
}

func newCopilotAuth(path string) *copilotAuth {
	return &copilotAuth{path: path, client: &http.Client{Timeout: 30 * time.Second}}
}

// token returns the bearer for api.githubcopilot.com. It never blocks on the
// device flow: an unauthenticated gateway reports Copilot as degraded and the
// background login (StartLogin / poll) fills the token in.
func (a *copilotAuth) token() (string, error) {
	if v := strings.TrimSpace(os.Getenv("COPILOT_GITHUB_TOKEN")); v != "" {
		return v, nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if time.Now().Before(a.expires) && a.value != "" {
		return a.value, nil
	}
	token, err := readCopilotToken(a.path)
	if err != nil {
		msg := err.Error()
		if a.userCode != "" {
			msg = fmt.Sprintf("%s; authorize at %s with code %s", msg, a.verifyURL, a.userCode)
		}
		return "", fmt.Errorf("%s", msg)
	}
	a.value = token
	a.expires = time.Now().Add(time.Minute)
	return token, nil
}

// readCopilotToken accepts a bare token file or the standard GitHub CLI
// Copilot configuration directory/file formats.
func readCopilotToken(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("Copilot credential is unavailable")
	}
	if info.IsDir() {
		for _, name := range []string{"hosts.json", "apps.json"} {
			if token, err := readCopilotToken(filepath.Join(path, name)); err == nil {
				return token, nil
			}
		}
		return "", fmt.Errorf("Copilot credential is unavailable")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read Copilot credential")
	}
	text := strings.TrimSpace(string(data))
	if !strings.HasPrefix(text, "{") {
		if text == "" {
			return "", fmt.Errorf("Copilot credential file is empty")
		}
		return text, nil
	}
	var hosts map[string]struct {
		OAuthToken string `json:"oauth_token"`
	}
	if err := json.Unmarshal([]byte(text), &hosts); err != nil {
		return "", fmt.Errorf("parse Copilot credential: %w", err)
	}
	for key, entry := range hosts {
		if strings.HasPrefix(key, "github.com") && entry.OAuthToken != "" {
			return entry.OAuthToken, nil
		}
	}
	return "", fmt.Errorf("no Copilot credential in configuration file")
}

// ensureToken keeps a Copilot credential on disk. It runs for the life of the
// process: with a token present it re-checks periodically (a revoked token is
// replaced by a fresh device login), and with none it starts one. An operator
// that sets COPILOT_GITHUB_TOKEN supplies its own credential, so no login.
func (a *copilotAuth) ensureToken(ctx context.Context) {
	if strings.TrimSpace(os.Getenv("COPILOT_GITHUB_TOKEN")) != "" {
		return
	}
	wait := time.Duration(0)
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if _, err := readCopilotToken(a.path); err == nil {
			a.mu.Lock()
			a.value, a.expires = "", time.Time{} // re-read on next use
			a.deviceCode, a.userCode, a.verifyURL = "", "", ""
			a.mu.Unlock()
			wait = 30 * time.Minute
			continue
		}
		a.mu.Lock()
		pending := a.deviceCode != ""
		a.mu.Unlock()
		var err error
		if pending {
			err = a.pollLogin(ctx)
		} else {
			err = a.startLogin(ctx)
		}
		if err != nil {
			log.Printf("copilot: device login: %v", err)
			a.mu.Lock()
			a.failed = err.Error()
			a.mu.Unlock()
			wait = 30 * time.Second
			continue
		}
		wait = 5 * time.Second
	}
}

// startLogin asks GitHub for a device code and logs the instructions. The code
// is also surfaced in /health so the operator does not have to find the unit
// log.
func (a *copilotAuth) startLogin(ctx context.Context) error {
	form := url.Values{"client_id": {copilotOAuthClientID}, "scope": {"read:user"}}
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost,
		"https://github.com/login/device/code",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")
	req.Header.Set("accept", "application/json")
	var out struct {
		DeviceCode      string `json:"device_code"`
		UserCode        string `json:"user_code"`
		VerificationURI string `json:"verification_uri"`
		Interval        int    `json:"interval"`
		Error           string `json:"error"`
	}
	if err := a.doJSON(req, &out); err != nil {
		return err
	}
	if out.DeviceCode == "" {
		return fmt.Errorf("no device code: %s", out.Error)
	}
	interval := time.Duration(out.Interval) * time.Second
	if interval <= 0 {
		interval = 5 * time.Second
	}
	a.mu.Lock()
	a.deviceCode = out.DeviceCode
	a.userCode = out.UserCode
	a.verifyURL = out.VerificationURI
	a.interval = interval
	a.nextPoll = time.Now().Add(interval)
	a.failed = ""
	a.mu.Unlock()
	log.Printf("copilot: authorize at %s with code %s (waiting for approval)", out.VerificationURI, out.UserCode)
	return nil
}

// pollLogin checks once whether the pending device code was approved and, on
// success, writes the token to the state dir for the next boot.
func (a *copilotAuth) pollLogin(ctx context.Context) error {
	a.mu.Lock()
	code, next, interval := a.deviceCode, a.nextPoll, a.interval
	a.mu.Unlock()
	if code == "" || time.Now().Before(next) {
		return nil
	}
	form := url.Values{
		"client_id":   {copilotOAuthClientID},
		"device_code": {code},
		"grant_type":  {"urn:ietf:params:oauth:grant-type:device_code"},
	}
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost,
		"https://github.com/login/oauth/access_token",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")
	req.Header.Set("accept", "application/json")
	var out struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := a.doJSON(req, &out); err != nil {
		a.mu.Lock()
		a.nextPoll = time.Now().Add(interval)
		a.mu.Unlock()
		return err
	}
	switch out.Error {
	case "":
	case "authorization_pending":
		a.mu.Lock()
		a.nextPoll = time.Now().Add(interval)
		a.mu.Unlock()
		return nil
	case "slow_down":
		a.mu.Lock()
		a.interval += 5 * time.Second
		a.nextPoll = time.Now().Add(a.interval)
		a.mu.Unlock()
		return nil
	default:
		// expired_token / access_denied: start over with a fresh code.
		a.mu.Lock()
		a.deviceCode, a.userCode, a.verifyURL, a.failed = "", "", "", out.Error
		a.mu.Unlock()
		log.Printf("copilot: device login ended: %s", out.Error)
		return nil
	}
	if out.AccessToken == "" {
		a.mu.Lock()
		a.nextPoll = time.Now().Add(interval)
		a.mu.Unlock()
		return nil
	}
	if err := writeTokenFile(a.path, out.AccessToken); err != nil {
		return err
	}
	a.mu.Lock()
	a.value, a.expires = out.AccessToken, time.Now().Add(time.Minute)
	a.deviceCode, a.userCode, a.verifyURL, a.failed = "", "", "", ""
	a.mu.Unlock()
	log.Printf("copilot: device login complete, token stored in %s", a.path)
	return nil
}

// loginHint reports an in-flight device login for /health.
func (a *copilotAuth) loginHint() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.userCode == "" {
		return a.failed
	}
	return fmt.Sprintf("authorize at %s with code %s", a.verifyURL, a.userCode)
}

func (a *copilotAuth) doJSON(req *http.Request, out any) error {
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", req.URL.Path, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// writeTokenFile stores the token atomically with mode 0600 so a partially
// written file is never read as a credential.
func writeTokenFile(path, token string) error {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(token+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
