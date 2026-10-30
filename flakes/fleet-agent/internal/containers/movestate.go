package containers

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// The placement registry side of `cnt move` (PLACEMENT-PLAN §2). A move owns
// the placement for as long as it runs: it reserves the destination before it
// touches either host, renews the lease around the steps that can take a while
// (the final backup among them), commits once the destination serves, and
// retires the source before it is uninstalled. The token the reserve returns is
// the handle for every later write, so a client that wakes up late cannot
// finish or undo a move another device has since taken over.
//
// The token is never taken from a read of the registry: a prepared row on the
// destination may be another client's move in flight. A move resumes only with
// a token its caller holds — the one the last run saved in the local move-state
// file (moveStatePath), or one passed with --resume-token — and otherwise asks
// for a fresh reservation, unforced unless --force. A row someone else holds
// (fenced or not) then answers 409 and the move stops before any remote call.
//
// Only a machine with no registry client at all (no machine key: every dev box,
// every test) moves a service unrecorded. A key that cannot be used, or a
// registry that does not answer, refuses the move before anything changes,
// unless --force accepts moving without a record.

// errMoveCanceled says the row this move was driving no longer carries its
// token: another client reserved the placement (a `--force`, a second move, a
// `place --set`) while this one ran.
var errMoveCanceled = errors.New("the move was taken over")

// errCommitUnconfirmed says a commit failed and the re-read could not tell
// whether it landed anyway (an answer lost after the write): the registry did
// not answer, or it shows the row committed on the destination with no token
// and no previous binding, which this move's commit leaves behind but so does
// any other client's (tokenlessCommit). The move then stops with both hosts as
// they are and the token kept: a re-run either resumes after the commit
// (resumeCommitted) or resumes the reservation.
var errCommitUnconfirmed = errors.New("the commit was not confirmed by the registry")

// moveState is one move's handle on the registry. A nil *moveState is a move
// running without a registry: every method then does nothing.
type moveState struct {
	c         *edgeClient
	svc       string
	from, to  string
	tok       string
	user      string
	committed bool
}

// moveHeld is the local move-state file: the token a move holds, saved on the
// operator's machine so a re-run after a crash or a killed terminal can resume
// its own reservation, and nobody else's.
type moveHeld struct {
	Service string `json:"service"`
	From    string `json:"from"`
	To      string `json:"to"`
	Token   string `json:"token"`
}

// moveStatePath is where the token of svc's open move is kept:
// $XDG_STATE_HOME/fleet-containers/moves/<svc>.json (~/.local/state by default).
func moveStatePath(svc string) string {
	dir := os.Getenv("XDG_STATE_HOME")
	if dir == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		dir = filepath.Join(h, ".local", "state")
	}
	return filepath.Join(dir, "fleet-containers", "moves", svc+".json")
}

// heldToken is the token the local move-state file holds for a move of svc to
// to; empty when there is none (or it is for another destination).
func heldToken(svc, to string) string {
	p := moveStatePath(svc)
	if p == "" {
		return ""
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	var h moveHeld
	if json.Unmarshal(b, &h) != nil || h.Service != svc || h.To != to {
		return ""
	}
	return h.Token
}

// save records the token this move holds. A failure is a warning: the move
// itself is unaffected, only a resume after a crash would need --resume-token.
func (st *moveState) save() {
	p := moveStatePath(st.svc)
	b, _ := json.Marshal(moveHeld{Service: st.svc, From: st.from, To: st.to, Token: st.tok})
	err := errors.New("no home directory")
	if p != "" {
		if err = os.MkdirAll(filepath.Dir(p), 0o700); err == nil {
			err = os.WriteFile(p, append(b, '\n'), 0o600)
		}
	}
	if err != nil {
		info("%s: the move-state file was not written (%v); resume an interrupted run with --resume-token %s", st.svc, err, st.tok)
	}
}

// forget drops the local move-state file once the token is of no further use:
// the move finished, its reservation was released, or another client owns the
// row now.
func (st *moveState) forget() {
	if st == nil {
		return
	}
	if p := moveStatePath(st.svc); p != "" {
		_ = os.Remove(p)
	}
}

// lockMove takes the per-service move lock (<state dir>/moves/<svc>.lock) for
// the whole of a `cnt move`, before moveBegin reads the move-state file: a
// second move of svc started on this machine while the first runs would
// otherwise read the saved token and resume the live move, two processes
// driving one reservation. The lock is nonblocking (a running move refuses the
// second one) and dies with the process, so a crashed move is resumable.
// unlock releases it (a no-op when there is no state dir, and so no token file).
func lockMove(svc string) (unlock func(), err error) {
	p := moveStatePath(svc)
	if p == "" {
		return func() {}, nil
	}
	p = strings.TrimSuffix(p, ".json") + ".lock"
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, fmt.Errorf("%s: cannot create the move lock: %w (nothing was changed)", svc, err)
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("%s: cannot open the move lock: %w (nothing was changed)", svc, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("another `cnt move %s` is running on this machine (it holds %s); nothing was changed. Let it finish, or re-run once it has exited (an interrupted move resumes with its held token)", svc, p)
		}
		return nil, fmt.Errorf("%s: cannot take the move lock %s: %w (nothing was changed)", svc, p, err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

// moveBegin reserves the destination for the move of s from from to to, before
// anything on either host changes. A nil state, nil error means the move runs
// unrecorded: this machine has no registry client, or --force accepted a
// registry that cannot be used. Any error stops the move with nothing changed.
//
// resume is a token the caller passed with --resume-token; without one, the
// token saved by an interrupted earlier run (if any) is presented. A held token
// the registry refuses is dropped, and the move falls back to a fresh
// reservation only with --force.
func moveBegin(s Service, from, to string, force bool, resume string) (*moveState, error) {
	c, err := edgeClientFor()
	if err != nil {
		if errors.Is(err, errNoToken) {
			return nil, nil
		}
		return nil, unrecorded(s, err, force)
	}
	st := &moveState{c: c, svc: s.Name, from: from, to: to, user: exposeUser()}
	held, via := resume, "--resume-token"
	if held == "" {
		held, via = heldToken(s.Name, to), moveStatePath(s.Name)
	}
	if held != "" {
		// A move interrupted (or stopped by an unconfirmed retire) after its
		// commit has only retire and switch left: the reserve below would
		// answer 409 on a committed row.
		if r, err := resumeCommitted(c, s.Name, from, to, held, force); err != nil {
			return nil, err
		} else if r != nil {
			// A tokenless row (accepted only with --force) has nothing to
			// retire; the move-state file stays until the switch is done.
			st.tok, st.committed = r.Token, true
			if st.tok == "" {
				info("%s: the registry records %s committed on %s with no token; finishing the move without proof it is this one's (--force): only the switch is left", s.Name, s.Name, to)
				return st, nil
			}
			st.save()
			info("%s: the move to %s already committed (%s); redoing only the retire and the switch", s.Name, to, via)
			return st, nil
		}
		row, err := c.placementReserve(placementReq{Service: s.Name, Host: to, User: st.user,
			Reason: "cnt move", Token: held})
		switch {
		case err == nil:
			st.tok = row.Token
			st.save()
			info("%s: resuming the move to %s with the held token (%s)", s.Name, to, via)
			return st, nil
		case !isEdgeHTTP(err):
			return nil, unrecorded(s, err, force)
		case !supersededReservation(err):
			return nil, fmt.Errorf("resuming the reservation of %s on %s: %w (nothing was changed)", s.Name, to, err)
		}
		st.forget()
		if !force {
			return nil, fmt.Errorf("%s: the held token %s (%s) no longer owns the placement: %w\nnothing was changed. Check `containers place %s`; settle an open move with `containers place %s --recover`, or take the name over with --force",
				s.Name, held, via, err, s.Name, s.Name)
		}
		info("%s: the held token %s no longer owns the placement (%v); reserving afresh (--force)", s.Name, held, err)
	}
	row, err := c.placementReserve(placementReq{Service: s.Name, Host: to, User: st.user,
		Reason: "cnt move", Force: force})
	if err != nil {
		if !isEdgeHTTP(err) {
			return nil, unrecorded(s, err, force)
		}
		return nil, fmt.Errorf("reserving %s on %s: %w\nnothing was changed. If another move holds it, let it finish (or resume it with the token it holds); `containers place %s --recover` settles an abandoned one, --force takes the name over",
			s.Name, to, err, s.Name)
	}
	st.tok = row.Token
	if st.tok != "" {
		st.save()
		info("%s: reserved on %s (token %s)", s.Name, to, st.tok)
	}
	return st, nil
}

// unrecorded decides a move whose registry client exists but cannot be used:
// refused, unless --force accepts moving without a record.
func unrecorded(s Service, err error, force bool) error {
	if force {
		info("%s: the placement registry cannot be used (%v); moving WITHOUT recording it (--force). Record the result with containers place %s --set <host>", s.Name, err, s.Name)
		return nil
	}
	return fmt.Errorf("%s: the placement registry cannot be used (%v); refusing to move without recording it (nothing was changed). Retry when it answers, or pass --force to move unrecorded", s.Name, err)
}

func isEdgeHTTP(err error) bool {
	var e *edgeHTTPError
	return errors.As(err, &e)
}

// renew extends the reservation's lease between the steps that can take a while
// (a large service takes longer to back up, restore and copy than ReserveTTL).
// An outage is a warning, not an abort: the steps that record the outcome are
// still ahead, and a move that is going well must not die of a registry outage.
// A step longer than the lease fences the row; presenting the token again
// re-opens it, which is what separates "slow" from "abandoned". A takeover is
// not an outage: a re-reserve the registry refuses (409) stops the move with
// errMoveCanceled.
func (st *moveState) renew() error {
	if st == nil || st.committed || st.tok == "" {
		return nil
	}
	_, err := st.c.placementRenew(placementReq{Service: st.svc, Host: st.to, User: st.user, Token: st.tok})
	if err == nil {
		return nil
	}
	if err := st.superseded(err); err != nil {
		return err
	}
	_, err = st.c.placementReserve(placementReq{Service: st.svc, Host: st.to, User: st.user,
		Reason: "cnt move", Token: st.tok})
	if err == nil {
		return nil
	}
	if e := st.superseded(err); e != nil {
		return e
	}
	if supersededReservation(err) {
		// The re-read could not tell, but the registry refused our token.
		st.forget()
		return fmt.Errorf("%w: %v", errMoveCanceled, err)
	}
	info("%s: the reservation could not be renewed (%v); the move goes on", st.svc, err)
	return nil
}

// owned confirms, with this move's token, that the row is still ours before an
// undo rolls the destination back or restarts the source. nil means it is; an
// errMoveCanceled means another client holds it; any other error means the
// registry could not say, or the row is already committed with this move's
// token (renew and reserve both refuse a committed row). Only a takeover the
// re-read confirms drops the held token; every error leaves the hosts as they
// are.
func (st *moveState) owned() error {
	if st == nil || st.tok == "" {
		return nil
	}
	req := placementReq{Service: st.svc, Host: st.to, User: st.user, Token: st.tok}
	_, err := st.c.placementRenew(req)
	if err == nil {
		return nil
	}
	// A lease that ran out fenced the row; the token re-opens it if it is ours.
	req.Reason = "cnt move"
	_, e := st.c.placementReserve(req)
	if e == nil {
		return nil
	}
	if isEdgeHTTP(e) {
		err = e
	}
	if !supersededReservation(e) {
		return fmt.Errorf("could not confirm that this move still owns the placement: %v", err)
	}
	v, re := st.c.placements(false)
	if re != nil {
		return fmt.Errorf("could not confirm that this move still owns the placement: %v (re-reading the row failed: %v)", e, re)
	}
	if r, ok := v.Rows[st.svc]; ok && st.landed(r) {
		return fmt.Errorf("the registry already records the move to %s as committed with this move's token (%v); it is not undone", st.to, e)
	}
	if c := st.takenOver(e, v); c != nil {
		return c
	}
	return fmt.Errorf("could not confirm that this move still owns the placement: %v", e)
}

// landed reports whether r is the row this move's commit leaves behind: on to,
// committed or retiring, and still carrying this move's token. A row committed
// with the token cleared (no previous binding to retire) is not proof: another
// client's commit leaves exactly the same row (see tokenlessCommit).
func (st *moveState) landed(r placementRow) bool {
	if st.tok == "" || r.Token != st.tok || r.Host != st.to {
		return false
	}
	return r.State == placementCommitted || r.State == placementRetiring
}

// tokenlessCommit reports whether r is committed on to with no token and no
// previous binding: what a commit leaves when there was nothing to retire.
// The registry records nothing that ties such a row to the move that made it,
// so to a move whose commit answer was lost it is ambiguous — its own commit,
// or another client's (a forced reserve and commit, `place --set`).
func tokenlessCommit(r placementRow, to string) bool {
	return r.Host == to && r.State == placementCommitted && r.Token == "" && r.Previous == nil
}

// commit publishes the destination as the binding. It presents the token and
// nothing else: a forced commit would land a *replacement* reservation someone
// else made on the same host (recordPlacement makes the same argument).
//
// A failed commit re-reads the row, because its answer may have been lost after
// the write landed: a row committed with this move's token is a commit that
// succeeded. A re-read that fails, or one that finds a tokenless commit on the
// destination (tokenlessCommit: ours or anyone's), returns errCommitUnconfirmed,
// which must be neither undone (the destination may already be the binding) nor
// finished (the switch would uninstall a source this move may not own).
func (st *moveState) commit() error {
	if st == nil {
		return nil
	}
	row, err := st.c.placementCommit(placementReq{Service: st.svc, Host: st.to, User: st.user, Token: st.tok})
	if err != nil {
		v, e := st.c.placements(false)
		if e != nil {
			return fmt.Errorf("%w: %v (re-reading the row failed: %v)", errCommitUnconfirmed, err, e)
		}
		r, ok := v.Rows[st.svc]
		if ok && tokenlessCommit(r, st.to) {
			return fmt.Errorf("%w: %v; the registry records %s committed on %s with no token (revision %d, device %s), which is what this move's commit leaves when there is no previous binding, but also what another client's leaves, and nothing in the row ties it to this move",
				errCommitUnconfirmed, err, st.svc, st.to, r.Revision, dash(r.Device))
		}
		if !ok || !st.landed(r) {
			if c := st.takenOver(err, v); c != nil {
				return c
			}
			return err
		}
		info("%s: the commit's answer was lost (%v), but the registry records it; the move goes on", st.svc, err)
		row = r
	}
	st.committed = true
	// The registry clears the token when there is no previous binding left to
	// retire; nothing below then belongs to this move. A tokenless row is only
	// taken from the commit's own answer: the 200 to this move's token is the
	// proof that the commit was ours.
	st.tok = row.Token
	return nil
}

// retire records that the source is about to be uninstalled, which is what
// makes a rollback onto it need force. It fails closed: the next step renames
// the source's data, so it runs only once the registry has confirmed the row is
// ours and retiring. A failed retire is asked again with the token (the first
// answer may have been lost after it landed; retire is idempotent on a
// retiring row), then the row is re-read; anything short of "ours and
// retiring" is an error, because a takeover followed by an outage would
// otherwise let this move destroy the new owner's source copy.
func (st *moveState) retire() error {
	if st == nil || !st.committed || st.tok == "" {
		return nil
	}
	req := placementReq{Service: st.svc, User: st.user, Token: st.tok}
	_, err := st.c.placementRetire(req)
	if err == nil {
		return nil
	}
	if e := st.superseded(err); e != nil {
		return e
	}
	if _, e := st.c.placementRetire(req); e == nil {
		return nil
	} else if e := st.superseded(e); e != nil {
		return e
	}
	if v, e := st.c.placements(false); e == nil {
		if r, ok := v.Rows[st.svc]; ok && r.Token == st.tok && r.Host == st.to && r.State == placementRetiring {
			return nil
		}
	}
	return fmt.Errorf("the retirement of %s was not confirmed by the registry: %w", st.from, err)
}

// resumeCommitted recognises a move whose commit already landed and returns the
// row (nil when it has not): the row is on to, committed or retiring, and
// carries the token the caller holds (a comparison with a held token, never an
// adoption). Only retire and switch are left to redo.
//
// A tokenless commit on to (tokenlessCommit) is what this move leaves when its
// commit answer was lost and there was no previous binding, but the registry
// cannot prove it is this move's: without force the resume refuses it, and
// with force the operator vouches for it (the row is returned, tokenless, so
// the retire has nothing to do and the switch runs).
func resumeCommitted(c *edgeClient, svc, from, to, held string, force bool) (*placementRow, error) {
	v, err := c.placements(false)
	if err != nil {
		return nil, nil
	}
	r, ok := v.Rows[svc]
	if ok && held != "" && tokenlessCommit(r, to) {
		if !force {
			return nil, fmt.Errorf("%[1]s: the registry records %[1]s committed on %[2]s with no token and no previous binding (revision %[3]d, device %[4]s, user %[5]s). That is what this move's commit leaves when its answer was lost, but also what another client's commit leaves, and the registry records nothing that ties it to the held token %[6]s; nothing was changed, and %[1]s is still installed on %[7]s. Check where %[1]s runs (`containers place %[1]s --verify`); if this move made that commit, re-run with --force to finish it: the switch then uninstalls %[1]s on %[7]s and renames its data. Otherwise leave %[7]s alone and remove the move-state file %[8]s",
				svc, to, r.Revision, dash(r.Device), dash(r.User), held, from, moveStatePath(svc))
		}
		return &r, nil
	}
	if !ok || held == "" || r.Token != held || r.Host != to ||
		(r.State != placementCommitted && r.State != placementRetiring) {
		return nil, nil
	}
	if r.Previous == nil || r.Previous.Host != from {
		prev := "none"
		if r.Previous != nil {
			prev = r.Previous.Host
		}
		return nil, fmt.Errorf("%s: the held token's move committed to %s with source %s, not %s; nothing was changed (pass --from %s)", svc, to, prev, from, prev)
	}
	return &r, nil
}

// release drops the reservation this move made, and only that one: unforced,
// because the token says the row is still ours, so a 409 means another client
// has since reserved the placement and owns it now (deleting that row would
// destroy their reservation along with the fence that keeps this token out).
// Nothing to drop once the commit landed: routing points at the destination,
// and that is not a rollback. A release that did not get through keeps the
// move-state file, so a re-run resumes the reservation instead of being fenced.
func (st *moveState) release() {
	if st == nil || st.committed || st.tok == "" {
		return
	}
	if _, err := st.c.placementRemove(st.svc, st.tok, 0, false); err != nil && !supersededReservation(err) {
		info("%s: the reservation was not rolled back (%v); re-run the move to resume it, or settle it with containers place %s --recover", st.svc, err, st.svc)
		return
	}
	st.forget()
	st.tok = ""
}

// superseded re-reads the row a failed write was aimed at and reports a
// takeover. Nothing else counts: a re-read that fails, a row that is gone, or a
// row still carrying this token all leave the decision to the caller. The
// re-read only compares tokens; it never adopts one.
func (st *moveState) superseded(err error) error {
	if err == nil {
		return nil
	}
	v, e := st.c.placements(false)
	if e != nil {
		return nil
	}
	return st.takenOver(err, v)
}

// takenOver is superseded's verdict on a row already re-read into v.
func (st *moveState) takenOver(err error, v *placementView) error {
	r, ok := v.Rows[st.svc]
	if !ok || r.Token == st.tok {
		return nil
	}
	if tokenlessCommit(r, st.to) {
		// A tokenless commit on the destination may be this move's own
		// commit (nothing to retire) or another client's: ambiguous, not a
		// confirmed takeover. The caller decides, and keeps the token.
		return nil
	}
	st.forget()
	return fmt.Errorf("%w: %v\nanother client now owns this placement; this move stopped and left both hosts as they are. Check where a copy of %[3]s is running before starting one, and settle the row with containers place %[3]s --recover",
		errMoveCanceled, err, st.svc)
}
