package backupui

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
)

func TestRevealIsPostCSRFOnly(t *testing.T) {
	f := newFx(t)
	g := httptest.NewRequest("GET", "/backup/forgejo/reveal", nil)
	g.RemoteAddr = "127.0.0.1:1"
	g.Header.Set("X-Auth-Request-Email", admin)
	g.Header.Set("X-Auth-Request-Groups", "role:admin")
	w := httptest.NewRecorder()
	f.ui.ServeHTTP(w, g)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET reveal: %d", w.Code)
	}
	for name, q := range map[string]req{
		"no csrf":   {csrf: "-"},
		"forged":    {csrf: "deadbeef"},
		"origin":    {origin: "https://evil.example"},
		"non-admin": {user: "eve@example.com", groups: "users"},
	} {
		if w := f.post("/backup/forgejo/reveal", q); w.Code != http.StatusForbidden || strings.Contains(w.Body.String(), "RESTIC_PASSWORD=") {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
	w = f.post("/backup/forgejo/reveal", req{})
	if w.Code != 200 || !strings.Contains(w.Body.String(), "RESTIC_REST_USERNAME=svc-forgejo") {
		t.Fatalf("reveal: %d %s", w.Code, w.Body)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("reveal page is cacheable")
	}
}

var exportRe = regexp.MustCompile(`(?s)<textarea id="export"[^>]*>(.*?)</textarea>`)

func TestExportImportUI(t *testing.T) {
	f := newFx(t)
	// main page warns: never exported
	if _, page := f.getPage(t); !strings.Contains(page, "not exported") {
		t.Fatal("no export warning")
	}
	if w := f.post("/backup/_credentials/export", req{user: "eve@example.com", groups: "users"}); w.Code != 403 {
		t.Fatalf("non-admin export: %d", w.Code)
	}
	if w := f.post("/backup/_credentials/export", req{csrf: "-"}); w.Code != 403 {
		t.Fatalf("export without csrf: %d", w.Code)
	}
	w := f.post("/backup/_credentials/export", req{})
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" || !strings.Contains(w.Body.String(), "navigator.clipboard.writeText") {
		t.Fatalf("export: %d %v", w.Code, w.Header())
	}
	m := exportRe.FindStringSubmatch(w.Body.String())
	if m == nil {
		t.Fatal("no export textarea")
	}
	text := strings.ReplaceAll(m[1], "&#43;", "+")
	if !strings.Contains(text, "svc-forgejo RESTIC_PASSWORD=") {
		t.Fatalf("export text: %s", text)
	}
	if _, page := f.getPage(t); strings.Contains(page, "not exported") {
		t.Fatal("warning after export")
	}
	// rotate via UI -> differs; preview then apply without and with overwrite
	if w := f.post("/backup/forgejo/rotate", req{}); w.Code != http.StatusSeeOther {
		t.Fatalf("rotate: %d", w.Code)
	}
	if _, page := f.getPage(t); !strings.Contains(page, "pending on h004") {
		t.Fatal("no pending rotation shown")
	}
	before, _ := f.svc.RevealAs("t", "forgejo")
	w = f.post("/backup/_credentials/import", req{form: url.Values{"step": {"preview"}, "text": {text}}})
	if w.Code != 200 || !strings.Contains(w.Body.String(), "differs") || !strings.Contains(w.Body.String(), `name="overwrite-forgejo"`) {
		t.Fatalf("preview: %d %s", w.Code, w.Body)
	}
	if now, _ := f.svc.RevealAs("t", "forgejo"); now.RestPassword != before.RestPassword {
		t.Fatal("preview wrote")
	}
	f.post("/backup/_credentials/import", req{form: url.Values{"step": {"apply"}, "text": {text}}})
	if now, _ := f.svc.RevealAs("t", "forgejo"); now.RestPassword != before.RestPassword {
		t.Fatal("applied without overwrite checkbox")
	}
	if w := f.post("/backup/_credentials/import", req{csrf: "x", form: url.Values{"step": {"apply"}, "text": {text}, "overwrite-forgejo": {"on"}}}); w.Code != 403 {
		t.Fatalf("import forged csrf: %d", w.Code)
	}
	f.post("/backup/_credentials/import", req{form: url.Values{"step": {"apply"}, "text": {text}, "overwrite-forgejo": {"on"}}})
	if now, _ := f.svc.RevealAs("t", "forgejo"); now.RestPassword == before.RestPassword || !strings.Contains(text, now.RestPassword) {
		t.Fatal("overwrite not applied")
	}
}

// getPage fetches the Credentials tab (export state, rotation status).
func (f *fx) getPage(t *testing.T) (int, string) {
	t.Helper()
	r := httptest.NewRequest("GET", "/backup/?tab=credentials", nil)
	r.RemoteAddr = "127.0.0.1:4000"
	r.Header.Set("X-Auth-Request-Email", admin)
	r.Header.Set("X-Auth-Request-Groups", "role:admin")
	g := httptest.NewRecorder()
	f.ui.ServeHTTP(g, r)
	if g.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("main page cacheable")
	}
	return g.Code, g.Body.String()
}
