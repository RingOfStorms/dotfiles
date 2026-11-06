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

// Per-subject backup credentials from h005 fleet-edge (BACKUP-PLAN.md §2.7):
//
//	fleet containers backup-creds <subject> [--dir DIR]
//
// fetches GET /api/backup/<subject>/credentials (machine token; allowed only
// while the live placement binds the subject to this host or this host is
// an in-flight move's destination), caches it as DIR/<subject>.env (root,
// 0600, atomic) and prints that path. API unreachable: the cached file is
// used. A 403 (not placed here any more) deletes the cache entry and fails.

const defaultCredsDir = "/var/lib/fleet-backup/creds"

type bpCred struct {
	Subject        string `json:"subject"`
	ResticPassword string `json:"RESTIC_PASSWORD"`
	RestUsername   string `json:"RESTIC_REST_USERNAME"`
	RestPassword   string `json:"RESTIC_REST_PASSWORD"`
	RestRevision   int64  `json:"restRevision"`
}

var credValueRe = regexp.MustCompile(`^[0-9a-f]{16,128}$`)

func (c bpCred) valid(subject string) error {
	if c.RestUsername != "svc-"+subject {
		return fmt.Errorf("RESTIC_REST_USERNAME %q is not svc-%s", c.RestUsername, subject)
	}
	if !credValueRe.MatchString(c.ResticPassword) || !credValueRe.MatchString(c.RestPassword) {
		return errors.New("malformed password")
	}
	return nil
}

func credEnv(c bpCred) string {
	return fmt.Sprintf("RESTIC_PASSWORD=%s\nRESTIC_REST_USERNAME=%s\nRESTIC_REST_PASSWORD=%s\nREST_REVISION=%d\n",
		c.ResticPassword, c.RestUsername, c.RestPassword, c.RestRevision)
}

// writeFile0600 writes path atomically, root-only.
func writeFile0600(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// backupCreds returns the path of subject's credential file and its source
// (api|cache).
func backupCreds(getClient func() (edgeDoer, error), subject, dir string, log io.Writer) (string, string, error) {
	if !subjectNameRe.MatchString(subject) {
		return "", "", fmt.Errorf("bad subject name %q", subject)
	}
	path := filepath.Join(dir, subject+".env")
	fallback := func(why string) (string, string, error) {
		if st, err := os.Stat(path); err != nil || st.Size() == 0 {
			return "", "", fmt.Errorf("%s: %s, and no cached credentials in %s", subject, why, path)
		}
		fmt.Fprintf(log, "%s: %s; using cached credentials\n", subject, why)
		return path, "cache", nil
	}
	c, err := getClient()
	if err != nil {
		return fallback("credentials API unavailable (" + err.Error() + ")")
	}
	var cr bpCred
	if err := c.do("GET", "/api/backup/"+subject+"/credentials", nil, &cr); err != nil {
		var he *edgeHTTPError
		if errors.As(err, &he) && (he.Code == 403 || he.Code == 404) {
			if rerr := os.Remove(path); rerr == nil {
				fmt.Fprintf(log, "%s: refused (%d); deleted the cached credentials\n", subject, he.Code)
			}
			return "", "", fmt.Errorf("%s: this host may not hold its backup credentials: %v", subject, err)
		}
		return fallback("credentials API: " + err.Error())
	}
	if err := cr.valid(subject); err != nil {
		return fallback("credentials answer rejected: " + err.Error())
	}
	if err := writeFile0600(path, []byte(credEnv(cr))); err != nil {
		return "", "", err
	}
	return path, "api", nil
}

func cmdBackupCreds(args []string) error {
	f := parse(args)
	if len(f.pos) != 1 {
		return errors.New("usage: fleet containers backup-creds <subject> [--dir DIR]")
	}
	dir := f.vals["dir"]
	if dir == "" {
		dir = defaultCredsDir
	}
	p, src, err := backupCreds(backupEdge, f.pos[0], dir, os.Stderr)
	if err != nil {
		return err
	}
	fmt.Printf("creds=%s\nsource=%s\n", p, src)
	return nil
}

// --- target side -----------------------------------------------------------

// writeTargetCreds splits the heartbeat reply: credentials (REST logins)
// go to credsOut (root 0600), the rest is returned for policy.json, which
// the restic-user units read.
func splitHeartbeatReply(reply json.RawMessage, credsOut string) (json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(reply, &m); err != nil {
		return nil, err
	}
	creds, ok := m["credentials"]
	delete(m, "credentials")
	if ok && credsOut != "" {
		var feed map[string]struct {
			Username     string `json:"username"`
			RestPassword string `json:"restPassword"`
			RestRevision int64  `json:"restRevision"`
		}
		if err := json.Unmarshal(creds, &feed); err != nil {
			return nil, fmt.Errorf("credentials: %w", err)
		}
		for n, c := range feed {
			if !subjectNameRe.MatchString(n) || c.Username != "svc-"+n || !credValueRe.MatchString(c.RestPassword) {
				return nil, fmt.Errorf("credentials: bad entry for %q", n)
			}
		}
		if err := writeFile0600(credsOut, append(creds, '\n')); err != nil {
			return nil, err
		}
	}
	return json.Marshal(m)
}

// backupRepoKeys fetches this target's repo passwords and writes one file
// per held subject, DIR/svc-<subject> (RESTIC_PASSWORD=<hex>, root 0600),
// removing files of subjects no longer held. Consumed via LoadCredential.
func backupRepoKeys(c edgeDoer, args []string) error {
	var id, dir string
	for len(args) > 0 {
		switch args[0] {
		case "--id":
			id, args = need(args), args[2:]
		case "--dir":
			dir, args = need(args), args[2:]
		default:
			return fmt.Errorf("repo-keys: unknown flag %s", args[0])
		}
	}
	if id == "" || dir == "" {
		return errors.New("repo-keys: --id and --dir are required")
	}
	var out struct {
		RepoKeys map[string]string `json:"repoKeys"`
	}
	if err := c.do("GET", "/api/backup/targets/"+id+"/repo-keys", nil, &out); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	keep := map[string]bool{}
	for n, pw := range out.RepoKeys {
		if !subjectNameRe.MatchString(n) || !credValueRe.MatchString(pw) {
			return fmt.Errorf("repo-keys: bad entry %q", n)
		}
		keep["svc-"+n] = true
		if err := writeFile0600(filepath.Join(dir, "svc-"+n), []byte("RESTIC_PASSWORD="+pw+"\n")); err != nil {
			return err
		}
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "svc-") && !keep[e.Name()] {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	names := sortedKeys(keep)
	fmt.Printf("repo keys: %s\n", strings.Join(names, " "))
	return nil
}

func backupRotate(c edgeDoer, args []string, out io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: backup-policy rotate <subject>")
	}
	var r struct {
		RestRevision int64 `json:"restRevision"`
	}
	if err := c.do("POST", "/api/backup/"+args[0]+"/rotate", nil, &r); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s: REST password rotated (revision %d); pending until each target's heartbeat reports it applied\n", args[0], r.RestRevision)
	return nil
}
