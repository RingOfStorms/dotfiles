package containers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Backup client resolver (containers/BACKUP-PLAN.md §2.4, P3):
//
//	fleet containers backup-resolve <subject> [--cache FILE]
//
// asks h005's /api/backup/<subject> (machine token) where the subject's repo
// is and prints
//
//	target=<id|none>
//	repo=<rest:http://…/svc-<subject>/>   (absent for none)
//	source=api|cache
//
// The answer is cached (0600, atomic) per subject. API unreachable, or the
// target unknown/disabled/stale: the cached answer is used. No cache: the
// run fails; it never guesses a target. The client never sees offsite.

const defaultResolveCache = "/var/lib/fleet-backup/target.json"

var subjectNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// bpResolved is fleet-edge's backup.Resolved.
type bpResolved struct {
	Subject        string `json:"subject"`
	Target         string `json:"target"`
	URL            string `json:"url,omitempty"`
	Repo           string `json:"repo,omitempty"`
	RetentionLocal string `json:"retentionLocal,omitempty"`
	Revision       int64  `json:"revision"`
	Unavailable    string `json:"unavailable,omitempty"`
}

// validResolved: target none, or a rest repo for exactly this subject.
func validResolved(subject string, r bpResolved) error {
	if r.Target == "none" {
		return nil
	}
	if r.Target == "" {
		return errors.New("no target")
	}
	if !(strings.HasPrefix(r.Repo, "rest:http://") || strings.HasPrefix(r.Repo, "rest:https://")) {
		return fmt.Errorf("repo %q is not rest:http(s)://…", r.Repo)
	}
	if !strings.HasSuffix(r.Repo, "/svc-"+subject+"/") {
		return fmt.Errorf("repo %q is not …/svc-%s/", r.Repo, subject)
	}
	if strings.Contains(strings.TrimPrefix(strings.TrimPrefix(r.Repo, "rest:http://"), "rest:https://"), "@") {
		return fmt.Errorf("repo %q carries userinfo (it would be stored in every snapshot)", r.Repo)
	}
	return nil
}

func readResolveCache(path string) map[string]bpResolved {
	m := map[string]bpResolved{}
	b, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return m
}

func writeResolveCache(path string, m map[string]bpResolved) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(m, "", "  ")
	tmp, err := os.CreateTemp(filepath.Dir(path), ".target.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// fetchResolved asks the API. Readers get a Resolved; writers (laptops) get
// {row, resolved}.
func fetchResolved(c edgeDoer, subject string) (bpResolved, error) {
	var raw json.RawMessage
	if err := c.do("GET", "/api/backup/"+subject, nil, &raw); err != nil {
		return bpResolved{}, err
	}
	var wrap struct {
		Resolved *bpResolved `json:"resolved"`
	}
	if json.Unmarshal(raw, &wrap) == nil && wrap.Resolved != nil {
		return *wrap.Resolved, nil
	}
	var r bpResolved
	if err := json.Unmarshal(raw, &r); err != nil {
		return r, err
	}
	return r, nil
}

// resolveBackup returns the subject's target and where the answer came from.
func resolveBackup(getClient func() (edgeDoer, error), subject, cache string, log io.Writer) (bpResolved, string, error) {
	if !subjectNameRe.MatchString(subject) {
		return bpResolved{}, "", fmt.Errorf("bad subject name %q", subject)
	}
	m := readResolveCache(cache)
	fallback := func(why string) (bpResolved, string, error) {
		r, ok := m[subject]
		if !ok {
			return bpResolved{}, "", fmt.Errorf("%s: %s, and no cached target in %s: refusing to guess", subject, why, cache)
		}
		if err := validResolved(subject, r); err != nil {
			return bpResolved{}, "", fmt.Errorf("%s: %s, and the cached target is unusable: %v", subject, why, err)
		}
		fmt.Fprintf(log, "%s: %s; using the cached target %s\n", subject, why, r.Target)
		return r, "cache", nil
	}
	c, err := getClient()
	if err != nil {
		return fallback("policy API unavailable (" + err.Error() + ")")
	}
	r, err := fetchResolved(c, subject)
	if err != nil {
		return fallback("policy API: " + err.Error())
	}
	if r.Unavailable != "" {
		return fallback("target " + r.Target + " " + r.Unavailable)
	}
	if err := validResolved(subject, r); err != nil {
		return fallback("policy answer rejected: " + err.Error())
	}
	r.Subject = subject
	m[subject] = r
	if err := writeResolveCache(cache, m); err != nil {
		fmt.Fprintf(log, "%s: could not write the cache %s: %v\n", subject, cache, err)
	}
	return r, "api", nil
}

func cmdBackupResolve(args []string) error {
	f := parse(args)
	if len(f.pos) != 1 {
		return errors.New("usage: fleet containers backup-resolve <subject> [--cache FILE]")
	}
	cache := f.vals["cache"]
	if cache == "" {
		cache = defaultResolveCache
	}
	r, src, err := resolveBackup(backupEdge, f.pos[0], cache, os.Stderr)
	if err != nil {
		return err
	}
	fmt.Printf("target=%s\n", r.Target)
	if r.Target != "none" {
		fmt.Printf("repo=%s\n", r.Repo)
	}
	fmt.Printf("source=%s\n", src)
	return nil
}

// BackupSpec is lib.nix normalizeBackup (service.nix `backup`).
type BackupSpec struct {
	Enable     *bool             `json:"enable"`
	Exclude    []string          `json:"exclude"`
	Hooks      BackupHooks       `json:"hooks"`
	ExtraPaths []BackupExtraPath `json:"extraPaths"`
}

type BackupHooks struct {
	Pre  string `json:"pre"`
	Post string `json:"post"`
}

// BackupExtraPath is one service.nix backup.extraPaths entry (§3.1).
type BackupExtraPath struct {
	Path     string   `json:"path"`
	Requires string   `json:"requires"`
	Exclude  []string `json:"exclude"`
	Mount    string   `json:"mount"`
	Sentinel string   `json:"sentinel"`
	OnMove   string   `json:"onMove"`
}

func (b BackupExtraPath) onMove() string {
	if b.OnMove == "" {
		return "restore"
	}
	return b.OnMove
}

// stampSubject is the subject a stamped repo URL names (…/svc-<subject>/).
func stampSubject(repo string) string {
	s := strings.TrimSuffix(repo, "/")
	i := strings.LastIndex(s, "/svc-")
	if i < 0 {
		return ""
	}
	return s[i+len("/svc-"):]
}

// resticCmd is fleet-restic for one subject: the stamped repo when known,
// else the subject's resolved repo (fleet-restic resolves it).
func resticCmd(subject, repo string) string {
	c := "fleet-restic --subject " + q(subject)
	if repo != "" {
		c += " -r " + q(repo)
	}
	return c
}

// backupPreflightScript (both move hosts, §2.9): the subject resolves to a
// target (not none) on this host, h005 hands this host the subject's
// credentials now (a fresh fetch, not the cache: placed here or the
// in-flight move's destination),
// and that credential can read and lock the subject's repo (`snapshots`
// takes a lock). Without it a move would stop the source and then fail.
func backupPreflightScript(s Service, host string) string {
	return fmt.Sprintf(`res=$(fleet containers backup-resolve %[1]s) || { echo "%[2]s: %[1]s resolves to no backup target" >&2; exit 1; }
case "$res" in *target=none*) echo "%[2]s: %[1]s has backups off (target=none); set a target first" >&2; exit 1 ;; esac
cr=$(fleet containers backup-creds %[1]s) && case "$cr" in *source=api*) ;; *) false ;; esac || { echo "%[2]s: h005 did not hand out the %[1]s backup credentials (not placed here or reserved as the move destination, or fleet-edge down)" >&2; exit 1; }
%[3]s snapshots --latest 1 --quiet </dev/null >/dev/null || { echo "%[2]s cannot read or lock the svc-%[1]s repo (wrong credentials, or the target has not applied the REST password yet)" >&2; exit 1; }
`, s.Name, host, resticCmd(s.Name, ""))
}

// extraPathsPreflightScript checks each extra path's onMove rule on the
// destination (§3.4): restore needs it missing or empty, present needs it
// local and non-empty.
func extraPathsPreflightScript(s Service, host string) string {
	var b strings.Builder
	for _, e := range s.Backup.ExtraPaths {
		p := q(e.Path)
		switch e.onMove() {
		case "present":
			fmt.Fprintf(&b, `if [ ! -d %[1]s ] || [ -z "$(ls -A %[1]s)" ]; then echo "%[2]s: %[3]s (onMove=present) is missing or empty; stage it with cnt restore %[4]s --extra %[3]s" >&2; exit 1; fi
case "$(findmnt -no FSTYPE -T %[1]s)" in nfs*|cifs|smb3|fuse.sshfs|autofs|9p) echo "%[2]s: %[3]s is a remote path" >&2; exit 1 ;; esac
`, p, host, e.Path, s.Name)
		default:
			fmt.Fprintf(&b, `if [ -e %[1]s ] && [ -n "$(ls -A %[1]s)" ]; then echo "%[2]s: %[3]s (onMove=restore) exists and is not empty; move it away first" >&2; exit 1; fi
`, p, host, e.Path)
		}
	}
	return b.String()
}

// restoreExtraScript restores the onMove=restore extra paths from the
// stamped snapshot at their absolute paths (move step 3).
func restoreExtraScript(s Service, st backupStamp) string {
	var paths []string
	for _, e := range s.Backup.ExtraPaths {
		if e.onMove() == "restore" {
			paths = append(paths, e.Path)
		}
	}
	if len(paths) == 0 {
		return ""
	}
	return extraRestoreScript(s, st.Repo, st.Snapshot, paths, "")
}

// extraRestoreScript restores paths from snap. into "" restores in place
// (refusing non-empty destinations); otherwise under the scratch dir into.
func extraRestoreScript(s Service, repo, snap string, paths []string, into string) string {
	var b strings.Builder
	b.WriteString(strict)
	incl := ""
	for _, p := range paths {
		if into == "" {
			fmt.Fprintf(&b, "if [ -e %[1]s ] && [ -n \"$(ls -A %[1]s)\" ]; then echo \"%[2]s exists and is not empty; use --into <scratch dir>\" >&2; exit 1; fi\n", q(p), p)
		}
		incl += " --include " + q(p)
	}
	tgt := "/"
	if into != "" {
		tgt = into
		fmt.Fprintf(&b, "install -d -m700 %s\n", q(into))
	}
	fmt.Fprintf(&b, "%s restore %s --target %s%s </dev/null\n", resticCmd(s.Name, repo), snap, q(tgt), incl)
	fmt.Fprintf(&b, "echo 'restored extra paths of %s from %s into %s'\n", s.Name, strings.ReplaceAll(snap, "'", ""), tgt)
	return b.String()
}

// cmdRestoreExtra: `cnt restore <svc> --extra all|<path> [--snapshot id]
// [--repo url] [--into dir] [--host h]`. Extra paths only; the
// /srv/containers part stays with the tarball restore and cnt move.
func cmdRestoreExtra(f flags) error {
	s := f.svc()
	h, _ := hostFor(s, f)
	want := f.vals["extra"]
	var paths []string
	for _, e := range s.Backup.ExtraPaths {
		if want == "all" || want == e.Path {
			paths = append(paths, e.Path)
		}
	}
	if len(paths) == 0 {
		return fmt.Errorf("%s: no extra path matches --extra %s", s.Name, want)
	}
	snap := f.vals["snapshot"]
	if snap == "" {
		snap = "latest --tag svc:" + s.Name
	} else if _, err := parseStamp("time=2000-01-01T00:00:00Z snapshot=" + snap); err != nil {
		return fmt.Errorf("--snapshot: %w", err)
	}
	repo := f.vals["repo"]
	if repo != "" {
		if err := validResolved(s.Name, bpResolved{Target: "x", Repo: repo}); err != nil {
			return fmt.Errorf("--repo: %w", err)
		}
	}
	into := f.vals["into"]
	if into != "" && !strings.HasPrefix(into, "/") {
		return errors.New("--into must be an absolute path")
	}
	info("restoring %s extra paths %s (%s) on %s", s.Name, strings.Join(paths, " "), snap, h)
	return remote(h, true, requiresScript(s, h)+extraRestoreScript(s, repo, snap, paths, into))
}
