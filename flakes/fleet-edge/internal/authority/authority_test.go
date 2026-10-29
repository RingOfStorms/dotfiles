package authority

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
)

// stubVerifier maps a bearer token's suffix to a subject; anything else fails.
type stubVerifier struct{}

func (stubVerifier) VerifyZitadelToken(raw string) (auth.VerifiedToken, error) {
	sub, ok := strings.CutPrefix(raw, "good-")
	if !ok {
		return auth.VerifiedToken{}, errors.New("bad token")
	}
	return auth.VerifiedToken{Subject: sub}, nil
}

const (
	orenSub  = "364267099884879875"
	orenPeer = "100.64.0.2"
	lioSub   = "344412093056811011"
	lioPeer  = "100.64.0.1"
)

func newAuth(t *testing.T) (*Auth, *time.Time) {
	t.Helper()
	now := time.Unix(1_000_000, 0)
	a, err := New(map[string]Writer{
		"oren": {Sub: orenSub, Peer: orenPeer},
		"lio":  {Sub: lioSub, Peer: lioPeer},
	}, stubVerifier{}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	return a, &now
}

func req(remote, peer, tok string) *http.Request {
	r := httptest.NewRequest("POST", "/api/anything", nil)
	r.RemoteAddr = remote
	if peer != "" {
		r.Header.Set("X-Fleet-Peer", peer)
	}
	if tok != "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	return r
}

func TestNewRejections(t *testing.T) {
	for name, tc := range map[string]struct {
		writers map[string]Writer
		ver     TokenVerifier
		want    string
	}{
		"shared sub": {writers: map[string]Writer{"a": {Sub: "1", Peer: "100.64.0.1"}, "b": {Sub: "1", Peer: "100.64.0.2"}}, ver: stubVerifier{}, want: "share sub 1"},
		"no peer":    {writers: map[string]Writer{"a": {Sub: "1"}}, ver: stubVerifier{}, want: "needs a sub and a peer IP"},
		"bad peer":   {writers: map[string]Writer{"a": {Sub: "1", Peer: "not-an-ip"}}, ver: stubVerifier{}, want: "needs a sub and a peer IP"},
		"no sub":     {writers: map[string]Writer{"a": {Peer: "100.64.0.1"}}, ver: stubVerifier{}, want: "needs a sub and a peer IP"},
		"no verifier": {
			writers: map[string]Writer{"a": {Sub: "1", Peer: "100.64.0.1"}},
			want:    "a token verifier is required",
		},
	} {
		t.Run(name, func(t *testing.T) {
			a, err := New(tc.writers, tc.ver, nil)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, %v; want %q", a, err, tc.want)
			}
		})
	}
	// A nil clock is allowed and the empty allowlist is valid.
	if _, err := New(nil, stubVerifier{}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestAuthenticate(t *testing.T) {
	a, _ := newAuth(t)
	for _, tc := range []struct {
		name, remote, peer, tok string
		want                    Caller
		err                     string
	}{
		{name: "through nginx", remote: "127.0.0.1:5555", peer: orenPeer, tok: "good-" + orenSub,
			want: Caller{Host: "oren", Sub: orenSub, Peer: orenPeer}},
		{name: "direct from overlay", remote: orenPeer + ":41234", tok: "good-" + orenSub,
			want: Caller{Host: "oren", Sub: orenSub, Peer: orenPeer}},
		{name: "header ignored off loopback", remote: "100.64.0.9:1", peer: orenPeer, tok: "good-" + orenSub,
			want: Caller{Host: "oren", Sub: orenSub, Peer: "100.64.0.9"}, err: "token of oren used from 100.64.0.9"},
		{name: "wrong source ip", remote: "127.0.0.1:5555", peer: lioPeer, tok: "good-" + orenSub,
			want: Caller{Host: "oren", Sub: orenSub, Peer: lioPeer}, err: "token of oren used from 100.64.0.1"},
		{name: "bad token", remote: "127.0.0.1:5555", peer: orenPeer, tok: "nope",
			want: Caller{Peer: orenPeer}, err: "token: bad token"},
		{name: "missing token", remote: "127.0.0.1:5555", peer: orenPeer,
			want: Caller{Peer: orenPeer}, err: "missing bearer token"},
		{name: "no peer", remote: "unix", tok: "good-" + orenSub, err: "no peer"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := a.Authenticate(req(tc.remote, tc.peer, tc.tok))
			if tc.err == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Fatalf("got %v, want %q", err, tc.err)
			}
			if c != tc.want {
				t.Errorf("caller %+v, want %+v", c, tc.want)
			}
		})
	}
}

func TestAllowWrite(t *testing.T) {
	a, now := newAuth(t)
	for i := range RateMaxWrites {
		if ok, wait := a.AllowWrite("oren"); !ok || wait != 0 {
			t.Fatalf("write %d refused: %v %v", i, ok, wait)
		}
	}
	ok, wait := a.AllowWrite("oren")
	if ok {
		t.Fatal("over the limit accepted")
	}
	if wait <= 0 || wait > RateWindow {
		t.Fatalf("wait %v", wait)
	}
	if ok, _ := a.AllowWrite("lio"); !ok {
		t.Fatal("another host refused")
	}
	// The window slides: the oldest entry ages out and a slot frees.
	*now = now.Add(RateWindow + time.Second)
	if ok, _ := a.AllowWrite("oren"); !ok {
		t.Fatal("slot not freed after the window")
	}
}

func TestWriters(t *testing.T) {
	a, _ := newAuth(t)
	w := a.Writers()
	if len(w) != 2 || w["oren"].Peer != orenPeer {
		t.Fatalf("writers %+v", w)
	}
}
