package containers

import (
	"strings"
	"testing"
	"time"
)

func TestMoveCarriesExposureWithOriginalDeadline(t *testing.T) {
	for _, level := range []string{"tailnet", "lan"} {
		s := exposeSvc()
		r := s.Routes["web"]
		r.Exposure = "tailnet"
		s.Routes["web"] = r
		o := override{Service: s.Name, Route: "web", Exposure: level, Until: 1200, Host: "h001"}
		script, got, err := carryOverrideScript(s, []override{o}, time.Unix(1000, 0))
		if err != nil || got == nil || !strings.Contains(script, "until=1200") || strings.Contains(script, "until=$((now +") || !strings.Contains(script, `"exposure":"`+level+`"`) {
			t.Fatalf("%s: %v %v %s", level, got, err, script)
		}
		script, _, err = carryOverrideScript(s, []override{o}, time.Unix(1200, 0))
		if err != nil || script != "" {
			t.Fatalf("expired override carried: %v %s", err, script)
		}
	}
}
