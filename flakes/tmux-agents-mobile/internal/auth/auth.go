// Package auth implements Zitadel OIDC PKCE login, JWKS RSA-256 token
// verification and plain API key authentication. It is copied from
// flakes/fleet-edge/internal/auth (stdlib only, no fleet-edge imports) so both
// apps share one reviewed auth model; the only change is the cookie name. Keep
// the copy in sync if that one gains fixes.
package auth

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	SessionCookieName = "tam_session"
	SessionTTL        = 8 * time.Hour
	PendingLoginTTL   = 10 * time.Minute
	MaxPendingLogins  = 128
	JWKSCacheTTL      = 1 * time.Hour
	ClockSkewSeconds  = 60
	MaxTokenLength    = 32 << 10
)

// ZitadelConfig mirrors containers/sec/container.nix ringofstorms.secrets.server.zitadel.
type ZitadelConfig struct {
	Issuer      string
	ProjectID   string
	Claim       string // default "flatRolesClaim"
	ClientID    string
	RedirectURI string
	AllowedRole string // optional role name (e.g. "admin"); if empty, any valid project token is accepted
}

// Config configures the Authenticator middleware.
type Config struct {
	Zitadel       ZitadelConfig
	APIKeysFile   string   // path to newline-delimited API keys (# comments allowed)
	APIKeys       []string // inline API keys (primarily for tests)
	SessionSecret []byte   // 32-byte HMAC secret; generated randomly at startup if empty
	Now           func() time.Time
	HTTPClient    *http.Client
}

type pendingLogin struct {
	Verifier  string
	ReturnTo  string
	CreatedAt time.Time
}

type jwksKey struct {
	N []byte
	E []byte
}

type sessionPayload struct {
	Subject   string   `json:"sub"`
	Roles     []string `json:"roles,omitempty"`
	IssuedAt  int64    `json:"iat"`
	ExpiresAt int64    `json:"exp"`
}

// Authenticator guards fleet-edge HTTP routes with either:
//  1. A plain API key in `Authorization: Bearer <key>` or `X-API-Key: <key>`
//  2. A verified Zitadel JWT in `Authorization: Bearer <jwt>`
//  3. An HMAC-signed browser session cookie established via OIDC Authorization Code + PKCE
type Authenticator struct {
	cfg           Config
	apiKeys       [][]byte
	sessionSecret []byte

	mu            sync.Mutex
	pendingLogins map[string]pendingLogin
	jwksKeys      map[string]jwksKey
	jwksFetchedAt time.Time
	discovery     *oidcDiscovery
}

type oidcDiscovery struct {
	Issuer                string `json:"issuer"`
	JWKSURI               string `json:"jwks_uri"`
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	UserinfoEndpoint      string `json:"userinfo_endpoint"`
	EndSessionEndpoint    string `json:"end_session_endpoint"`
}

type jwksDocument struct {
	Keys []struct {
		Kid string `json:"kid"`
		Kty string `json:"kty"`
		Alg string `json:"alg"`
		Use string `json:"use"`
		N   string `json:"n"`
		E   string `json:"e"`
	} `json:"keys"`
}

type tokenResponse struct {
	AccessToken      string `json:"access_token"`
	IDToken          string `json:"id_token"`
	TokenType        string `json:"token_type"`
	ExpiresIn        int    `json:"expires_in"`
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// New creates an Authenticator from cfg. If neither Zitadel nor API keys are
// configured, Enabled() is false and Wrap() is a pass-through.
func New(cfg Config) (*Authenticator, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 10 * time.Second}
	}
	if cfg.Zitadel.Claim == "" {
		cfg.Zitadel.Claim = "flatRolesClaim"
	}

	var keys [][]byte
	for _, k := range cfg.APIKeys {
		k = strings.TrimSpace(k)
		if k != "" {
			keys = append(keys, []byte(k))
		}
	}
	if cfg.APIKeysFile != "" {
		loaded, err := loadAPIKeysFile(cfg.APIKeysFile)
		if err != nil {
			return nil, err
		}
		keys = append(keys, loaded...)
	}

	secret := cfg.SessionSecret
	if len(secret) == 0 {
		secret = make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return nil, fmt.Errorf("generating session secret: %w", err)
		}
	}

	return &Authenticator{
		cfg:           cfg,
		apiKeys:       keys,
		sessionSecret: secret,
		pendingLogins: make(map[string]pendingLogin),
		jwksKeys:      make(map[string]jwksKey),
	}, nil
}

func loadAPIKeysFile(path string) ([][]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read api-keys-file %s: %w", path, err)
	}
	var out [][]byte
	for _, line := range strings.Split(string(b), "\n") {
		if idx := strings.IndexByte(line, '#'); idx >= 0 {
			line = line[:idx]
		}
		k := strings.TrimSpace(line)
		if idx := strings.IndexByte(k, ':'); idx > 0 {
			k = strings.TrimSpace(k[idx+1:])
		}
		if len(k) >= 16 {
			out = append(out, []byte(k))
		} else if k != "" {
			return nil, fmt.Errorf("api key in %s is shorter than 16 characters", path)
		}
	}
	return out, nil
}

// Enabled reports whether authentication is active.
func (a *Authenticator) Enabled() bool {
	if a == nil {
		return false
	}
	return a.oidcEnabled() || len(a.apiKeys) > 0
}

func (a *Authenticator) oidcEnabled() bool {
	return a != nil && a.cfg.Zitadel.Issuer != "" && a.cfg.Zitadel.ClientID != ""
}

// Wrap protects next with API key and/or Zitadel OIDC session authentication.
// Only the /auth/* endpoints are served before session enforcement: every other
// route in this app, including static assets, SSE streams and POSTs, requires a
// session.
func (a *Authenticator) Wrap(next http.Handler) http.Handler {
	if !a.Enabled() {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/auth/login":
			a.handleLogin(w, r)
			return
		case "/auth/callback", "/callback":
			a.handleCallback(w, r)
			return
		case "/auth/logout":
			a.handleLogout(w, r)
			return
		}

		if a.checkRequest(r) {
			next.ServeHTTP(w, r)
			return
		}

		// Unauthenticated browser navigation: redirect to Zitadel OIDC login if enabled.
		if a.oidcEnabled() && wantsHTML(r) && (r.Method == http.MethodGet || r.Method == http.MethodHead) {
			q := url.Values{}
			if r.URL.Path != "" && r.URL.Path != "/" {
				returnTo := r.URL.Path
				if r.URL.RawQuery != "" {
					returnTo += "?" + r.URL.RawQuery
				}
				q.Set("return_to", returnTo)
			}
			target := "/auth/login"
			if enc := q.Encode(); enc != "" {
				target += "?" + enc
			}
			http.Redirect(w, r, target, http.StatusFound)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"unauthorized"}`+"\n")
	})
}

func wantsHTML(r *http.Request) bool {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		return false
	}
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") && !strings.Contains(accept, "text/html") {
		return false
	}
	return true
}

func (a *Authenticator) checkRequest(r *http.Request) bool {
	// 1. Check X-API-Key header
	if key := strings.TrimSpace(r.Header.Get("X-API-Key")); key != "" {
		if a.matchAPIKey(key) {
			return true
		}
	}

	// 2. Check Authorization: Bearer <token> (either plain API key or Zitadel JWT)
	if authz := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(strings.ToLower(authz), "bearer ") {
		tok := strings.TrimSpace(authz[7:])
		if tok != "" {
			if a.matchAPIKey(tok) {
				return true
			}
			if a.cfg.Zitadel.Issuer != "" {
				if id, err := a.VerifyZitadelToken(tok); err == nil && a.roleAllowed(id.Roles) {
					return true
				}
			}
		}
	}

	// 3. Check signed session cookie
	if c, err := r.Cookie(SessionCookieName); err == nil && c.Value != "" {
		if sess, ok := a.verifySessionCookie(c.Value); ok && a.roleAllowed(sess.Roles) {
			return true
		}
	}

	return false
}

func (a *Authenticator) matchAPIKey(candidate string) bool {
	candBytes := []byte(candidate)
	matched := false
	for _, k := range a.apiKeys {
		if subtle.ConstantTimeCompare(candBytes, k) == 1 {
			matched = true
		}
	}
	return matched
}

func (a *Authenticator) roleAllowed(roles []string) bool {
	reqRole := a.cfg.Zitadel.AllowedRole
	if reqRole == "" {
		return true
	}
	for _, r := range roles {
		if r == reqRole {
			return true
		}
	}
	return false
}

// mintSessionCookie creates an HMAC-SHA256 signed cookie value.
func (a *Authenticator) mintSessionCookie(sub string, roles []string) (string, error) {
	now := a.cfg.Now()
	p := sessionPayload{
		Subject:   sub,
		Roles:     roles,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(SessionTTL).Unix(),
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	payloadB64 := base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, a.sessionSecret)
	mac.Write([]byte(payloadB64))
	sigB64 := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return payloadB64 + "." + sigB64, nil
}

func (a *Authenticator) verifySessionCookie(val string) (sessionPayload, bool) {
	parts := strings.Split(val, ".")
	if len(parts) != 2 {
		return sessionPayload{}, false
	}
	mac := hmac.New(sha256.New, a.sessionSecret)
	mac.Write([]byte(parts[0]))
	expectedSig := mac.Sum(nil)
	gotSig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || subtle.ConstantTimeCompare(gotSig, expectedSig) != 1 {
		return sessionPayload{}, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return sessionPayload{}, false
	}
	var p sessionPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return sessionPayload{}, false
	}
	now := a.cfg.Now().Unix()
	if p.ExpiresAt <= now || p.Subject == "" {
		return sessionPayload{}, false
	}
	return p, true
}

func (a *Authenticator) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !a.oidcEnabled() {
		http.Error(w, "OIDC sign-in not configured", http.StatusServiceUnavailable)
		return
	}
	disc, err := a.getDiscovery()
	if err != nil {
		http.Error(w, "OIDC discovery failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	stateTok, err := randomToken(24)
	if err != nil {
		http.Error(w, "random error", http.StatusInternalServerError)
		return
	}
	verifier, err := randomToken(48)
	if err != nil {
		http.Error(w, "random error", http.StatusInternalServerError)
		return
	}

	returnTo := sanitizeReturnTo(r.URL.Query().Get("return_to"))
	now := a.cfg.Now()

	a.mu.Lock()
	a.expirePendingLocked(now)
	if len(a.pendingLogins) >= MaxPendingLogins {
		var oldestKey string
		var oldestTime time.Time
		for k, v := range a.pendingLogins {
			if oldestKey == "" || v.CreatedAt.Before(oldestTime) {
				oldestKey = k
				oldestTime = v.CreatedAt
			}
		}
		if oldestKey != "" {
			delete(a.pendingLogins, oldestKey)
		}
	}
	a.pendingLogins[stateTok] = pendingLogin{
		Verifier:  verifier,
		ReturnTo:  returnTo,
		CreatedAt: now,
	}
	a.mu.Unlock()

	scopes := []string{"openid", "profile", "email", "urn:zitadel:iam:org:projects:roles"}
	if a.cfg.Zitadel.ProjectID != "" {
		scopes = append(scopes, "urn:zitadel:iam:org:project:id:"+a.cfg.Zitadel.ProjectID+":aud")
	}

	q := url.Values{}
	q.Set("client_id", a.cfg.Zitadel.ClientID)
	q.Set("redirect_uri", a.redirectURI(r))
	q.Set("response_type", "code")
	q.Set("scope", strings.Join(scopes, " "))
	q.Set("state", stateTok)
	q.Set("code_challenge", pkceChallenge(verifier))
	q.Set("code_challenge_method", "S256")

	authEndpoint := disc.AuthorizationEndpoint
	if authEndpoint == "" {
		authEndpoint = strings.TrimRight(a.cfg.Zitadel.Issuer, "/") + "/oauth/v2/authorize"
	}
	http.Redirect(w, r, authEndpoint+"?"+q.Encode(), http.StatusFound)
}

func (a *Authenticator) handleCallback(w http.ResponseWriter, r *http.Request) {
	if !a.oidcEnabled() {
		http.Error(w, "OIDC sign-in not configured", http.StatusServiceUnavailable)
		return
	}
	stateTok := r.URL.Query().Get("state")
	code := r.URL.Query().Get("code")

	now := a.cfg.Now()
	a.mu.Lock()
	a.expirePendingLocked(now)
	pending, ok := a.pendingLogins[stateTok]
	if ok {
		delete(a.pendingLogins, stateTok)
	}
	a.mu.Unlock()

	if !ok {
		http.Error(w, "invalid or expired OIDC state", http.StatusBadRequest)
		return
	}
	if code == "" {
		http.Error(w, "OIDC provider returned no code: "+r.URL.Query().Get("error"), http.StatusBadRequest)
		return
	}

	tokens, err := a.exchangeCode(r, code, pending.Verifier)
	if err != nil {
		http.Error(w, "OIDC code exchange failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	var verified *VerifiedToken
	for _, cand := range []string{tokens.IDToken, tokens.AccessToken} {
		if cand == "" {
			continue
		}
		vt, err := a.VerifyZitadelToken(cand)
		if err == nil {
			if len(vt.Roles) > 0 {
				verified = &vt
				break
			}
			if verified == nil {
				verified = &vt
			}
		}
	}
	if verified == nil {
		http.Error(w, "no verifiable JWT returned by OIDC provider", http.StatusUnauthorized)
		return
	}
	// Fallback to /oidc/v1/userinfo when roles aren't embedded in the ID/access JWT
	if !a.roleAllowed(verified.Roles) && tokens.AccessToken != "" {
		if uiRoles, err := a.fetchUserInfoRoles(r.Context(), tokens.AccessToken, verified.Subject); err == nil && len(uiRoles) > 0 {
			verified.Roles = appendUniqueStrings(verified.Roles, uiRoles...)
		}
	}
	if !a.roleAllowed(verified.Roles) {
		http.Error(w, fmt.Sprintf("user %s lacks required role %q", verified.Subject, a.cfg.Zitadel.AllowedRole), http.StatusForbidden)
		return
	}

	cookieVal, err := a.mintSessionCookie(verified.Subject, verified.Roles)
	if err != nil {
		http.Error(w, "failed to mint session", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     SessionCookieName,
		Value:    cookieVal,
		Path:     "/",
		MaxAge:   int(SessionTTL.Seconds()),
		HttpOnly: true,
		Secure:   isSecureRequest(r),
		SameSite: http.SameSiteLaxMode,
	})
	http.Redirect(w, r, sanitizeReturnTo(pending.ReturnTo), http.StatusFound)
}

func (a *Authenticator) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     SessionCookieName,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   isSecureRequest(r),
		SameSite: http.SameSiteLaxMode,
	})
	http.Redirect(w, r, "/auth/login", http.StatusFound)
}

func (a *Authenticator) redirectURI(r *http.Request) string {
	if a.cfg.Zitadel.RedirectURI != "" {
		return a.cfg.Zitadel.RedirectURI
	}
	scheme := "http"
	if isSecureRequest(r) {
		scheme = "https"
	}
	return scheme + "://" + r.Host + "/auth/callback"
}

func isSecureRequest(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	return strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func sanitizeReturnTo(raw string) string {
	if raw == "" || !strings.HasPrefix(raw, "/") || strings.HasPrefix(raw, "//") || strings.HasPrefix(raw, "/auth/") {
		return "/"
	}
	return raw
}

func (a *Authenticator) expirePendingLocked(now time.Time) {
	for k, v := range a.pendingLogins {
		if now.Sub(v.CreatedAt) > PendingLoginTTL {
			delete(a.pendingLogins, k)
		}
	}
}

func (a *Authenticator) exchangeCode(r *http.Request, code, verifier string) (tokenResponse, error) {
	disc, err := a.getDiscovery()
	if err != nil {
		return tokenResponse{}, err
	}
	tokenEndpoint := disc.TokenEndpoint
	if tokenEndpoint == "" {
		tokenEndpoint = strings.TrimRight(a.cfg.Zitadel.Issuer, "/") + "/oauth/v2/token"
	}

	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", a.redirectURI(r))
	form.Set("client_id", a.cfg.Zitadel.ClientID)
	form.Set("code_verifier", verifier)

	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, tokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return tokenResponse{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := a.cfg.HTTPClient.Do(req)
	if err != nil {
		return tokenResponse{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return tokenResponse{}, err
	}
	var tr tokenResponse
	if err := json.Unmarshal(body, &tr); err != nil {
		return tokenResponse{}, fmt.Errorf("status %d: invalid JSON", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK || tr.Error != "" {
		return tokenResponse{}, fmt.Errorf("status %d: %s (%s)", resp.StatusCode, tr.Error, tr.ErrorDescription)
	}
	return tr, nil
}
func (a *Authenticator) fetchUserInfoRoles(ctx context.Context, accessToken, expectedSub string) ([]string, error) {
	disc, err := a.getDiscovery()
	if err != nil {
		return nil, err
	}
	uiEndpoint := disc.UserinfoEndpoint
	if uiEndpoint == "" {
		uiEndpoint = strings.TrimRight(a.cfg.Zitadel.Issuer, "/") + "/oidc/v1/userinfo"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, uiEndpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	resp, err := a.cfg.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("userinfo HTTP %d", resp.StatusCode)
	}
	var claims map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&claims); err != nil {
		return nil, err
	}
	if expectedSub != "" && extractSubject(claims) != expectedSub {
		return nil, errors.New("userinfo subject mismatch")
	}
	return extractRoles(claims, a.cfg.Zitadel.Claim, a.cfg.Zitadel.ProjectID), nil
}

func appendUniqueStrings(base []string, extra ...string) []string {
	seen := make(map[string]bool, len(base))
	for _, s := range base {
		seen[s] = true
	}
	for _, s := range extra {
		if s != "" && !seen[s] {
			seen[s] = true
			base = append(base, s)
		}
	}
	return base
}

// VerifiedToken holds the verified subject and roles from a Zitadel JWT.
type VerifiedToken struct {
	Subject string
	Roles   []string
}

// VerifyZitadelToken verifies a raw RS256 JWT against Zitadel's JWKS and checks
// exp/nbf/iat, issuer, and project audience.
func (a *Authenticator) VerifyZitadelToken(raw string) (VerifiedToken, error) {
	if len(raw) > MaxTokenLength {
		return VerifiedToken{}, errors.New("token too large")
	}
	parts := strings.Split(strings.TrimSpace(raw), ".")
	if len(parts) != 3 {
		return VerifiedToken{}, errors.New("malformed JWT")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return VerifiedToken{}, errors.New("invalid JWT header encoding")
	}
	claimsBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return VerifiedToken{}, errors.New("invalid JWT claims encoding")
	}
	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return VerifiedToken{}, errors.New("invalid JWT signature encoding")
	}

	var header map[string]any
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return VerifiedToken{}, errors.New("invalid JWT header JSON")
	}
	var claims map[string]any
	if err := json.Unmarshal(claimsBytes, &claims); err != nil {
		return VerifiedToken{}, errors.New("invalid JWT claims JSON")
	}

	if jsonString(header, "alg") != "RS256" {
		return VerifiedToken{}, errors.New("unsupported JWT alg")
	}
	kid := jsonString(header, "kid")
	if kid == "" {
		return VerifiedToken{}, errors.New("missing JWT kid")
	}

	key, err := a.resolveJWKSKey(kid)
	if err != nil {
		return VerifiedToken{}, err
	}
	pubKey, err := buildRSAPublicKey(key)
	if err != nil {
		return VerifiedToken{}, err
	}

	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(pubKey, crypto.SHA256, digest[:], sigBytes); err != nil {
		return VerifiedToken{}, errors.New("invalid JWT signature")
	}

	now := a.cfg.Now().Unix()
	exp := jsonInt64(claims, "exp")
	if exp == 0 || now > exp+ClockSkewSeconds {
		return VerifiedToken{}, errors.New("JWT expired")
	}
	if nbf := jsonInt64(claims, "nbf"); nbf != 0 && now+ClockSkewSeconds < nbf {
		return VerifiedToken{}, errors.New("JWT not yet valid")
	}
	if iat := jsonInt64(claims, "iat"); iat != 0 && now+ClockSkewSeconds < iat {
		return VerifiedToken{}, errors.New("JWT issued in the future")
	}

	if a.cfg.Zitadel.Issuer != "" {
		iss := jsonString(claims, "iss")
		if strings.TrimRight(iss, "/") != strings.TrimRight(a.cfg.Zitadel.Issuer, "/") {
			return VerifiedToken{}, errors.New("unexpected JWT issuer")
		}
	}
	if a.cfg.Zitadel.ProjectID != "" || a.cfg.Zitadel.ClientID != "" {
		foundAud := false
		for _, aud := range jsonStringList(claims, "aud") {
			if (a.cfg.Zitadel.ProjectID != "" && aud == a.cfg.Zitadel.ProjectID) ||
				(a.cfg.Zitadel.ClientID != "" && aud == a.cfg.Zitadel.ClientID) {
				foundAud = true
				break
			}
		}
		if !foundAud {
			return VerifiedToken{}, errors.New("JWT audience does not include project or client ID")
		}
	}
	sub := extractSubject(claims)
	if sub == "" {
		return VerifiedToken{}, errors.New("JWT missing subject")
	}
	return VerifiedToken{
		Subject: sub,
		Roles:   extractRoles(claims, a.cfg.Zitadel.Claim, a.cfg.Zitadel.ProjectID),
	}, nil
}

func (a *Authenticator) getDiscovery() (oidcDiscovery, error) {
	a.mu.Lock()
	if a.discovery != nil {
		d := *a.discovery
		a.mu.Unlock()
		return d, nil
	}
	a.mu.Unlock()

	discURL := strings.TrimRight(a.cfg.Zitadel.Issuer, "/") + "/.well-known/openid-configuration"
	resp, err := a.cfg.HTTPClient.Get(discURL)
	if err != nil {
		return oidcDiscovery{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return oidcDiscovery{}, fmt.Errorf("discovery HTTP %d", resp.StatusCode)
	}
	var d oidcDiscovery
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&d); err != nil {
		return oidcDiscovery{}, err
	}
	a.mu.Lock()
	a.discovery = &d
	a.mu.Unlock()
	return d, nil
}

func (a *Authenticator) resolveJWKSKey(kid string) (jwksKey, error) {
	now := a.cfg.Now()
	a.mu.Lock()
	if now.Sub(a.jwksFetchedAt) <= JWKSCacheTTL {
		if k, ok := a.jwksKeys[kid]; ok {
			a.mu.Unlock()
			return k, nil
		}
	}
	a.mu.Unlock()

	_ = a.refreshJWKS()

	a.mu.Lock()
	defer a.mu.Unlock()
	if k, ok := a.jwksKeys[kid]; ok {
		return k, nil
	}
	return jwksKey{}, errors.New("unknown JWKS signing key")
}

func (a *Authenticator) refreshJWKS() error {
	disc, err := a.getDiscovery()
	if err != nil {
		return err
	}
	jwksURI := disc.JWKSURI
	if jwksURI == "" {
		jwksURI = strings.TrimRight(a.cfg.Zitadel.Issuer, "/") + "/oauth/v2/keys"
	}
	resp, err := a.cfg.HTTPClient.Get(jwksURI)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("JWKS HTTP %d", resp.StatusCode)
	}
	var doc jwksDocument
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&doc); err != nil {
		return err
	}
	keys := make(map[string]jwksKey)
	for _, entry := range doc.Keys {
		if entry.Kty != "RSA" || entry.Kid == "" {
			continue
		}
		if entry.Alg != "" && entry.Alg != "RS256" {
			continue
		}
		nBytes, err1 := base64.RawURLEncoding.DecodeString(entry.N)
		eBytes, err2 := base64.RawURLEncoding.DecodeString(entry.E)
		if err1 != nil || err2 != nil || len(nBytes) == 0 || len(eBytes) == 0 {
			continue
		}
		keys[entry.Kid] = jwksKey{N: nBytes, E: eBytes}
	}
	if len(keys) == 0 {
		return errors.New("JWKS contained no usable RSA keys")
	}
	a.mu.Lock()
	a.jwksKeys = keys
	a.jwksFetchedAt = a.cfg.Now()
	a.mu.Unlock()
	return nil
}

func buildRSAPublicKey(k jwksKey) (*rsa.PublicKey, error) {
	n := new(big.Int).SetBytes(k.N)
	exp := 0
	for _, b := range k.E {
		exp = exp*256 + int(b)
	}
	if exp < 3 {
		return nil, errors.New("invalid RSA exponent")
	}
	return &rsa.PublicKey{N: n, E: exp}, nil
}

func randomToken(byteLen int) (string, error) {
	b := make([]byte, byteLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func jsonString(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

func jsonInt64(m map[string]any, key string) int64 {
	switch v := m[key].(type) {
	case float64:
		return int64(v)
	case int64:
		return v
	}
	return 0
}

func jsonStringList(m map[string]any, key string) []string {
	switch v := m[key].(type) {
	case string:
		if v != "" {
			return []string{v}
		}
	case []any:
		var out []string
		for _, item := range v {
			if s, ok := item.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

func extractSubject(claims map[string]any) string {
	for _, k := range []string{"sub", "urn:zitadel:iam:user:id", "client_id"} {
		if s := jsonString(claims, k); s != "" {
			return s
		}
	}
	return ""
}

func extractRoles(claims map[string]any, claimName, projectID string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(r string) {
		if r != "" && !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	cands := []string{claimName, "flatRolesClaim", "urn:zitadel:iam:org:project:roles", "roles"}
	if projectID != "" {
		cands = append(cands, "urn:zitadel:iam:org:project:"+projectID+":roles")
	}
	for _, cand := range cands {
		if cand == "" {
			continue
		}
		for _, r := range jsonStringList(claims, cand) {
			add(r)
		}
		if obj, ok := claims[cand].(map[string]any); ok {
			for role := range obj {
				add(role)
			}
		}
	}
	return out
}
