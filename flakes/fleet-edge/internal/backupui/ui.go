// Package backupui is the dashboard's backup policy editor (/backup/,
// containers/BACKUP-PLAN.md §2.3). It runs inside `fleet-edge overrides`
// next to the backup store, so every write goes through the same put/clear
// and revision rules as /api/backup.
//
// Identity: h005's nginx gates /backup/ with oauth2-proxy auth_request and
// overwrites X-Auth-Request-User/-Email/-Groups from the subrequest (never
// the client's). Those headers are trusted only when the TCP peer is
// loopback (nginx); anything else is refused. Writes then need Group in the
// groups header or the user/email in Users.
//
// CSRF: token = HMAC-SHA256(secret, user), secret random per process; every
// form carries it and every POST must match it, plus a same-host
// Origin/Referer.
package backupui

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"errors"
	"html/template"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/backup"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/server"
)

//go:embed templates/*.html
var tfs embed.FS

var tmpl = template.Must(template.ParseFS(tfs, "templates/*.html"))

// Store is the subset of *backup.Service the editor uses.
type Store interface {
	Snapshot() backup.Export
	PutAs(user, subject string, req backup.PolicyRequest) (*backup.Row, error)
	ClearAs(user, subject string, req backup.ClearRequest) (*backup.Row, error)
	AuditUI(user, peer, action string, code int, msg string)
}

// Config selects who may write.
type Config struct {
	// Group (an oauth2-proxy group, i.e. a Zitadel role) that may write.
	Group string
	// Users (oauth2-proxy user or email) that may write regardless of group.
	Users        []string
	B2PricePerTB float64
	// Secret keys the CSRF HMAC; nil draws a random one.
	Secret []byte
	Now    func() time.Time
}

// UI is the /backup/ handler.
type UI struct {
	st  Store
	cfg Config
}

// New builds the editor.
func New(st Store, cfg Config) *UI {
	if len(cfg.Secret) == 0 {
		cfg.Secret = make([]byte, 32)
		if _, err := rand.Read(cfg.Secret); err != nil {
			panic(err)
		}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &UI{st: st, cfg: cfg}
}

type identity struct {
	User   string
	Groups []string
}

// identify reads the oauth2-proxy identity nginx set; ok is false when the
// peer is not loopback (headers could be the client's) or no user is set.
func identify(r *http.Request) (identity, bool) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return identity{}, false
	}
	id := identity{User: strings.TrimSpace(r.Header.Get("X-Auth-Request-User"))}
	if e := strings.TrimSpace(r.Header.Get("X-Auth-Request-Email")); e != "" {
		id.User = e
	}
	for _, g := range strings.Split(r.Header.Get("X-Auth-Request-Groups"), ",") {
		if g = strings.TrimSpace(g); g != "" {
			id.Groups = append(id.Groups, g)
		}
	}
	return id, id.User != ""
}

func (u *UI) mayWrite(id identity) bool {
	for _, x := range u.cfg.Users {
		if x != "" && x == id.User {
			return true
		}
	}
	if u.cfg.Group == "" {
		return false
	}
	for _, g := range id.Groups {
		// oauth2-proxy may prefix groups ("role:admin"); accept both.
		if g == u.cfg.Group || strings.HasSuffix(g, ":"+u.cfg.Group) {
			return true
		}
	}
	return false
}

func (u *UI) token(user string) string {
	m := hmac.New(sha256.New, u.cfg.Secret)
	m.Write([]byte("fleet-edge backup-ui\x00" + user))
	return hex.EncodeToString(m.Sum(nil))
}

func (u *UI) tokenOK(user, got string) bool {
	return got != "" && subtle.ConstantTimeCompare([]byte(u.token(user)), []byte(got)) == 1
}

// sameOrigin requires Origin (or, without it, Referer) to name r.Host.
func sameOrigin(r *http.Request) bool {
	raw := r.Header.Get("Origin")
	if raw == "" || raw == "null" {
		raw = r.Header.Get("Referer")
	}
	if raw == "" {
		return false
	}
	o, err := url.Parse(raw)
	return err == nil && o.Host != "" && strings.EqualFold(o.Host, r.Host)
}

type rowView struct {
	server.BackupRow
	OffsiteReason string
}

type pageData struct {
	User, Token  string
	CanWrite     bool
	Flash, Error string
	Rows         []rowView
	Targets      []backup.TargetView
	TargetIDs    []string
	Presets      []string
	B2Presets    []string
	Scopes       []string
	Code         int
	GeneratedAt  string
}

func (u *UI) render(w http.ResponseWriter, id identity, code int, flash, msg string) {
	e := u.st.Snapshot()
	tb := server.BuildBackupTable(e, u.cfg.B2PricePerTB, u.cfg.Now())
	pusher := map[string]bool{}
	d := pageData{User: id.User, Token: u.token(id.User), CanWrite: u.mayWrite(id), Flash: flash, Error: msg,
		Targets: e.Targets, TargetIDs: []string{backup.None}, Presets: []string{"short", "standard", "long"},
		B2Presets: []string{"local", "short", "standard", "long"}, Scopes: backup.Scopes, Code: code,
		GeneratedAt: u.cfg.Now().UTC().Format(time.RFC3339)}
	for _, t := range e.Targets {
		d.TargetIDs = append(d.TargetIDs, t.ID)
		pusher[t.ID] = t.Pusher
	}
	for _, r := range tb.Rows {
		v := rowView{BackupRow: r}
		switch {
		case r.Target == backup.None:
			v.OffsiteReason = "no target"
		case !pusher[r.Target]:
			v.OffsiteReason = r.Target + " is not a pusher"
		}
		d.Rows = append(d.Rows, v)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.WriteHeader(code)
	_ = tmpl.ExecuteTemplate(w, "backup.html", d)
}

// ServeHTTP: GET /backup/ renders; POST /backup/<subject>/{policy,off,clear}.
func (u *UI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	id, ok := identify(r)
	if !ok {
		http.Error(w, "forbidden: no trusted identity", http.StatusForbidden)
		return
	}
	if r.URL.Path == "/backup/" || r.URL.Path == "/backup" {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		// Results arrive via redirect, signed so a crafted link cannot
		// put text in the page; the page then carries the write's status.
		q := r.URL.Query()
		code, flash, msg := http.StatusOK, q.Get("ok"), q.Get("err")
		if flash != "" || msg != "" {
			if !hmac.Equal([]byte(q.Get("sig")), []byte(u.flashSig(id.User, q.Get("code"), flash, msg))) {
				flash, msg = "", ""
			} else if c, err := strconv.Atoi(q.Get("code")); err == nil && c >= 400 && c < 600 {
				code = c
			}
		}
		u.render(w, id, code, flash, msg)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/backup/"), "/"), "/")
	act := "UI " + r.URL.Path
	peer, _, _ := net.SplitHostPort(r.RemoteAddr)
	deny := func(code int, msg string) {
		u.st.AuditUI(id.User, peer, act, code, msg)
		http.Error(w, msg, code)
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := r.ParseForm(); err != nil {
		deny(http.StatusBadRequest, "bad form")
		return
	}
	switch {
	case !sameOrigin(r):
		deny(http.StatusForbidden, "forbidden: cross-origin request")
		return
	case !u.tokenOK(id.User, r.PostForm.Get("csrf")):
		deny(http.StatusForbidden, "forbidden: bad CSRF token")
		return
	case !u.mayWrite(id):
		deny(http.StatusForbidden, "forbidden: "+id.User+" may not change backup policy")
		return
	case len(parts) != 2:
		deny(http.StatusNotFound, "not found")
		return
	}
	subject, op := parts[0], parts[1]
	var err error
	var flash string
	switch op {
	case "policy", "off":
		err = u.policy(id.User, subject, op, r.PostForm)
		flash = subject + ": policy saved"
		if op == "off" {
			flash = subject + ": turned off (target none; nothing deleted)"
		}
	case "clear":
		scope := r.PostForm.Get("scope")
		if typed := strings.TrimSpace(r.PostForm.Get("confirm")); typed != subject {
			err = badRequest("clear: type the subject name " + subject + " to confirm")
			break
		}
		_, err = u.st.ClearAs(id.User, subject, backup.ClearRequest{Scope: scope, Confirm: "clear svc-" + subject + " " + scope})
		flash = subject + ": clear " + scope + " queued"
	default:
		deny(http.StatusNotFound, "not found")
		return
	}
	code := http.StatusOK
	if err != nil {
		code, flash = errCode(err), ""
		u.st.AuditUI(id.User, peer, act, code, err.Error())
	} else {
		u.st.AuditUI(id.User, peer, act, code, "")
	}
	u.redirect(w, r, id.User, code, flash, errText(err))
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func errCode(err error) int {
	var br badRequest
	if errors.As(err, &br) {
		return http.StatusBadRequest
	}
	return backup.ErrCode(err)
}

func (u *UI) flashSig(user, code, flash, msg string) string {
	m := hmac.New(sha256.New, u.cfg.Secret)
	m.Write([]byte("flash\x00" + user + "\x00" + code + "\x00" + flash + "\x00" + msg))
	return hex.EncodeToString(m.Sum(nil))
}

// redirect is the post/redirect/get step; the result page carries code
// (e.g. 409 for a stale revision) as its HTTP status.
func (u *UI) redirect(w http.ResponseWriter, r *http.Request, user string, code int, flash, msg string) {
	c := strconv.Itoa(code)
	q := url.Values{"code": {c}, "sig": {u.flashSig(user, c, flash, msg)}}
	if flash != "" {
		q.Set("ok", flash)
	}
	if msg != "" {
		q.Set("err", msg)
	}
	http.Redirect(w, r, "/backup/?"+q.Encode(), http.StatusSeeOther)
}

// policy sends only the fields that differ from the row as rendered, so
// changing a preset does not re-validate an unchanged (stale) target.
func (u *UI) policy(user, subject, op string, f url.Values) error {
	rev, err := parseRev(f.Get("revision"))
	if err != nil {
		return err
	}
	req := backup.PolicyRequest{Revision: rev}
	if op == "off" {
		none := backup.None
		req.Target = &none
		_, err = u.st.PutAs(user, subject, req)
		return err
	}
	set := func(name string, dst **string) {
		if v := f.Get(name); v != "" && v != f.Get("was-"+name) {
			*dst = &v
		}
	}
	set("target", &req.Target)
	set("retentionLocal", &req.RetentionLocal)
	set("retentionB2", &req.RetentionB2)
	off := f.Get("offsite") == "on"
	if was := f.Get("was-offsite") == "on"; off != was {
		req.Offsite = &off
	}
	_, err = u.st.PutAs(user, subject, req)
	return err
}
