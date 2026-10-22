package auth

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAPIKeyAndOIDCFlow(t *testing.T) {
	privKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)

	var idpURL string
	idp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"issuer":                 idpURL,
				"jwks_uri":               idpURL + "/oauth/v2/keys",
				"authorization_endpoint": idpURL + "/oauth/v2/authorize",
				"token_endpoint":         idpURL + "/oauth/v2/token",
			})
		case "/oauth/v2/keys":
			eBytes := big.NewInt(int64(privKey.PublicKey.E)).Bytes()
			_ = json.NewEncoder(w).Encode(map[string]any{
				"keys": []map[string]any{
					{
						"kid": "k1",
						"kty": "RSA",
						"alg": "RS256",
						"use": "sig",
						"n":   base64.RawURLEncoding.EncodeToString(privKey.PublicKey.N.Bytes()),
						"e":   base64.RawURLEncoding.EncodeToString(eBytes),
					},
				},
			})
		case "/oauth/v2/token":
			jwt := signTestJWT(t, privKey, "k1", map[string]any{
				"iss":            idpURL,
				"sub":            "user-123",
				"aud":            []string{"proj-1"},
				"exp":            now.Add(1 * time.Hour).Unix(),
				"iat":            now.Unix(),
				"flatRolesClaim": []string{"admin"},
			})
			_ = json.NewEncoder(w).Encode(map[string]any{
				"access_token": jwt,
				"id_token":     jwt,
				"token_type":   "Bearer",
				"expires_in":   3600,
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer idp.Close()
	idpURL = idp.URL

	keyFile := filepath.Join(t.TempDir(), "keys")
	if err := os.WriteFile(keyFile, []byte("# comment\nsecret-api-key-1234567890\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	authn, err := New(Config{
		Zitadel: ZitadelConfig{
			Issuer:      idpURL,
			ProjectID:   "proj-1",
			Claim:       "flatRolesClaim",
			ClientID:    "client-1",
			RedirectURI: "https://fleet.joshuabell.xyz/auth/callback",
		},
		APIKeysFile: keyFile,
		Now:         func() time.Time { return now },
		HTTPClient:  idp.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}

	protected := authn.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))

	// 1. Unauthenticated browser request redirects to /auth/login
	req := httptest.NewRequest(http.MethodGet, "/hosts", nil)
	req.Header.Set("Accept", "text/html")
	rec := httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || !strings.HasPrefix(rec.Header().Get("Location"), "/auth/login?return_to=%2Fhosts") {
		t.Fatalf("expected redirect to /auth/login, got %d (%s)", rec.Code, rec.Header().Get("Location"))
	}

	// 2. Unauthenticated API request returns 401
	req = httptest.NewRequest(http.MethodGet, "/api/state", nil)
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauthenticated /api/state, got %d", rec.Code)
	}

	// 3. Valid X-API-Key succeeds
	req = httptest.NewRequest(http.MethodGet, "/api/state", nil)
	req.Header.Set("X-API-Key", "secret-api-key-1234567890")
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 with X-API-Key, got %d", rec.Code)
	}

	// 4. Valid Authorization: Bearer <api-key> succeeds
	req = httptest.NewRequest(http.MethodGet, "/api/state", nil)
	req.Header.Set("Authorization", "Bearer secret-api-key-1234567890")
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 with Bearer API key, got %d", rec.Code)
	}

	// 5. OIDC PKCE login + callback sets session cookie
	req = httptest.NewRequest(http.MethodGet, "/auth/login?return_to=/hosts", nil)
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("expected 302 from /auth/login, got %d", rec.Code)
	}
	authLoc := rec.Header().Get("Location")
	var stateParam string
	for _, kv := range strings.Split(strings.SplitN(authLoc, "?", 2)[1], "&") {
		if after, ok := strings.CutPrefix(kv, "state="); ok {
			stateParam = after
		}
	}
	if stateParam == "" {
		t.Fatalf("missing state parameter in %s", authLoc)
	}

	req = httptest.NewRequest(http.MethodGet, "/auth/callback?code=test-code&state="+stateParam, nil)
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/hosts" {
		t.Fatalf("expected redirect to /hosts after callback, got %d (%s): %s", rec.Code, rec.Header().Get("Location"), rec.Body.String())
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 || cookies[0].Name != SessionCookieName {
		t.Fatalf("expected %s cookie, got %+v", SessionCookieName, cookies)
	}

	// 6. Subsequent browser request with session cookie succeeds
	req = httptest.NewRequest(http.MethodGet, "/hosts", nil)
	req.AddCookie(cookies[0])
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 with session cookie, got %d", rec.Code)
	}

	// 7. Cross-project JWT (different aud and project-scoped role) is rejected
	otherProjJWT := signTestJWT(t, privKey, "k1", map[string]any{
		"iss": idpURL,
		"sub": "user-123",
		"aud": []string{"other-project", "other-client"},
		"exp": now.Add(1 * time.Hour).Unix(),
		"iat": now.Unix(),
		"urn:zitadel:iam:org:project:other-project:roles": map[string]any{"admin": map[string]any{"org": "x"}},
	})
	req = httptest.NewRequest(http.MethodGet, "/api/state", nil)
	req.Header.Set("Authorization", "Bearer "+otherProjJWT)
	rec = httptest.NewRecorder()
	protected.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for cross-project JWT, got %d", rec.Code)
	}

	// 8. Userinfo subject mismatch is rejected by fetchUserInfoRoles
	badUI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"issuer":            idpURL,
				"userinfo_endpoint": "http://" + r.Host + "/oidc/v1/userinfo",
			})
		case "/oidc/v1/userinfo":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"sub":            "different-user",
				"flatRolesClaim": []string{"admin"},
			})
		}
	}))
	defer badUI.Close()
	authnMismatch, err := New(Config{
		Zitadel: ZitadelConfig{
			Issuer:      badUI.URL,
			ProjectID:   "proj-1",
			Claim:       "flatRolesClaim",
			ClientID:    "client-1",
			AllowedRole: "admin",
		},
		HTTPClient: badUI.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if roles, err := authnMismatch.fetchUserInfoRoles(req.Context(), "tok", "user-123"); err == nil || len(roles) != 0 {
		t.Fatalf("expected error on userinfo subject mismatch, got roles=%v err=%v", roles, err)
	}
}

func signTestJWT(t *testing.T, priv *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	hdr, _ := json.Marshal(map[string]any{"alg": "RS256", "typ": "JWT", "kid": kid})
	clm, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(hdr) + "." + base64.RawURLEncoding.EncodeToString(clm)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, priv, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}
