package backup

// Per-subject backup credentials (containers/README.md, Credentials, policy and retention). fleet-edge
// generates and holds them; nothing else stores them except the operator's
// export.
//
//   - RESTIC_PASSWORD: the repo password (local and B2). Generated once and
//     never rotated: the repo master key would not change anyway.
//   - RESTIC_REST_USERNAME=svc-<name>, RESTIC_REST_PASSWORD: rest-server HTTP
//     auth. Rotated on a committed move and on demand; RestRevision counts.
//
// Who gets what:
//   - a client host: all three, for a subject the live placement binds to it
//     (or the destination of an in-flight move); GET /api/backup/<s>/credentials.
//   - every target: {username, restPassword, restRevision} for all subjects
//     in its heartbeat reply (htpasswd); never the repo password.
//   - a target: RESTIC_PASSWORD only, for the repos it holds;
//     GET /api/backup/targets/<id>/repo-keys.

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Cred is one subject's credential set.
type Cred struct {
	ResticPassword string `json:"resticPassword"`
	RestUsername   string `json:"restUsername"`
	RestPassword   string `json:"restPassword"`
	RestRevision   int64  `json:"restRevision"`
	CreatedAt      int64  `json:"createdAt"`
	RotatedAt      int64  `json:"rotatedAt,omitempty"`
	// BoundHost is the committed placement host last seen; a change rotates
	// the REST password (the move committed).
	BoundHost string `json:"boundHost,omitempty"`
}

type credsFile struct {
	LastExportedAt int64            `json:"lastExportedAt,omitempty"`
	LastExportHash string           `json:"lastExportHash,omitempty"`
	Creds          map[string]*Cred `json:"creds"`
	// WrittenBy is monotonic subject history, independent of current placement
	// and whether any target currently reports the repo. Only "low" is stored.
	WrittenBy map[string]string `json:"writtenBy,omitempty"`
}

// RestCred is the target feed entry: never the repo password.
type RestCred struct {
	Username     string `json:"username"`
	RestPassword string `json:"restPassword"`
	RestRevision int64  `json:"restRevision"`
}

// ClientCred is what a placed host receives.
type ClientCred struct {
	Subject        string `json:"subject"`
	ResticPassword string `json:"RESTIC_PASSWORD"`
	RestUsername   string `json:"RESTIC_REST_USERNAME"`
	RestPassword   string `json:"RESTIC_REST_PASSWORD"`
	RestRevision   int64  `json:"restRevision"`
}

func randHex() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

var hexRe = regexp.MustCompile(`^[0-9a-f]{16,128}$`)

func (s *Service) credsPath() string { return filepath.Join(s.cfg.StateDir, "backup-credentials.json") }

func (s *Service) saveCreds() error { return writeAtomic(s.credsPath(), s.creds) }

// ensureCred returns subject's credentials, generating them on first need.
func (s *Service) ensureCred(subject string) (*Cred, error) {
	if err := s.recordPlacement(subject); err != nil {
		return nil, err
	}
	if c := s.creds.Creds[subject]; c != nil {
		return c, nil
	}
	host, _ := s.cfg.Placement(subject)
	c := &Cred{ResticPassword: randHex(), RestUsername: "svc-" + subject, RestPassword: randHex(),
		RestRevision: 1, CreatedAt: s.cfg.Now().Unix(), BoundHost: host}
	s.creds.Creds[subject] = c
	if err := s.saveCreds(); err != nil {
		delete(s.creds.Creds, subject)
		return nil, err
	}
	return c, nil
}

// rotate bumps subject's REST password; a non-empty bindHost is set as
// BoundHost in the same step. On a save failure the whole Cred is restored.
func (s *Service) rotate(subject, why, bindHost string) (*Cred, error) {
	c := s.creds.Creds[subject]
	if c == nil {
		return nil, fail(404, "%s has no credentials yet", subject)
	}
	old := *c
	if bindHost != "" {
		c.BoundHost = bindHost
	}
	c.RestPassword, c.RestRevision, c.RotatedAt = randHex(), c.RestRevision+1, s.cfg.Now().Unix()
	if err := s.saveCreds(); err != nil {
		*c = old
		return nil, err
	}
	s.logAudit(auditEntry{Host: "fleet-edge", Action: "rotate " + subject, Code: 200, Message: fmt.Sprintf("%s; restRevision %d", why, c.RestRevision)})
	return c, nil
}

// syncBindings rotates the REST password of every subject whose committed
// placement host changed since it was last seen (a move committed): the old
// host loses fetch access via placement and, once targets apply the new
// revision, HTTP access too.
func (s *Service) syncBindings() {
	s.refreshProvenance()
	for _, n := range sortedKeys(s.creds.Creds) {
		c := s.creds.Creds[n]
		if err := s.recordPlacement(n); err != nil {
			log.Printf("backup: save provenance for %s: %v", n, err)
			continue
		}
		host, _ := s.cfg.Placement(n)
		if host == "" || host == c.BoundHost {
			continue
		}
		prev := c.BoundHost
		if prev == "" {
			c.BoundHost = host
			if err := s.saveCreds(); err != nil {
				c.BoundHost = prev
				log.Printf("backup: save credentials: %v", err)
			}
			continue
		}
		if _, err := s.rotate(n, "placement "+prev+" -> "+host, host); err != nil {
			log.Printf("backup: rotate %s: %v", n, err)
		}
	}
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// mayFetch: the live placement binds subject to host, or host is the
// destination of an in-flight move.
func (s *Service) mayFetch(host, subject string) bool {
	h, pending := s.cfg.Placement(subject)
	return host != "" && (host == h || host == pending)
}

func (s *Service) clientCred(subject string) (ClientCred, error) {
	c, err := s.ensureCred(subject)
	if err != nil {
		return ClientCred{}, err
	}
	return ClientCred{Subject: subject, ResticPassword: c.ResticPassword, RestUsername: c.RestUsername,
		RestPassword: c.RestPassword, RestRevision: c.RestRevision}, nil
}

// restFeed is every subject's HTTP login, for targets' htpasswd.
func (s *Service) restFeed() map[string]RestCred {
	out := map[string]RestCred{}
	for n, c := range s.creds.Creds {
		out[n] = RestCred{Username: c.RestUsername, RestPassword: c.RestPassword, RestRevision: c.RestRevision}
	}
	return out
}

// holds: the policy target (own row or the default row) is id, or id's
// stats list the repo (containers/README.md, Nightly restic: a target's root reads every repo it holds).
func (s *Service) holds(id, subject string) bool {
	if s.effective(subject).Target == id {
		return true
	}
	if t := s.targets[id]; t != nil {
		_, ok := t.Stats[subject]
		return ok
	}
	return false
}

// repoKeys is RESTIC_PASSWORD per subject target id holds.
func (s *Service) repoKeys(id string) (map[string]string, error) {
	names := map[string]bool{}
	for _, n := range s.cfg.Subjects() {
		names[n] = true
	}
	if t := s.targets[id]; t != nil {
		for n := range t.Stats {
			names[n] = true
		}
	}
	out := map[string]string{}
	for _, n := range sortedKeys(names) {
		if !s.holds(id, n) {
			continue
		}
		c, err := s.ensureCred(n)
		if err != nil {
			return nil, err
		}
		out[n] = c.ResticPassword
	}
	return out, nil
}

// --- export / import -------------------------------------------------------

func exportLine(n string, c *Cred) string {
	return fmt.Sprintf("svc-%s RESTIC_PASSWORD=%s RESTIC_REST_PASSWORD=%s", n, c.ResticPassword, c.RestPassword)
}

func (s *Service) exportBody() (string, string) {
	var b strings.Builder
	for _, n := range sortedKeys(s.creds.Creds) {
		b.WriteString(exportLine(n, s.creds.Creds[n]) + "\n")
	}
	sum := sha256.Sum256([]byte(b.String()))
	return b.String(), hex.EncodeToString(sum[:])
}

// ExportAs renders the export text and records lastExportedAt and its hash.
func (s *Service) ExportAs(user string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, n := range s.cfg.Subjects() {
		if subjectRe.MatchString(n) {
			if _, err := s.ensureCred(n); err != nil {
				return "", err
			}
		}
	}
	body, sum := s.exportBody()
	now := s.cfg.Now()
	prevAt, prevHash := s.creds.LastExportedAt, s.creds.LastExportHash
	s.creds.LastExportedAt, s.creds.LastExportHash = now.Unix(), sum
	if err := s.saveCreds(); err != nil {
		s.creds.LastExportedAt, s.creds.LastExportHash = prevAt, prevHash
		return "", err
	}
	s.logAudit(auditEntry{Host: uiHost, Role: "ui", User: user, Action: "export credentials", Code: 200, Message: "sha256 " + sum})
	return "# fleet-edge backup credentials export " + now.UTC().Format(time.RFC3339) + "\n" + body, nil
}

// ImportLine is one parsed import entry and what applying it would do.
type ImportLine struct {
	Subject string
	// Action: new, same, differs, unknown.
	Action string
	// Fields that differ (RESTIC_PASSWORD, RESTIC_REST_PASSWORD).
	Differs        []string
	resticPassword string
	restPassword   string
}

func parseImport(text string) ([]ImportLine, error) {
	var out []ImportLine
	seen := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(text))
	for ln := 1; sc.Scan(); ln++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 3 || !strings.HasPrefix(f[0], "svc-") {
			return nil, fail(400, "line %d: want `svc-<name> RESTIC_PASSWORD=<hex> RESTIC_REST_PASSWORD=<hex>`", ln)
		}
		il := ImportLine{Subject: strings.TrimPrefix(f[0], "svc-")}
		for _, kv := range f[1:] {
			k, v, _ := strings.Cut(kv, "=")
			if !hexRe.MatchString(v) {
				return nil, fail(400, "line %d: %s is not a hex secret", ln, k)
			}
			switch k {
			case "RESTIC_PASSWORD":
				il.resticPassword = v
			case "RESTIC_REST_PASSWORD":
				il.restPassword = v
			default:
				return nil, fail(400, "line %d: unknown field %q", ln, k)
			}
		}
		if il.resticPassword == "" || il.restPassword == "" || !subjectRe.MatchString(il.Subject) {
			return nil, fail(400, "line %d: incomplete entry", ln)
		}
		if seen[il.Subject] {
			return nil, fail(400, "line %d: svc-%s listed twice", ln, il.Subject)
		}
		seen[il.Subject] = true
		out = append(out, il)
	}
	return out, nil
}

func (s *Service) classify(lines []ImportLine) {
	for i := range lines {
		l := &lines[i]
		c := s.creds.Creds[l.Subject]
		switch {
		case !s.knownSubject(l.Subject) && c == nil:
			l.Action = "unknown"
		case c == nil:
			l.Action = "new"
		default:
			if c.ResticPassword != l.resticPassword {
				l.Differs = append(l.Differs, "RESTIC_PASSWORD")
			}
			if c.RestPassword != l.restPassword {
				l.Differs = append(l.Differs, "RESTIC_REST_PASSWORD")
			}
			l.Action = "same"
			if len(l.Differs) > 0 {
				l.Action = "differs"
			}
		}
	}
}

// ImportPreview parses text and reports what applying it would change.
func (s *Service) ImportPreview(text string) ([]ImportLine, error) {
	lines, err := parseImport(text)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.classify(lines)
	return lines, nil
}

// ImportAs restores missing subjects from text. A differing subject is
// overwritten only if listed in overwrite; a changed REST password bumps its
// revision so targets re-render.
func (s *Service) ImportAs(user, text string, overwrite map[string]bool) ([]ImportLine, error) {
	lines, err := parseImport(text)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.classify(lines)
	now := s.cfg.Now().Unix()
	var applied []string
	for _, l := range lines {
		switch {
		case l.Action == "new":
			if err := s.recordPlacement(l.Subject); err != nil {
				return nil, err
			}
			host, _ := s.cfg.Placement(l.Subject)
			s.creds.Creds[l.Subject] = &Cred{ResticPassword: l.resticPassword, RestUsername: "svc-" + l.Subject,
				RestPassword: l.restPassword, RestRevision: 1, CreatedAt: now, BoundHost: host}
			applied = append(applied, l.Subject+" (new)")
		case l.Action == "differs" && overwrite[l.Subject]:
			c := s.creds.Creds[l.Subject]
			if c.ResticPassword != l.resticPassword {
				c.ResticPassword, c.CreatedAt = l.resticPassword, now
			}
			if c.RestPassword != l.restPassword {
				c.RestPassword, c.RestRevision, c.RotatedAt = l.restPassword, c.RestRevision+1, now
			}
			applied = append(applied, l.Subject+" (overwritten)")
		}
	}
	if len(applied) > 0 {
		if err := s.saveCreds(); err != nil {
			return nil, err
		}
	}
	s.logAudit(auditEntry{Host: uiHost, Role: "ui", User: user, Action: "import credentials", Code: 200, Message: "applied: " + strings.Join(applied, ", ")})
	s.classify(lines)
	return lines, nil
}

// RevealAs returns one subject's credentials for the dashboard.
func (s *Service) RevealAs(user, subject string) (ClientCred, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !subjectRe.MatchString(subject) || !s.knownSubject(subject) || subject == Default {
		return ClientCred{}, fail(404, "unknown subject %q", subject)
	}
	cc, err := s.clientCred(subject)
	if err != nil {
		return cc, err
	}
	s.logAudit(auditEntry{Host: uiHost, Role: "ui", User: user, Action: "reveal " + subject, Code: 200})
	return cc, nil
}

// RotateAs rotates subject's REST password from the dashboard.
func (s *Service) RotateAs(user, subject string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !subjectRe.MatchString(subject) || !s.knownSubject(subject) || subject == Default {
		return 0, fail(404, "unknown subject %q", subject)
	}
	if _, err := s.ensureCred(subject); err != nil {
		return 0, err
	}
	c, err := s.rotate(subject, "manual (ui "+user+")", "")
	if err != nil {
		return 0, err
	}
	return c.RestRevision, nil
}

// CredState is one subject's credential status for the dashboard.
type CredState struct {
	Subject      string
	RestRevision int64
	CreatedAt    int64
	RotatedAt    int64
	// PendingOn lists targets that have not applied RestRevision yet.
	PendingOn []string
}

// CredStatus is the dashboard's credential overview.
type CredStatus struct {
	Subjects       []CredState
	LastExportedAt int64
	// ExportStale: never exported, or a repo password newer than the export.
	ExportStale bool
	// Missing: known subjects without credentials yet (made on first need).
	Missing []string
}

// CredentialStatus summarises credentials, pending rotations and export age.
func (s *Service) CredentialStatus() CredStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.syncBindings()
	st := CredStatus{LastExportedAt: s.creds.LastExportedAt}
	st.ExportStale = s.creds.LastExportedAt == 0
	for _, n := range sortedKeys(s.creds.Creds) {
		c := s.creds.Creds[n]
		cs := CredState{Subject: n, RestRevision: c.RestRevision, CreatedAt: c.CreatedAt, RotatedAt: c.RotatedAt}
		for _, t := range s.sortedTargets() {
			if t.Applied[n] < c.RestRevision {
				cs.PendingOn = append(cs.PendingOn, t.ID)
			}
		}
		if c.CreatedAt > s.creds.LastExportedAt {
			st.ExportStale = true
		}
		st.Subjects = append(st.Subjects, cs)
	}
	for _, n := range s.cfg.Subjects() {
		if s.creds.Creds[n] == nil {
			st.Missing = append(st.Missing, n)
		}
	}
	sort.Strings(st.Missing)
	return st
}
