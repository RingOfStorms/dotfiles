package containers

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFetchMachineTokenLikeSecAgent(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyJSON, _ := json.Marshal(machineKey{KeyID: "kid-1", UserID: "344412093056811011",
		Key: string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)}))})
	keyPath := filepath.Join(t.TempDir(), "machine-key.json")
	if err := os.WriteFile(keyPath, keyJSON, 0o600); err != nil {
		t.Fatal(err)
	}
	withRoles := "h." + base64.RawURLEncoding.EncodeToString([]byte(`{"flatRolesClaim":["machines-hightrust"]}`)) + ".s"

	var issuer string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]string{"token_endpoint": issuer + "/oauth/v2/token"})
		case "/oauth/v2/token":
			_ = r.ParseForm()
			if g := r.PostForm.Get("grant_type"); g != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
				t.Errorf("grant_type %q", g)
			}
			if s := r.PostForm.Get("scope"); s != "openid urn:zitadel:iam:org:project:id:"+secProjectID+":aud urn:zitadel:iam:org:projects:roles" {
				t.Errorf("scope %q", s)
			}
			parts := strings.Split(r.PostForm.Get("assertion"), ".")
			if len(parts) != 3 {
				t.Fatalf("assertion %q", r.PostForm.Get("assertion"))
			}
			sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
			sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			if err := rsa.VerifyPKCS1v15(&priv.PublicKey, crypto.SHA256, sum[:], sig); err != nil {
				t.Errorf("assertion signature: %v", err)
			}
			var h, c map[string]any
			hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
			cb, _ := base64.RawURLEncoding.DecodeString(parts[1])
			_ = json.Unmarshal(hb, &h)
			_ = json.Unmarshal(cb, &c)
			if h["kid"] != "kid-1" || h["alg"] != "RS256" {
				t.Errorf("header %v", h)
			}
			if c["iss"] != "344412093056811011" || c["sub"] != "344412093056811011" || c["aud"] != issuer {
				t.Errorf("claims %v", c)
			}
			// Opaque access token, id_token carries the roles: pick the latter.
			_ = json.NewEncoder(w).Encode(map[string]string{"access_token": "opaque", "id_token": withRoles})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	issuer = srv.URL

	k, p, err := loadMachineKey(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	tok, err := fetchMachineToken(context.Background(), srv.Client(), k, p, issuer+"/", secProjectID)
	if err != nil {
		t.Fatal(err)
	}
	if tok != withRoles {
		t.Errorf("token %q, want the one with roles", tok)
	}
}

func TestMissingMachineKeyIsNoToken(t *testing.T) {
	_, _, err := loadMachineKey(filepath.Join(t.TempDir(), "absent.json"))
	if !errors.Is(err, errNoToken) {
		t.Fatalf("got %v", err)
	}
}
