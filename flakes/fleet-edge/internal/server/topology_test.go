package server

import (
	"encoding/json"
	"encoding/xml"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/topology"
)

// The same template is parsed as HTML inline and as XML during refresh/download.
// User-facing names must survive both, including XML-sensitive characters.
func TestTopologySVGNamesRoundTrip(t *testing.T) {
	name := `rack & "home" <gear>`
	spec := topology.Default()
	spec.Nodes = []topology.NodeSpec{{ID: "gear", Label: name, Kind: "switch", Zone: "fleet", Lines: []string{`a < b & c > d`}}}
	srv := New(fakeSource{m: sample()}, Config{Topology: spec})
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/topology.svg", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	decoder := xml.NewDecoder(strings.NewReader(w.Body.String()))
	var meta map[string]topology.NodeInfo
	for {
		tok, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("invalid downloadable/refresh SVG: %v", err)
		}
		if start, ok := tok.(xml.StartElement); ok && start.Name.Local == "metadata" {
			var text string
			if err := decoder.DecodeElement(&text, &start); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(text), &meta); err != nil {
				t.Fatalf("invalid node metadata: %v", err)
			}
		}
	}
	if got := meta["gear"]; got.Label != name || len(got.Lines) != 1 || got.Lines[0] != `a < b & c > d` {
		t.Fatalf("node details lost/escaped: %+v", got)
	}
}
