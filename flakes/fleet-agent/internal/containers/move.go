package containers

// `cnt move` (ROUTING-PLAN §8 step 9, §9.1). The data travels through the
// shared restic repository, so the moved service continues its svc:<name>
// series and a move doubles as a restore test:
//
//	1 preflight   target has the host module, fleet-backup (fleet-restic) and
//	              the service's capabilities; source has fleet-backup and the
//	              data; leftovers of an interrupted move on the target are
//	              cleared (only if marked as ours)
//	2 final backup  backupHook while running, blocking stop on the source,
//	              fleet-backup-svc@<svc> (one service, no prune), snapshot id
//	              read from the fresh stamp
//	3 restore     that snapshot onto the target (SQLite .backup copies put
//	              in place of the excluded live files), then the excluded
//	              live PG clusters copied from the stopped source with the
//	              manifest-verified tar
//	4 deploy      on the target, then health-check every route
//	5 restore check  scratch restore of the same snapshot on the target:
//	              SQLite PRAGMA integrity_check, PG dumps non-empty and valid
//	6 first backup  on the target (fresh stamp from the target)
//	7 switch      uninstall on the source, rename its data <svc>.moved-<date>
//	              (fleet-backup skips it)
//
// Any failure in 2-6 undoes the target: stop confirmed (killed if needed),
// uninstall, data moved aside as <svc>.failed-move-<time>, marker removed
// last; then the source starts again if it was running. If that rollback
// fails the source is NOT started (no two live copies): both stay stopped,
// the error says what to do by hand.
// Re-running after a failure or an interrupted run is safe.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Paths on the hosts (vars for tests).
var (
	backupMarker   = "/etc/fleet-containers/backup"          // host-module.nix, backup.enable
	backupStampDir = "/var/lib/fleet-containers/backup-last" // fleet-backup success stamps
	backupStaging  = "/var/lib/fleet-backup/staging"         // fleet-backup SQLite copies
	moveMarkerDir  = "/var/lib/fleet-containers"             // move-<svc>: target has an unfinished move
)

func moveMarker(svc string) string { return moveMarkerDir + "/move-" + svc }

// moveSourceMarker (on the source) records that the service was running
// when a move stopped it, so a re-run after an interruption still knows to
// start it again on failure. Removed by the restart or the switch.
func moveSourceMarker(svc string) string { return moveMarkerDir + "/move-" + svc + ".was-running" }

// liveDBGlobs are paths fleet-backup excludes as live database clusters
// (host-module.nix backup.exclude); move copies them from the stopped source.
var liveDBGlobs = []string{"postgres", "postgresql/[0-9]*"}

// backupStamp is one line written by fleet-backup on success:
// time=<RFC3339> snapshot=<id> host=<hostname>
type backupStamp struct {
	Time     time.Time
	Snapshot string
	Host     string
}

func parseStamp(s string) (backupStamp, error) {
	var b backupStamp
	for _, kv := range strings.Fields(s) {
		k, v, _ := strings.Cut(kv, "=")
		switch k {
		case "time":
			t, err := time.Parse(time.RFC3339, v)
			if err != nil {
				return b, fmt.Errorf("stamp time %q: %w", v, err)
			}
			b.Time = t
		case "snapshot":
			b.Snapshot = v
		case "host":
			b.Host = v
		}
	}
	if b.Time.IsZero() || b.Snapshot == "" {
		return b, fmt.Errorf("incomplete backup stamp %q", strings.TrimSpace(s))
	}
	for _, c := range b.Snapshot {
		if !strings.ContainsRune("0123456789abcdef", c) {
			return b, fmt.Errorf("bad snapshot id %q", b.Snapshot)
		}
	}
	return b, nil
}

func backupCheckScript(host string) string {
	return fmt.Sprintf("if [ ! -e %s ] || ! command -v fleet-restic >/dev/null; then echo \"%s has no fleet-backup (set ringofstorms.containers.backup.enable and its restic credentials)\" >&2; exit 1; fi\n",
		q(backupMarker), host)
}

// movePreflightTarget: target can take the service. Leftovers from an
// unfinished move (marker present) are uninstalled and moved aside;
// anything else in the way is refused.
func movePreflightTarget(s Service, to string) string {
	dst := dataDir(s)
	return strict + fmt.Sprintf(`test -d /etc/systemd-mutable/system || { echo "%[3]s lacks the containers host module" >&2; exit 1; }
`, unitOf(s), s.Name, to) + backupCheckScript(to) + requiresScript(s, to) + fmt.Sprintf(`if [ -e %[6]s ]; then
  echo "%[3]s: leftovers of an unfinished move of %[2]s; removing them" >&2
  %[7]s
fi
if systemctl is-active -q %[1]s; then echo "%[2]s already running on %[3]s" >&2; exit 1; fi
if [ -e %[4]s ] && [ -n "$(ls -A %[4]s)" ]; then echo "%[4]s already exists on %[3]s; move it away first" >&2; exit 1; fi
install -d -m755 %[5]s
`, unitOf(s), s.Name, to, q(dst), q(inv.DataRoot), q(moveMarker(s.Name)),
		strings.ReplaceAll(strings.TrimSpace(retireTargetBody(s)), "\n", "\n  "))
}

func movePreflightSource(s Service, from string) string {
	return "set -e\n" + backupCheckScript(from) + fmt.Sprintf("test -d %s || { echo \"%s: no %s; nothing to move\" >&2; exit 1; }\n",
		q(dataDir(s)), from, dataDir(s))
}

// finalBackupScript stops the service (after its hook) and runs a
// one-service fleet-backup. First prints "WAS <state>" (before the stop).
func finalBackupScript(s Service) string {
	return "set -e\n" + fmt.Sprintf(`if [ -e %[2]s ]; then echo "WAS active"
else
  st=$(systemctl is-active %[1]s || true); echo "WAS $st"
  case "$st" in active|activating|reloading) touch %[2]s ;; esac
fi
`, unitOf(s), q(moveSourceMarker(s.Name))) +
		hookScript(s) + disableScript(s) + stopConfirmScript(s) +
		backupRunScript(s)
}

// backupRunScript runs fleet-backup for one service and prints its stamp.
// The old stamp is removed first, so a skipped run (unit condition false)
// cannot pass for a fresh one.
func backupRunScript(s Service) string {
	st := q(backupStampDir + "/" + s.Name)
	return fmt.Sprintf("rm -f %[1]s\nsystemctl start fleet-backup-svc@%[2]s.service\ntest -s %[1]s || { echo 'fleet-backup wrote no stamp for %[2]s' >&2; exit 1; }\necho \"STAMP $(cat %[1]s)\"\n",
		st, s.Name)
}

// wasActive reads the "WAS <state>" line of finalBackupScript. Without it
// nothing was stopped, so nothing is started again.
func wasActive(out string) bool {
	for _, l := range strings.Split(out, "\n") {
		if st, ok := strings.CutPrefix(l, "WAS "); ok {
			return st != "inactive" && st != "failed" && st != "unknown"
		}
	}
	return false
}

// stampFrom finds the STAMP line in script output and checks it is fresh
// (taken after since, allowing for clock skew) and from host.
func stampFrom(out, host string, since time.Time) (backupStamp, error) {
	for _, l := range strings.Split(out, "\n") {
		if rest, ok := strings.CutPrefix(l, "STAMP "); ok {
			b, err := parseStamp(rest)
			if err != nil {
				return b, err
			}
			if b.Time.Before(since.Add(-5 * time.Minute)) {
				return b, fmt.Errorf("backup stamp is from %s, before this move started", b.Time.Format(time.RFC3339))
			}
			if host != "" && b.Host != "" && b.Host != host {
				return b, fmt.Errorf("backup stamp is from host %s, expected %s", b.Host, host)
			}
			return b, nil
		}
	}
	return backupStamp{}, errors.New("no backup stamp in output")
}

// restoreScript restores snapshot onto host into a temp dir next to the
// data, puts the SQLite copies in place of the excluded live files (files
// only, so the restored dirs keep their owners/modes), and renames the
// result into place. Marks the target so a re-run knows it is ours.
func restoreScript(s Service, from, snap string) string {
	root := inv.DataRoot
	return strict + fmt.Sprintf(`root=%[1]s
svc=%[2]s
tmp=$(mktemp -d "$root/.cnt-move-$svc.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
echo "from=%[3]s snapshot=%[4]s" > %[5]s
fleet-restic restore %[4]s --target "$tmp"
test -d "$tmp$root/$svc" || { echo "snapshot %[4]s has no $root/$svc" >&2; exit 1; }
sq="$tmp"%[6]s/$svc/sqlite/$svc
if [ -d "$sq" ]; then
  (cd "$sq" && find . -type f -print0) | while IFS= read -r -d "" f; do
    install -d "$(dirname "$tmp$root/$svc/$f")"
    cp -a "$sq/$f" "$tmp$root/$svc/$f"
  done
fi
mv -T "$tmp$root/$svc" "$root/$svc"
echo "restored $root/$svc from snapshot %[4]s"
`, q(root), q(s.Name), from, snap, q(moveMarker(s.Name)), q(backupStaging))
}

// liveDBListScript lists the live DB cluster dirs of the service (relative
// to the data root) that fleet-backup does not snapshot.
func liveDBListScript(s Service) string {
	var g []string
	for _, p := range liveDBGlobs {
		g = append(g, q(s.Name)+"/"+p)
	}
	return fmt.Sprintf("cd %s && for p in %s; do [ -d \"$p\" ] && echo \"$p\"; done; true\n", q(inv.DataRoot), strings.Join(g, " "))
}

// moveStopWait bounds how long (seconds) a stop may take before the unit
// is killed, and again after the kill. var for tests.
var moveStopWait = 60

// stopConfirmScript stops the unit and fails unless it is confirmed down:
// systemctl reports it neither active, activating, deactivating nor
// reloading, and (nixos kind) machinectl knows no machine of that name.
// A failing stop fails the script unless the service is proven never
// installed (cnt_absent: LoadState not-found, no unit file, no machine /
// podman container); then CNT_ABSENT=1 and the uninstall is skipped. A unit
// still up after moveStopWait is killed (SIGKILL) and checked again.
// Needs set -e.
func stopConfirmScript(s Service) string {
	machine, present := "", ""
	if s.Kind == "podman" {
		// exit 1 = no such container; anything else (0, or podman broken) is not proof
		present = fmt.Sprintf("  if podman container exists %[1]s >/dev/null 2>&1; then return 1; else [ $? -eq 1 ] || return 1; fi\n", q(s.Name))
	} else {
		machine = fmt.Sprintf("  if machinectl show %s >/dev/null 2>&1; then return 1; fi\n", q(s.Name))
		present = machine
	}
	return fmt.Sprintf(`cnt_down() {
  case "$(systemctl is-active %[1]s 2>/dev/null || true)" in
    ""|active|activating|deactivating|reloading|refreshing) return 1 ;;
  esac
%[3]s  return 0
}
cnt_wait_down() {
  for _ in $(seq 1 %[2]d); do cnt_down && return 0; sleep 1; done
  cnt_down
}
cnt_absent() {
  [ "$(systemctl show -p LoadState --value %[1]s 2>/dev/null || true)" = not-found ] || return 1
  [ ! -e %[5]s ] && [ ! -L %[5]s ] || return 1
%[4]s  return 0
}
CNT_ABSENT=0
if ! systemctl stop %[1]s; then
  if cnt_absent; then
    CNT_ABSENT=1
    echo "%[1]s is not installed here; nothing to stop or uninstall" >&2
  else
    echo "stopping %[1]s failed; refusing to go on" >&2; exit 1
  fi
fi
if ! cnt_wait_down; then
  echo "%[1]s still up after %[2]ds; killing it" >&2
  systemctl kill --signal=SIGKILL %[1]s || true
  cnt_wait_down || { echo "%[1]s is still running after SIGKILL; refusing to go on" >&2; exit 1; }
fi
`, unitOf(s), moveStopWait, machine, present, q(mutableUnits+"/"+unitOf(s)))
}

// uninstallUnlessAbsent: uninstall (failures fail) unless stopConfirmScript
// proved the service was never installed.
func uninstallUnlessAbsent(s Service) string {
	return "if [ \"$CNT_ABSENT\" != 1 ]; then\n" + uninstallScript(s) + "fi\n"
}

// retireTargetBody (needs set -e) takes the service down on the target,
// confirmed, uninstalls it (failures fail), moves the data aside, and only
// then removes the move marker, so any failure leaves the marker for a
// re-run.
func retireTargetBody(s Service) string {
	return disableScript(s) + stopConfirmScript(s) + uninstallUnlessAbsent(s) + cleanupScript(s) +
		"cnt_down || { echo \"" + unitOf(s) + " came back up during uninstall\" >&2; exit 1; }\n" +
		fmt.Sprintf("if [ -e %[1]s ]; then d=%[1]s.failed-move-$(date +%%Y%%m%%dT%%H%%M%%S); [ ! -e \"$d\" ] || d=$d-$$; mv -T %[1]s \"$d\"; fi\nrm -f %[2]s\n",
			q(dataDir(s)), q(moveMarker(s.Name)))
}

// rollbackTargetScript undoes a partial move on the target.
func rollbackTargetScript(s Service) string { return strict + retireTargetBody(s) }

// switchScript retires the source copy once it is confirmed stopped:
// <svc>.moved-<date> (with the time added if that exists already, e.g. a
// second move the same day). The was-running marker goes last.
func switchScript(s Service) string {
	return strict + disableScript(s) + stopConfirmScript(s) + uninstallUnlessAbsent(s) + cleanupScript(s) +
		"cnt_down || { echo \"" + unitOf(s) + " came back up during uninstall\" >&2; exit 1; }\n" + fmt.Sprintf(`d=%[1]s.moved-$(date +%%F)
[ ! -e "$d" ] || d=%[1]s.moved-$(date +%%F-%%H%%M%%S)
mv -T %[1]s "$d"
echo "source data kept as $d"
`, q(dataDir(s))) + "rm -f " + q(moveSourceMarker(s.Name)) + "\n"
}

// restartSourceAfterUndo: the source may only start again if the target
// is confirmed down (rolled back, or never touched) and it was running.
func restartSourceAfterUndo(targetDown, wasRunning bool) bool { return targetDown && wasRunning }

// rollbackFailedMsg: both hosts left stopped; what to do by hand.
func rollbackFailedMsg(s Service, from, to string, err error) string {
	return fmt.Sprintf(`
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
ROLLBACK ON %[2]s FAILED (%[4]v).
%[1]s may still be running on %[2]s. It was NOT started again on %[3]s, to
avoid two live copies of the same data. Both are left as they are.
By hand:
  1. on %[2]s: systemctl stop/kill %[5]s until it is down; containers destroy %[1]s --host %[2]s
  2. on %[2]s: move %[6]s aside (e.g. .failed-move-<time>), then rm %[7]s
  3. re-run: containers move %[1]s --to %[2]s --from %[3]s  (or containers start %[1]s --host %[3]s)
%[3]s keeps %[8]s, so a re-run still knows to start it again.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`,
		s.Name, to, from, err, unitOf(s), dataDir(s), moveMarker(s.Name), moveSourceMarker(s.Name))
}

func cmdMove(args []string) error {
	f := parse(args)
	s := f.svc()
	to := f.vals["to"]
	if to == "" {
		return errors.New("usage: containers move <svc> --to <host> [--from <host>]")
	}
	from := f.vals["from"]
	if from == "" && !dryRun {
		var err error
		if from, err = moveSource(s, locate(s, probe)); err != nil {
			return err
		}
	}
	if from == "" {
		from = s.Host
	}
	if !slices.Contains(containerHosts(), to) {
		return fmt.Errorf("%s is not a container host; add it to containerHosts in containers/flake.nix (and import the host module there) so discovery can see it", to)
	}
	if from == to {
		return fmt.Errorf("%s is already on %s", s.Name, to)
	}
	if err := validateRoutes(s); err != nil {
		return err
	}
	if dryRun {
		fmt.Printf("plan: move %s %s -> %s through the restic repo (svc:%s)\n", s.Name, from, to, s.Name)
	}
	started := time.Now()

	info("1/7 preflight: %s (fleet-backup, capabilities, free) and %s", to, from)
	if err := remote(to, true, movePreflightTarget(s, to)); err != nil {
		return fmt.Errorf("preflight on %s: %w (nothing changed on %s)", to, err, from)
	}
	if err := remote(from, true, movePreflightSource(s, from)); err != nil {
		return fmt.Errorf("preflight on %s: %w (nothing changed)", from, err)
	}

	info("2/7 final backup on %s: hook, stop, fleet-backup-svc@%s", from, s.Name)
	wasRunning := !dryRun
	undo := func(step string, err error, target bool) error {
		msg := fmt.Sprintf("%s: %v", step, err)
		targetDown := true
		if target {
			info("rolling back %s", to)
			if e := remote(to, true, rollbackTargetScript(s)); e != nil {
				targetDown = false
				msg += rollbackFailedMsg(s, from, to, e)
			}
		}
		if !targetDown {
			return errors.New(msg)
		}
		if restartSourceAfterUndo(targetDown, wasRunning) {
			info("starting %s again on %s", s.Name, from)
			if e := remote(from, true, strict+enableScript(s)+"systemctl start "+unitOf(s)+"\nsystemctl is-active "+unitOf(s)+"\nrm -f "+q(moveSourceMarker(s.Name))+"\n"); e != nil {
				msg += fmt.Sprintf("\nrestart on %s FAILED (%v): containers start %s --host %s", from, e, s.Name, from)
			}
		} else {
			msg += fmt.Sprintf("\n%s was not running on %s before the move; left stopped", s.Name, from)
		}
		return errors.New(msg)
	}
	var snap backupStamp
	if dryRun {
		remote(from, true, finalBackupScript(s))
		snap.Snapshot = "<snapshot-from-step-2>"
	} else {
		out, err := remoteOut(context.Background(), from, true, finalBackupScript(s))
		wasRunning = wasActive(out)
		if err != nil {
			return undo("final backup on "+from, err, false)
		}
		if snap, err = stampFrom(out, from, started); err != nil {
			return undo("final backup on "+from, err, false)
		}
		info("snapshot %s (%s)", snap.Snapshot, snap.Time.Format(time.RFC3339))
	}

	info("3/7 restoring snapshot %s onto %s, then live DB clusters from the stopped %s", snap.Snapshot, to, from)
	if err := remote(to, true, restoreScript(s, from, snap.Snapshot)); err != nil {
		return undo("restore on "+to, err, true)
	}
	if err := copyLiveDBs(s, from, to); err != nil {
		return undo("copying live DB clusters", err, true)
	}

	info("4/7 deploying on %s and checking its routes", to)
	if err := deploy(s, to, flakeRef(s.Dir), false); err != nil {
		return undo("deploy on "+to, err, true)
	}
	if hs := healthScript(s, hostOverlayIP(to)); hs != "" {
		if err := remote(to, true, hs); err != nil {
			return undo("health check on "+to, err, true)
		}
	}

	info("5/7 restore check of snapshot %s on %s (scratch dir)", snap.Snapshot, to)
	if err := restoreCheck(s, to, snap.Snapshot); err != nil {
		return undo("restore check", err, true)
	}

	info("6/7 first backup on %s", to)
	if dryRun {
		remote(to, true, "set -e\n"+backupRunScript(s))
	} else {
		out, err := remoteOut(context.Background(), to, true, "set -e\n"+backupRunScript(s))
		if err == nil {
			var b backupStamp
			if b, err = stampFrom(out, to, started); err == nil {
				info("snapshot %s on %s", b.Snapshot, to)
			}
		}
		if err != nil {
			return undo("first backup on "+to, err, true)
		}
	}
	if err := remote(to, true, "rm -f "+q(moveMarker(s.Name))+"\n"); err != nil {
		return fmt.Errorf("clearing the move marker on %s: %w (the move is complete otherwise; remove %s by hand)", to, err, moveMarker(s.Name))
	}

	info("7/7 switch: removing %s from %s (data kept as %s.moved-<date>)", s.Name, from, dataDir(s))
	if err := remote(from, true, switchScript(s)); err != nil {
		return fmt.Errorf("cleanup on %s: %w (%s runs on %s; the source copy is stopped)", from, err, s.Name, to)
	}
	fmt.Print(moveWarning(s, to))
	return nil
}

// copyLiveDBs streams the live DB cluster dirs (excluded from restic) from
// the stopped source and verifies them by manifest.
func copyLiveDBs(s Service, from, to string) error {
	if dryRun {
		remote(from, true, liveDBListScript(s))
		fmt.Printf("[%s -> %s] tar each listed dir (numeric owners), verify manifests\n", from, to)
		return nil
	}
	out, err := remoteOut(context.Background(), from, true, liveDBListScript(s))
	if err != nil {
		return err
	}
	for _, rel := range strings.Fields(out) {
		if !strings.HasPrefix(rel, s.Name+"/") || strings.Contains(rel, "..") {
			return fmt.Errorf("unexpected path %q", rel)
		}
		info("copying %s:%s/%s (live DB cluster, verified)", from, inv.DataRoot, rel)
		src := hostCmd(context.Background(), from, false, true, packScript(inv.DataRoot, rel))
		sink := hostCmd(context.Background(), to, false, true, strict+"rm -rf "+q(inv.DataRoot+"/"+rel)+"\n"+strings.TrimPrefix(unpackScript("zstd -d -q -c", inv.DataRoot), strict))
		sum := manifestScript(inv.DataRoot, rel)
		if err := copyVerified(src, sink,
			func() (string, error) { return remoteOut(context.Background(), from, true, sum) },
			func() (string, error) { return remoteOut(context.Background(), to, true, sum) }); err != nil {
			return fmt.Errorf("%s: %w", rel, err)
		}
	}
	return nil
}

// healthScript checks every route on the host after deploy: the backend
// answers (route health path: 2xx/3xx; otherwise any HTTP status below
// 500), and http routes with an fqdn also through the host's nginx on its
// overlay IP (any status below 500: the vhost and backend are wired). tcp
// routes: the port accepts. Retries for up to 90s each.
func healthScript(s Service, overlay string) string {
	var checks []string
	for _, n := range sortedRouteNames(s) {
		r := s.Routes[n]
		addr := backendAddr(s)
		path, lo, hi := "/", 100, 500
		if r.Health != nil && *r.Health != "" {
			path, lo, hi = *r.Health, 200, 400
		}
		switch r.Proto {
		case "http", "":
			checks = append(checks, fmt.Sprintf("chk_http %s %d %d %s", q("route "+n+" backend"), lo, hi,
				q(fmt.Sprintf("http://%s:%d%s", addr, r.Port, path))))
			if f := str(r.FQDN); f != "" && overlay != "" && r.Exposure != "local" {
				// through nginx: wired up (not 000/5xx); the ACL may refuse this
				// host's own address (lan routes), which still proves the route
				checks = append(checks, fmt.Sprintf("chk_http %s %d %d %s --resolve %s", q("route "+n+" nginx"), 100, 500,
					q("https://"+f+path), q(f+":443:"+overlay)))
			}
		case "tcp":
			checks = append(checks, fmt.Sprintf("chk_tcp %s %s %d", q("route "+n+" tcp"), q(addr), r.Port))
		}
	}
	if len(checks) == 0 {
		return ""
	}
	return `fail=0
chk_http() {
  label=$1 lo=$2 hi=$3; shift 3
  for i in $(seq 1 30); do
    c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true); c=${c:-000}
    if [ "$c" -ge "$lo" ] && [ "$c" -lt "$hi" ]; then echo "ok    $label $1 ($c)"; return 0; fi
    sleep 3
  done
  echo "FAIL  $label $1 (last status $c)" >&2; fail=1
}
chk_tcp() {
  for i in $(seq 1 30); do
    if timeout 3 bash -c "</dev/tcp/$2/$3" 2>/dev/null; then echo "ok    $1 $2:$3"; return 0; fi
    sleep 3
  done
  echo "FAIL  $1 $2:$3" >&2; fail=1
}
` + strings.Join(checks, "\n") + "\n[ \"$fail\" = 0 ]\n"
}

// needsPGDump: the service's hook writes a pg_dump(all), so a restore must
// contain at least one valid dump.
func needsPGDump(s Service) bool { return strings.Contains(s.BackupHook, "pg_dump") }

// restoreCheckScript restores the snapshot's databases and dumps into a
// scratch dir on the host and prints one line per file:
//
//	sqlite <path> <integrity_check result>
//	pgdump <path> ok|<reason>
//
// The scratch dir is always removed.
func restoreCheckScript(s Service, snap string) string {
	return strict + fmt.Sprintf(`scratch=$(mktemp -d /var/tmp/cnt-restore-check-%[1]s.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
fleet-restic restore %[2]s --target "$scratch" \
  --include '*.db' --include '*.sqlite' --include '*.sqlite3' \
  --include '*.sql' --include '*.sql.gz' --include '*.dump' >&2
for t in sqlite3 gzip; do command -v $t >/dev/null || { echo "restore check needs $t on this host" >&2; exit 1; }; done
cd "$scratch"
find . -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0 |
while IFS= read -r -d "" f; do
  [ "$(head -c 15 "$f")" = "SQLite format 3" ] || continue
  r=$(sqlite3 -readonly "$f" 'PRAGMA integrity_check;' 2>&1 | tr '\n' ' ' | sed 's/ *$//') || true
  echo "sqlite ${f#.} ${r:-no output}"
done
find . -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump' \) -print0 |
while IFS= read -r -d "" f; do
  p=${f#.}
  if [ ! -s "$f" ]; then echo "pgdump $p empty"; continue; fi
  case "$f" in
    *.gz)
      if ! gzip -t "$f" 2>/dev/null; then echo "pgdump $p bad-gzip"; continue; fi
      head=$(gzip -dc "$f" | head -c 4096 | tr -d '\0' || true); tail=$(gzip -dc "$f" | tail -c 4096 | tr -d '\0' || true) ;;
    *.dump)
      if [ "$(head -c 5 "$f")" = PGDMP ]; then echo "pgdump $p ok"; else echo "pgdump $p bad-format"; fi
      continue ;;
    *) head=$(head -c 4096 "$f" | tr -d '\0' || true); tail=$(tail -c 4096 "$f" | tr -d '\0' || true) ;;
  esac
  case "$head" in *"PostgreSQL database"*) ;; *) echo "pgdump $p not-a-pg-dump"; continue ;; esac
  case "$tail" in *"dump complete"*) echo "pgdump $p ok" ;; *) echo "pgdump $p truncated" ;; esac
done
echo "checked snapshot %[2]s"
`, s.Name, snap)
}

// evalRestoreCheck turns restoreCheckScript output into a verdict.
func evalRestoreCheck(out string, needPG bool) (string, error) {
	var bad []string
	nSQL, nPG := 0, 0
	for _, l := range strings.Split(out, "\n") {
		kind, rest, _ := strings.Cut(l, " ")
		path, res, _ := strings.Cut(rest, " ")
		switch kind {
		case "sqlite":
			nSQL++
			if res != "ok" {
				bad = append(bad, "sqlite "+path+": "+res)
			}
		case "pgdump":
			nPG++
			if res != "ok" {
				bad = append(bad, "pg dump "+path+": "+res)
			}
		}
	}
	if needPG && nPG == 0 {
		bad = append(bad, "no PostgreSQL dump in the snapshot (the backupHook writes one)")
	}
	sum := fmt.Sprintf("%d SQLite db(s), %d PG dump(s)", nSQL, nPG)
	if len(bad) > 0 {
		return sum, fmt.Errorf("restore check failed (%s):\n  %s", sum, strings.Join(bad, "\n  "))
	}
	return sum, nil
}

func restoreCheck(s Service, h, snap string) error {
	if dryRun {
		return remote(h, true, restoreCheckScript(s, snap))
	}
	out, err := remoteOut(context.Background(), h, true, restoreCheckScript(s, snap))
	if err != nil {
		return err
	}
	sum, err := evalRestoreCheck(out, needsPGDump(s))
	if err == nil {
		info("restore check ok: %s", sum)
	}
	return err
}

// cmdRestoreCheck: `containers restore-check <svc> [--host h] [--snapshot id]`
// (default: latest svc:<svc> snapshot). Read-only apart from a scratch dir.
func cmdRestoreCheck(args []string) error {
	f := parse(args)
	s := f.svc()
	h := hostForRead(s, f)
	snap := f.vals["snapshot"]
	if snap == "" {
		snap = "latest --tag svc:" + s.Name
	} else if _, err := parseStamp("time=2000-01-01T00:00:00Z snapshot=" + snap); err != nil {
		return fmt.Errorf("--snapshot: %w", err)
	}
	info("restore check of %s (%s) on %s", s.Name, snap, h)
	return restoreCheck(s, h, snap)
}

// cmdHealth: `containers health <svc> [--host h]`, the route check move runs
// after deploy.
func cmdHealth(args []string) error {
	f := parse(args)
	s := f.svc()
	h := hostForRead(s, f)
	hs := healthScript(s, hostOverlayIP(h))
	if hs == "" {
		info("%s has no routes to check", s.Name)
		return nil
	}
	return remote(h, false, hs)
}
