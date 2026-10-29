package web

import (
	"compress/gzip"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testServer(roots ...string) *Server {
	return &Server{roots: roots, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func TestValidPane(t *testing.T) {
	valid := []string{"0", "12", "999"}
	for _, s := range valid {
		if !validPane(s) {
			t.Errorf("validPane(%q) = false", s)
		}
	}
	invalid := []string{"", "%12", "1a", "1 2", "-1", "123456789", "../1"}
	for _, s := range invalid {
		if validPane(s) {
			t.Errorf("validPane(%q) = true", s)
		}
	}
}

func TestSlug(t *testing.T) {
	if got := Slug("%42"); got != "42" {
		t.Fatalf("Slug = %q", got)
	}
}

func TestValidSessionName(t *testing.T) {
	for _, s := range []string{"nix", "a.b-c_d", "x1"} {
		if !validSessionName(s) {
			t.Errorf("validSessionName(%q) = false", s)
		}
	}
	for _, s := range []string{"", "-x", ".hidden", "with space", "semi;colon", "a/b", strings.Repeat("x", 41)} {
		if validSessionName(s) {
			t.Errorf("validSessionName(%q) = true", s)
		}
	}
}

func TestAllowedDir(t *testing.T) {
	root := t.TempDir()
	inside := filepath.Join(root, "repo")
	if err := os.Mkdir(inside, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()

	s := testServer(root)
	if got, err := s.allowedDir(inside); err != nil || got != inside {
		t.Fatalf("allowedDir(inside) = %q, %v", got, err)
	}
	if _, err := s.allowedDir(root); err != nil {
		t.Fatalf("allowedDir(root) = %v", err)
	}
	if _, err := s.allowedDir(outside); err == nil {
		t.Fatal("allowedDir(outside) should fail")
	}
	if _, err := s.allowedDir(filepath.Join(root, "nope")); err == nil {
		t.Fatal("allowedDir(missing) should fail")
	}
	// A symlink inside the root must not smuggle a path out of it.
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink: %v", err)
	}
	if _, err := s.allowedDir(link); err == nil {
		t.Fatal("allowedDir(symlink escape) should fail")
	}
}

func TestOriginCheck(t *testing.T) {
	s := testServer()
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	h := s.originCheck(ok)

	tests := []struct {
		name   string
		host   string
		origin string
		fetch  string
		want   int
	}{
		{"same origin", "", "http://example.test", "", http.StatusNoContent},
		{"cross origin", "", "http://evil.test", "", http.StatusForbidden},
		{"same site fetch", "", "", "same-origin", http.StatusNoContent},
		{"cross site fetch", "", "", "cross-site", http.StatusForbidden},
		{"same-site fetch", "", "", "same-site", http.StatusForbidden},
		{"no headers", "", "", "", http.StatusNoContent},
		// Behind a TLS proxy the browser's Origin and the Host Go sees differ
		// (tailscale serve, nginx with proxy_set_header Host $proxy_host, a
		// hostname alias). Sec-Fetch-Site is the signal that survives that.
		{"proxy https origin", "127.0.0.1:8099", "https://lio.example", "same-origin", http.StatusNoContent},
		// No fetch metadata: compare hostnames, ignoring scheme and port.
		{"scheme differs", "", "https://example.test", "", http.StatusNoContent},
		{"port differs", "", "http://example.test:9999", "", http.StatusNoContent},
		{"different host same port", "", "http://evil.test:9999", "", http.StatusForbidden},
	}
	for _, tc := range tests {
		req := httptest.NewRequest(http.MethodPost, "http://example.test/p/1/keys", nil)
		if tc.host != "" {
			req.Host = tc.host
		}
		if tc.origin != "" {
			req.Header.Set("Origin", tc.origin)
		}
		if tc.fetch != "" {
			req.Header.Set("Sec-Fetch-Site", tc.fetch)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("%s: status = %d, want %d (%s)", tc.name, rec.Code, tc.want, rec.Body.String())
		}
	}

	// GETs are never blocked.
	req := httptest.NewRequest(http.MethodGet, "http://example.test/", nil)
	req.Header.Set("Origin", "http://evil.test")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Errorf("GET with foreign origin = %d", rec.Code)
	}
}

func TestSameHostname(t *testing.T) {
	tests := []struct {
		origin, host string
		want         bool
	}{
		{"http://example.test", "example.test", true},
		{"https://example.test", "example.test", true},
		{"http://example.test:8099", "example.test", true},
		{"http://example.test", "example.test:8099", true},
		{"http://[::1]:8099", "[::1]:8099", true},
		{"http://[fd7a:115c:a1e0::1]:8099", "fd7a:115c:a1e0::1", true},
		{"http://evil.test", "example.test", false},
		{"null", "example.test", false},
		{"", "example.test", false},
	}
	for _, tc := range tests {
		if got := sameHostname(tc.origin, tc.host); got != tc.want {
			t.Errorf("sameHostname(%q, %q) = %v, want %v", tc.origin, tc.host, got, tc.want)
		}
	}
}

func TestGzipCompressesHTML(t *testing.T) {
	body := strings.Repeat("agent output ", 200)
	h := gzipHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, body)
	}))
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("content-encoding = %q", got)
	}
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != body {
		t.Fatal("round trip mismatch")
	}
}

func TestGzipLeavesEventStreamAlone(t *testing.T) {
	h := gzipHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "event: init\ndata: {}\n\n")
	}))
	req := httptest.NewRequest(http.MethodGet, "/p/0/events", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Encoding"); got != "" {
		t.Fatalf("event stream was compressed: %q", got)
	}
	if !strings.Contains(rec.Body.String(), "event: init") {
		t.Fatalf("body = %q", rec.Body.String())
	}
}

func TestValidKey(t *testing.T) {
	for _, k := range []string{"Enter", "C-c", "M-x", "BTab", "Up", "x", "1", "F5"} {
		if !validKey(k) {
			t.Errorf("validKey(%q) = false", k)
		}
	}
	for _, k := range []string{"", "run-shell", "C-", "Escape; rm -rf /", "Enter Enter"} {
		if validKey(k) {
			t.Errorf("validKey(%q) = true", k)
		}
	}
}

// The inbox must use the same glyphs as the tmux status line, so an operator
// does not have to translate between the desktop and the phone.
func TestStateGlyph(t *testing.T) {
	tests := []struct {
		state  string
		unseen bool
		glyph  string
		class  string
	}{
		{"input", false, "!", "input"},
		{"working", false, "⠿", "working"},
		{"idle", true, "●", "done"},
		{"idle", false, "○", "idle"},
		{"", false, "·", "none"},
	}
	for _, tc := range tests {
		glyph, class := stateGlyph(tc.state, tc.unseen)
		if glyph != tc.glyph || class != tc.class {
			t.Errorf("stateGlyph(%q, %v) = %q/%q, want %q/%q", tc.state, tc.unseen, glyph, class, tc.glyph, tc.class)
		}
	}
}

// A browser always sends Accept-Encoding: gzip, so the event stream must reach
// it through the gzip wrapper (which is a no-op for text/event-stream) and the
// logging recorder. If any wrapper swallows Flush, every event sits in the
// server's write buffer and the pane never updates until a reload - the exact
// bug this test exists to prevent.
func TestEventStreamFlushesThroughMiddleware(t *testing.T) {
	s := testServer()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "event: init\ndata: {}\n\n")
		_ = http.NewResponseController(w).Flush()
		<-r.Context().Done()
	})

	// Same order as Server.Handler()/middleware: the recorder is outside the
	// gzip writer, which is outside the handlers.
	handler := s.logger(s.headers(gzipHandler(mux)))
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, err := http.NewRequest(http.MethodGet, srv.URL+"/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if got := resp.Header.Get("Content-Encoding"); got != "" {
		t.Fatalf("event stream was compressed: %q", got)
	}

	type readResult struct {
		data []byte
		err  error
	}
	read := make(chan readResult, 1)
	go func() {
		buf := make([]byte, 64)
		n, err := resp.Body.Read(buf)
		read <- readResult{data: buf[:n], err: err}
	}()

	select {
	case res := <-read:
		if res.err != nil {
			t.Fatalf("read: %v", res.err)
		}
		if !strings.Contains(string(res.data), "event: init") {
			t.Fatalf("got %q", res.data)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first event was not flushed: the stream is buffered")
	}
}
