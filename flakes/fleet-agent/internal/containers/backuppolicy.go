package containers

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

// Backup policy CLI and target heartbeat (containers/BACKUP-PLAN.md §2.3, P2).
// Both talk to h005's /api/backup with the host's machine token.

// edgeDoer is the slice of edgeClient the backup commands use (tests fake it).
type edgeDoer interface {
	do(method, path string, body any, out any) error
}

var backupEdge = func() (edgeDoer, error) { return edgeClientFor() }

type bpStats struct {
	LocalBytes *int64 `json:"localBytes,omitempty"`
	B2Bytes    *int64 `json:"b2Bytes,omitempty"`
	LastBackup int64  `json:"lastBackup,omitempty"`
	LastCopied int64  `json:"lastCopied,omitempty"`
	Complete   *bool  `json:"complete,omitempty"`
	At         int64  `json:"at,omitempty"`
}

type bpClear struct {
	Scope  string   `json:"scope"`
	Target string   `json:"target"`
	Done   []string `json:"done"`
}

type bpRow struct {
	Subject        string   `json:"subject"`
	Target         string   `json:"target"`
	Offsite        bool     `json:"offsite"`
	RetentionLocal string   `json:"retentionLocal"`
	RetentionB2    string   `json:"retentionB2"`
	Revision       int64    `json:"revision"`
	By             string   `json:"by"`
	Clear          *bpClear `json:"clear"`
}

type bpTarget struct {
	ID      string             `json:"id"`
	URL     string             `json:"url"`
	Pusher  bool               `json:"pusher"`
	Enabled bool               `json:"enabled"`
	Seen    int64              `json:"seen"`
	Stale   bool               `json:"stale"`
	Stats   map[string]bpStats `json:"stats"`
}

type bpExport struct {
	Rows     []bpRow    `json:"rows"`
	Targets  []bpTarget `json:"targets"`
	Subjects []string   `json:"subjects"`
}

const backupPolicyHelp = `usage: fleet containers backup-policy <command>

  list                         policy rows (explicit and default), targets, sizes
  set <subject> [target=<id|none>] [offsite=true|false] [local=short|standard|long]
                [b2=short|standard|long|local]
                               change a row (target=none turns backups off; nothing is deleted)
  clear <subject> local|b2|both
                               queue a repo deletion on the holding target (asks for
                               the typed confirmation "clear svc-<subject> <scope>")
  heartbeat --id <host> --url <rest:http://…/> [--pusher] [--stats FILE] [--out FILE]
                               target only: register, post stats, save the reply
                               (presets, pending clears) for prune/clear units

Writes need a backup writer's machine key: sudo fleet containers backup-policy set …
`

func cmdBackupPolicy(args []string) error {
	if len(args) == 0 {
		fmt.Fprint(usageOut, backupPolicyHelp)
		return errors.New("backup-policy: missing command")
	}
	c, err := backupEdge()
	if err != nil {
		return err
	}
	switch args[0] {
	case "list", "ls":
		return backupPolicyList(c, os.Stdout)
	case "set":
		return backupPolicySet(c, args[1:], os.Stdout)
	case "clear":
		return backupPolicyClear(c, args[1:], os.Stdin, os.Stdout)
	case "heartbeat":
		return backupHeartbeat(c, args[1:])
	}
	fmt.Fprint(usageOut, backupPolicyHelp)
	return fmt.Errorf("backup-policy: unknown command %q", args[0])
}

func fmtBytes(p *int64) string {
	if p == nil {
		return "-"
	}
	f, u := float64(*p), 0
	for f >= 1024 && u < 5 {
		f /= 1024
		u++
	}
	return fmt.Sprintf("%.1f%s", f, []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}[u])
}

func backupPolicyList(c edgeDoer, out interface{ Write([]byte) (int, error) }) error {
	var e bpExport
	if err := c.do("GET", "/api/backup", nil, &e); err != nil {
		return err
	}
	rows := map[string]bpRow{}
	for _, r := range e.Rows {
		rows[r.Subject] = r
	}
	stats := func(subject string) bpStats {
		for _, t := range e.Targets {
			if s, ok := t.Stats[subject]; ok {
				return s
			}
		}
		return bpStats{}
	}
	w := tabwriter.NewWriter(out, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "SUBJECT\tTARGET\tOFFSITE\tLOCAL\tB2\tREV\tSIZE\tB2 SIZE\tPENDING")
	names := append([]string{"default"}, e.Subjects...)
	// Repos a target reports that the inventory does not name (a canary, a
	// retired service): listed after it, with stats and no invented policy.
	listed := map[string]bool{"default": true}
	for _, n := range e.Subjects {
		listed[n] = true
	}
	var unlisted []string
	for _, t := range e.Targets {
		for n := range t.Stats {
			if !listed[n] {
				listed[n] = true
				unlisted = append(unlisted, n)
			}
		}
	}
	sort.Strings(unlisted)
	nInventory := len(names)
	names = append(names, unlisted...)
	for i, n := range names {
		r, explicit := rows[n]
		tgt := r.Target
		switch {
		case i >= nInventory && !explicit:
			r = bpRow{Target: "-", RetentionLocal: "-", RetentionB2: "-"}
			tgt = "- (not in inventory)"
		case i >= nInventory:
			tgt += " (not in inventory)"
		case !explicit:
			r = rows["default"]
			r.Revision = 0
			tgt = r.Target
			if n != "default" {
				tgt += " (default)"
			}
		}
		pend := ""
		if r.Clear != nil && explicit {
			pend = "clear " + r.Clear.Scope
		}
		s := stats(n)
		fmt.Fprintf(w, "%s\t%s\t%v\t%s\t%s\t%d\t%s\t%s\t%s\n", n, tgt, r.Offsite, r.RetentionLocal, r.RetentionB2, r.Revision,
			fmtBytes(s.LocalBytes), fmtBytes(s.B2Bytes), pend)
	}
	fmt.Fprintln(w)
	for _, t := range e.Targets {
		state := "ok"
		switch {
		case !t.Enabled:
			state = "disabled"
		case t.Stale:
			state = "stale"
		}
		fmt.Fprintf(w, "target %s\t%s\tpusher=%v\t%s\tseen %s\n", t.ID, t.URL, t.Pusher, state, time.Unix(t.Seen, 0).UTC().Format(time.RFC3339))
	}
	return w.Flush()
}

func backupPolicySet(c edgeDoer, args []string, out interface{ Write([]byte) (int, error) }) error {
	if len(args) < 2 {
		return errors.New("usage: backup-policy set <subject> key=value…")
	}
	subject := args[0]
	body := map[string]any{"user": exposeUser()}
	for _, kv := range args[1:] {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			return fmt.Errorf("%q: want key=value", kv)
		}
		switch k {
		case "target":
			body["target"] = v
		case "offsite":
			b, err := strconv.ParseBool(v)
			if err != nil {
				return fmt.Errorf("offsite: %v", err)
			}
			body["offsite"] = b
		case "local", "retentionLocal":
			body["retentionLocal"] = v
		case "b2", "retentionB2":
			body["retentionB2"] = v
		default:
			return fmt.Errorf("unknown key %q (target, offsite, local, b2)", k)
		}
	}
	var cur struct {
		Row bpRow `json:"row"`
	}
	if err := c.do("GET", "/api/backup/"+subject, nil, &cur); err != nil {
		return err
	}
	body["revision"] = cur.Row.Revision
	var row bpRow
	if err := c.do("PUT", "/api/backup/"+subject, body, &row); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s: target=%s offsite=%v local=%s b2=%s (revision %d)\n", row.Subject, row.Target, row.Offsite, row.RetentionLocal, row.RetentionB2, row.Revision)
	return nil
}

func backupPolicyClear(c edgeDoer, args []string, in interface{ Read([]byte) (int, error) }, out interface{ Write([]byte) (int, error) }) error {
	if len(args) != 2 {
		return errors.New("usage: backup-policy clear <subject> local|b2|both")
	}
	want := "clear svc-" + args[0] + " " + args[1]
	fmt.Fprintf(out, "This deletes backup data. Type %q to confirm: ", want)
	buf := make([]byte, 256)
	n, _ := in.Read(buf)
	got := strings.TrimSpace(string(buf[:n]))
	if got != want {
		return errors.New("confirmation does not match; nothing queued")
	}
	var row bpRow
	if err := c.do("POST", "/api/backup/"+args[0]+"/clear", map[string]string{"scope": args[1], "confirm": got, "user": exposeUser()}, &row); err != nil {
		return err
	}
	fmt.Fprintf(out, "queued: clear %s on %s (runs on its next heartbeat)\n", row.Clear.Scope, row.Clear.Target)
	return nil
}

// backupHeartbeat posts this target's record and stats and saves the reply
// atomically (0600) for the prune and clear units. The stats file is the
// stats unit's output: {subject: stats}; cleared.json (next to --out) lists
// finished clears and is removed once reported.
func backupHeartbeat(c edgeDoer, args []string) error {
	var id, url, statsFile, outFile string
	pusher := false
	for len(args) > 0 {
		switch args[0] {
		case "--id":
			id, args = need(args), args[2:]
		case "--url":
			url, args = need(args), args[2:]
		case "--stats":
			statsFile, args = need(args), args[2:]
		case "--out":
			outFile, args = need(args), args[2:]
		case "--pusher":
			pusher, args = true, args[1:]
		default:
			return fmt.Errorf("heartbeat: unknown flag %s", args[0])
		}
	}
	if id == "" || url == "" || outFile == "" {
		return errors.New("heartbeat: --id, --url and --out are required")
	}
	body := map[string]any{"url": url, "pusher": pusher}
	if statsFile != "" {
		if b, err := os.ReadFile(statsFile); err == nil {
			var st map[string]bpStats
			if err := json.Unmarshal(b, &st); err != nil {
				return fmt.Errorf("%s: %w", statsFile, err)
			}
			body["stats"] = st
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	clearedFile := filepath.Join(filepath.Dir(outFile), "cleared.json")
	if b, err := os.ReadFile(clearedFile); err == nil {
		var cl map[string][]string
		if json.Unmarshal(b, &cl) == nil && len(cl) > 0 {
			body["cleared"] = cl
		}
	}
	var reply json.RawMessage
	if err := c.do("POST", "/api/backup/targets/"+id, body, &reply); err != nil {
		return err
	}
	if body["cleared"] != nil {
		_ = os.Remove(clearedFile)
	}
	tmp, err := os.CreateTemp(filepath.Dir(outFile), ".policy-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(reply, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), outFile)
}

// sortedKeys is used by tests.
func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
