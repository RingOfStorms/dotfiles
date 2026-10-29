// Package authority is the caller identity check shared by h005's runtime
// authorities (internal/overrides, internal/placements).
//
// Both authorities accept writes only from hosts holding their own Zitadel
// machine identity (the sec-agent machine key): a verified token whose sub is
// in an explicit allowlist, sent from that host's overlay IP. Roles and trust
// levels are never consulted, and the peer is X-Fleet-Peer only when the TCP
// peer is loopback (h005 nginx sets it), so a host cannot claim another's IP.
// Nothing here reads or writes state; each authority keeps its own.
package authority

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
)

const (
	// RateWindow and RateMaxWrites bound writes per calling host.
	RateWindow    = 10 * time.Minute
	RateMaxWrites = 30
)

// Writer is one host allowed to call an API: its Zitadel machine user and the
// overlay IP its requests must come from.
type Writer struct {
	Sub  string `json:"sub"`
	Peer string `json:"peer"`
}

// TokenVerifier checks a Zitadel JWT's signature, issuer, project audience
// and expiry (auth.Authenticator).
type TokenVerifier interface {
	VerifyZitadelToken(raw string) (auth.VerifiedToken, error)
}

// Caller is who made a request; fields are filled as far as auth got, for the
// audit log.
type Caller struct {
	Host, Sub, Peer string
}

// Auth is an allowlist of writing hosts plus a per-host write rate limit.
type Auth struct {
	writers  map[string]Writer
	bySub    map[string]string // Writer sub -> host
	verifier TokenVerifier
	now      func() time.Time
	mu       sync.Mutex
	rate     map[string][]time.Time
}

// New validates the allowlist. now may be nil (time.Now).
func New(writers map[string]Writer, v TokenVerifier, now func() time.Time) (*Auth, error) {
	if v == nil {
		return nil, errors.New("a token verifier is required")
	}
	if now == nil {
		now = time.Now
	}
	a := &Auth{writers: writers, bySub: map[string]string{}, verifier: v, now: now, rate: map[string][]time.Time{}}
	for host, w := range writers {
		if w.Sub == "" || net.ParseIP(w.Peer) == nil {
			return nil, fmt.Errorf("writer %s needs a sub and a peer IP", host)
		}
		if other, dup := a.bySub[w.Sub]; dup {
			return nil, fmt.Errorf("writers %s and %s share sub %s", other, host, w.Sub)
		}
		a.bySub[w.Sub] = host
	}
	return a, nil
}

// Writers returns the allowlist (never nil-safe to mutate: it is the caller's
// map).
func (a *Auth) Writers() map[string]Writer { return a.writers }

// Authenticate accepts a request only if its bearer token is a valid Zitadel
// token (signature, issuer, project audience, expiry), its sub is a
// configured writer, and it came from that writer's overlay IP.
func (a *Auth) Authenticate(r *http.Request) (Caller, error) {
	var c Caller
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return c, errors.New("no peer")
	}
	if ip := net.ParseIP(peer); ip != nil && ip.IsLoopback() {
		if p := strings.TrimSpace(r.Header.Get("X-Fleet-Peer")); p != "" {
			peer = p
		}
	}
	c.Peer = peer
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || strings.TrimSpace(tok) == "" {
		return c, errors.New("missing bearer token")
	}
	id, err := a.verifier.VerifyZitadelToken(tok)
	if err != nil {
		return c, fmt.Errorf("token: %w", err)
	}
	c.Sub = id.Subject
	host, ok := a.bySub[id.Subject]
	if !ok {
		return c, errors.New("sub is not an override writer")
	}
	c.Host = host
	want := net.ParseIP(a.writers[host].Peer)
	if got := net.ParseIP(peer); got == nil || !got.Equal(want) {
		return c, fmt.Errorf("token of %s used from %s", host, peer)
	}
	return c, nil
}

// AllowWrite counts one write for host inside RateWindow, reporting the wait
// until a slot frees when the host is over the limit.
func (a *Auth) AllowWrite(host string) (bool, time.Duration) {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	var keep []time.Time
	for _, t := range a.rate[host] {
		if now.Sub(t) < RateWindow {
			keep = append(keep, t)
		}
	}
	if len(keep) >= RateMaxWrites {
		a.rate[host] = keep
		return false, RateWindow - now.Sub(keep[0])
	}
	a.rate[host] = append(keep, now)
	return true, 0
}
