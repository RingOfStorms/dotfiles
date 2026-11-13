package backup

import (
	"bufio"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// markLow records risk before credentials can be released. It never creates
// credentials, resets history on clear, or treats missing evidence as high trust.
func (s *Service) markLow(subject string) error {
	if s.creds.WrittenBy[subject] == WrittenByLow {
		return nil
	}
	s.creds.WrittenBy[subject] = WrittenByLow
	if err := s.saveCreds(); err != nil {
		delete(s.creds.WrittenBy, subject)
		return err
	}
	for _, t := range s.targets {
		if st, ok := t.Stats[subject]; ok {
			st.WrittenBy = WrittenByLow
			t.Stats[subject] = st
		}
	}
	return nil
}

// Placement and the last credential binding are authority-owned, unlike a
// snapshot's hostname. A pending low-trust destination can fetch the same repo
// key, so an aborted move cannot make that repository trustworthy again.
func (s *Service) recordPlacement(subject string) error {
	if s.creds.WrittenBy[subject] == WrittenByLow {
		return nil
	}
	host, pending := s.cfg.Placement(subject)
	bound := ""
	if c := s.creds.Creds[subject]; c != nil {
		bound = c.BoundHost
	}
	for _, h := range []string{host, pending, bound} {
		if h != "" && s.cfg.HostTrust(h) == WrittenByLow {
			return s.markLow(subject)
		}
	}
	return nil
}

func (s *Service) applyProvenance(t *Target) {
	for subject, st := range t.Stats {
		st.WrittenBy = s.creds.WrittenBy[subject]
		t.Stats[subject] = st
	}
}

func (s *Service) refreshProvenance() {
	for subject, low := range s.cfg.LowTrustSubjects() {
		if low && subjectRe.MatchString(subject) {
			if err := s.markLow(subject); err != nil {
				log.Printf("backup: save provenance for %s: %v", subject, err)
			}
		}
	}
	for _, subject := range s.cfg.Subjects() {
		if err := s.recordPlacement(subject); err != nil {
			log.Printf("backup: save provenance for %s: %v", subject, err)
		}
	}
	for subject := range s.creds.Creds {
		if err := s.recordPlacement(subject); err != nil {
			log.Printf("backup: save provenance for %s: %v", subject, err)
		}
	}
	for _, t := range s.targets {
		s.applyProvenance(t)
	}
}

// loadProvenance migrates existing metadata at startup. Only successful,
// authenticated credential fetches or the authority's own placement rotations
// are evidence; denied requests and user-supplied audit text are not. No secret
// values are needed, and no audit lines are changed.
func (s *Service) loadProvenance() error {
	for subject, value := range s.creds.WrittenBy {
		if value != WrittenByLow || !subjectRe.MatchString(subject) {
			delete(s.creds.WrittenBy, subject)
		}
	}
	for _, t := range s.targets {
		for subject, st := range t.Stats {
			if subjectRe.MatchString(subject) && st.WrittenBy == WrittenByLow {
				if err := s.markLow(subject); err != nil {
					return err
				}
			}
		}
	}
	f, err := os.Open(filepath.Join(s.cfg.StateDir, "backup-audit.log"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 4096), 1<<20)
		for sc.Scan() {
			var e auditEntry
			if json.Unmarshal(sc.Bytes(), &e) != nil || e.Code != 200 {
				continue
			}
			subject := ""
			if e.Sub != "" && (e.Role == roleReader || e.Role == roleWriter) && s.cfg.HostTrust(e.Host) == WrittenByLow {
				path, ok := strings.CutPrefix(e.Action, "GET /api/backup")
				path = strings.Trim(path, "/")
				if ok && strings.HasSuffix(path, "/credentials") {
					subject = strings.TrimSuffix(path, "/credentials")
				}
			} else if e.Host == "fleet-edge" && e.Sub == "" && strings.HasPrefix(e.Message, "placement ") {
				fields := strings.Fields(e.Message)
				if len(fields) >= 4 && fields[2] == "->" && (s.cfg.HostTrust(fields[1]) == WrittenByLow || s.cfg.HostTrust(strings.TrimSuffix(fields[3], ";")) == WrittenByLow) {
					subject, _ = strings.CutPrefix(e.Action, "rotate ")
				}
			}
			if subjectRe.MatchString(subject) {
				if err := s.markLow(subject); err != nil {
					return err
				}
			}
		}
		if err := sc.Err(); err != nil {
			return err
		}
	}
	for subject, low := range s.cfg.LowTrustSubjects() {
		if low && subjectRe.MatchString(subject) {
			if err := s.markLow(subject); err != nil {
				return err
			}
		}
	}
	for _, subject := range s.cfg.Subjects() {
		if err := s.recordPlacement(subject); err != nil {
			return err
		}
	}
	for subject := range s.creds.Creds {
		if err := s.recordPlacement(subject); err != nil {
			return err
		}
	}
	for _, t := range s.targets {
		s.applyProvenance(t)
	}
	return nil
}
