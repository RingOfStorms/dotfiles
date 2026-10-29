package containers

// Zitadel machine token for fleet-edge-overrides: the exact login sec-agent
// does (secrets_manager src/agent.lis, fetch_zitadel_token). The host's
// machine key (/machine-key.json, root-only) signs an RS256 JWT-bearer
// assertion, exchanged at the issuer for a short-lived token whose
// audience includes the sec project. No new credential: h005 allows the
// token by its sub (the machine user) and the host's overlay IP.

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Same values as hosts/_shared_assets/utilities/sec-agent.nix.
const (
	defaultMachineKey = "/machine-key.json"
	secProjectID      = "344379162166820867"
)

// machineKey is Zitadel's machine key JSON (only the fields we use).
type machineKey struct {
	KeyID  string `json:"keyId"`
	UserID string `json:"userId"`
	Key    string `json:"key"`
}

// machineKeyPath honours SEC_MACHINE_KEY like sec-agent.
func machineKeyPath() string {
	if p := os.Getenv("SEC_MACHINE_KEY"); p != "" {
		return p
	}
	return defaultMachineKey
}

func zitadelIssuer() string { return "https://sso." + fleetDomain() }

// loadMachineKey reads and parses the key; errNoToken if the file is missing.
func loadMachineKey(path string) (machineKey, *rsa.PrivateKey, error) {
	var k machineKey
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return k, nil, fmt.Errorf("%w: no Zitadel machine key at %s", errNoToken, path)
		}
		if os.IsPermission(err) {
			return k, nil, fmt.Errorf("%w: public expose signs with this host's machine key (root-only); run sudo fleet containers expose ... (the cnt alias does not expand under sudo)", err)
		}
		return k, nil, err
	}
	if err := json.Unmarshal(b, &k); err != nil {
		return k, nil, fmt.Errorf("%s: %w", path, err)
	}
	if k.KeyID == "" || k.UserID == "" || k.Key == "" {
		return k, nil, fmt.Errorf("%s is missing keyId, userId or key", path)
	}
	blk, _ := pem.Decode([]byte(k.Key))
	if blk == nil {
		return k, nil, errors.New("machine key does not contain a PEM block")
	}
	// Zitadel emits PKCS#1; accept PKCS#8 too (it changed across versions).
	if priv, err := x509.ParsePKCS1PrivateKey(blk.Bytes); err == nil {
		return k, priv, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return k, nil, fmt.Errorf("machine key: %w", err)
	}
	priv, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return k, nil, errors.New("machine key is not an RSA private key")
	}
	return k, priv, nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// mintAssertion builds the RS256 JWT-bearer assertion (5 minute lifetime).
func mintAssertion(k machineKey, priv *rsa.PrivateKey, issuer string, now time.Time) (string, error) {
	jti := make([]byte, 16)
	if _, err := rand.Read(jti); err != nil {
		return "", err
	}
	h, err := json.Marshal(map[string]any{"alg": "RS256", "typ": "JWT", "kid": k.KeyID})
	if err != nil {
		return "", err
	}
	c, err := json.Marshal(map[string]any{
		"iss": k.UserID, "sub": k.UserID, "aud": strings.TrimRight(issuer, "/"),
		"iat": now.Unix(), "exp": now.Unix() + 300, "jti": hex.EncodeToString(jti),
	})
	if err != nil {
		return "", err
	}
	in := b64(h) + "." + b64(c)
	sum := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, priv, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return in + "." + b64(sig), nil
}

// fetchMachineToken exchanges a fresh assertion for a Zitadel token with
// sec-agent's scopes (openid, the project audience, project roles).
func fetchMachineToken(ctx context.Context, hc *http.Client, k machineKey, priv *rsa.PrivateKey, issuer, projectID string) (string, error) {
	assertion, err := mintAssertion(k, priv, issuer, time.Now())
	if err != nil {
		return "", err
	}
	endpoint := strings.TrimRight(issuer, "/") + "/oauth/v2/token"
	var disc struct {
		TokenEndpoint string `json:"token_endpoint"`
	}
	if err := getJSON(ctx, hc, strings.TrimRight(issuer, "/")+"/.well-known/openid-configuration", &disc); err != nil {
		return "", fmt.Errorf("zitadel discovery: %w", err)
	}
	if disc.TokenEndpoint != "" {
		endpoint = disc.TokenEndpoint
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
		"scope":      {"openid urn:zitadel:iam:org:project:id:" + projectID + ":aud urn:zitadel:iam:org:projects:roles"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("zitadel token: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var tr struct {
		AccessToken string `json:"access_token"`
		IDToken     string `json:"id_token"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	_ = json.Unmarshal(raw, &tr)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("zitadel token: HTTP %d: %s %s", resp.StatusCode, tr.Error, tr.Description)
	}
	// Same choice as sec-agent: the token carrying a roles claim, else the
	// first one returned.
	fallback := ""
	for _, t := range []string{tr.AccessToken, tr.IDToken} {
		if t == "" {
			continue
		}
		if fallback == "" {
			fallback = t
		}
		if tokenHasRoles(t) {
			return t, nil
		}
	}
	if fallback == "" {
		return "", errors.New("zitadel returned no usable token")
	}
	return fallback, nil
}

// tokenHasRoles peeks (unverified) at a JWT's flatRolesClaim; h005
// verifies whichever token is sent.
func tokenHasRoles(raw string) bool {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return false
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var c struct {
		Roles []string `json:"flatRolesClaim"`
	}
	return json.Unmarshal(b, &c) == nil && len(c.Roles) > 0
}

func getJSON(ctx context.Context, hc *http.Client, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
}
