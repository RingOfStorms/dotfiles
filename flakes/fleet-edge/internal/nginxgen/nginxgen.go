// Package nginxgen confirms that nginx actually loaded a new configuration
// after a reload. On NixOS `systemctl reload nginx` is `nginx -t` followed by
// `kill -HUP $MAINPID` (nixpkgs nixos/modules/services/web-servers/nginx,
// ExecReload), so it exits 0 as soon as the signal is sent. The master then
// re-reads its config, and that can still fail at runtime (e.g. bind() of a
// new listen port that something else holds, which `nginx -t` never tries):
// it logs [emerg] and keeps serving the old config with its old workers.
//
// The proof used here: a master that loads a new cycle starts fresh worker
// processes and tells the old ones to drain (their title becomes "nginx:
// worker process is shutting down"); a failed cycle leaves the old workers
// serving. So a config written before Watch is live once the master has a
// serving worker and none of its serving workers was serving at Watch time.
// (A lone worker that crashes and is respawned under the old config would
// pass too; the master respawns it only after a crash.)
package nginxgen

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Poll is how often Await re-checks (var for tests).
var Poll = 50 * time.Millisecond

// workerTitle is a serving worker's /proc cmdline (ngx_setproctitle).
const workerTitle = "nginx: worker process"

// proc identifies a process; the start time tells a reused pid apart.
type proc struct {
	pid   int
	start string
}

// Watcher remembers which nginx workers were serving at Watch time.
type Watcher struct {
	root    string // procfs
	mainPID string // shell command printing the master's pid
	before  map[proc]bool
}

// Watch snapshots the serving workers of the nginx master whose pid the
// shell command mainPID prints. Call it after the new config is on disk and
// before the reload.
func Watch(mainPID string) (*Watcher, error) { return watch("/proc", mainPID) }

func watch(root, mainPID string) (*Watcher, error) {
	w := &Watcher{root: root, mainPID: mainPID, before: map[proc]bool{}}
	serving, err := w.serving()
	if err != nil {
		return nil, err
	}
	for _, p := range serving {
		w.before[p] = true
	}
	return w, nil
}

// Applied reports whether nginx serves a config loaded after Watch: it has a
// serving worker and every serving worker is new. The master pid is re-read
// each time, so a restarted master counts as applied once its workers run.
func (w *Watcher) Applied() (bool, error) {
	serving, err := w.serving()
	if err != nil {
		return false, err
	}
	for _, p := range serving {
		if w.before[p] {
			return false, nil
		}
	}
	return len(serving) > 0, nil
}

func (w *Watcher) master() (int, error) {
	out, err := exec.Command("/bin/sh", "-c", w.mainPID).Output()
	if err != nil {
		return 0, fmt.Errorf("nginx main pid: %v", err)
	}
	s := strings.TrimSpace(string(out))
	pid, err := strconv.Atoi(s)
	if err != nil || pid <= 1 {
		return 0, fmt.Errorf("nginx main pid %q: nginx not running", s)
	}
	return pid, nil
}

// serving lists the master's children titled workerTitle (not draining
// workers, cache manager or loader).
func (w *Watcher) serving() ([]proc, error) {
	master, err := w.master()
	if err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(w.root)
	if err != nil {
		return nil, err
	}
	var out []proc
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		dir := filepath.Join(w.root, e.Name())
		stat, err := os.ReadFile(filepath.Join(dir, "stat"))
		if err != nil {
			continue // exited meanwhile
		}
		ppid, start, ok := parseStat(stat)
		if !ok || ppid != master {
			continue
		}
		cmd, err := os.ReadFile(filepath.Join(dir, "cmdline"))
		if err != nil || strings.TrimRight(string(cmd), "\x00") != workerTitle {
			continue
		}
		out = append(out, proc{pid: pid, start: start})
	}
	return out, nil
}

// parseStat returns ppid (field 4) and starttime (field 22) of a
// /proc/<pid>/stat line; comm (field 2) may contain spaces and parens.
func parseStat(b []byte) (int, string, bool) {
	i := bytes.LastIndexByte(b, ')')
	if i < 0 {
		return 0, "", false
	}
	f := strings.Fields(string(b[i+1:]))
	if len(f) < 20 {
		return 0, "", false
	}
	ppid, err := strconv.Atoi(f[1])
	return ppid, f[19], err == nil
}

// Await polls applied until it reports true, and fails after timeout. Errors
// are retried (the master may be restarting) and reported on timeout.
func Await(applied func() (bool, error), timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		ok, err := applied()
		if err == nil && ok {
			return nil
		}
		if time.Now().After(deadline) {
			if err != nil {
				return fmt.Errorf("nginx did not confirm the new config within %s: %v", timeout, err)
			}
			return fmt.Errorf("nginx did not load the new config within %s (old workers still serving; see its [emerg] log)", timeout)
		}
		time.Sleep(Poll)
	}
}
