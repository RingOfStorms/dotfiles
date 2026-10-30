package containers

// The placement registry on h005 (containers/PLACEMENT-PLAN.md) is the runtime
// answer to "which host runs this service". These are the CLI's paths into it:
// the same edgeClient the expose API uses (one listener, one machine token,
// one error shape), and a package-level seam so tests can answer without a
// fleet-edge.
//
// Every write sends only the keys placements.Request accepts: the registry
// decodes with DisallowUnknownFields, so an extra field is a hard 400.

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"text/tabwriter"
)

// placementBinding is placements.Binding: the host a reservation came from.
type placementBinding struct {
	Host string `json:"host"`
}

// placementRow mirrors placements.Row (the fields the CLI reads).
type placementRow struct {
	Service      string            `json:"service"`
	Host         string            `json:"host"`
	State        string            `json:"state"`
	Previous     *placementBinding `json:"previous,omitempty"`
	Device       string            `json:"device,omitempty"`
	User         string            `json:"user,omitempty"`
	Reason       string            `json:"reason,omitempty"`
	Created      int64             `json:"created"`
	Updated      int64             `json:"updated"`
	ReserveSince int64             `json:"reserveSince,omitempty"`
	Token        string            `json:"token,omitempty"`
	Revision     int64             `json:"revision"`
	Conflict     string            `json:"conflict,omitempty"`
	LastError    string            `json:"lastError,omitempty"`
}

// placementStates are the row states the registry can report.
const (
	placementPrepared  = "prepared"
	placementCommitted = "committed"
	placementRetiring  = "retiring"
	placementStale     = "stale"
)

// effective is placements.Row.Effective: the host the name resolves to now. A
// prepared reservation still serves from its previous binding, a stale one
// from nowhere (the fence is on), and a first placement only once committed.
func (r placementRow) effective() string {
	switch r.State {
	case placementPrepared:
		if r.Previous != nil {
			return r.Previous.Host
		}
		return ""
	case placementStale:
		return ""
	}
	return r.Host
}

// placementVerify is placements.Verify: where every bound service really is.
type placementVerify struct {
	Bound map[string]string `json:"bound"`
	Stray map[string]string `json:"stray"`
	Error string            `json:"error"`
}

// placementView is one read of the registry: the rows, the effective host per
// service, and (with --verify) live state per host.
type placementView struct {
	Rows   map[string]placementRow
	Host   map[string]string
	Verify *placementVerify
}

// placementNow is the registry read the CLI resolves hosts from. It is a var
// so tests can answer without fleet-edge, and nil means "the registry was not
// asked" (no credentials, unreachable, or --dry-run): resolution then falls
// through to discovery, which is what fixtures and dev machines need.
var placementNow = fetchPlacements

// fetchPlacements reads GET /api/placements. A machine without the root-only
// key (every dev box, every test) has no way in, and that is not an error the
// caller can act on: it returns nil and the caller discovers instead.
func fetchPlacements(verify bool) *placementView {
	c, err := newEdgeClient()
	if err != nil {
		return nil
	}
	v, err := c.placements(verify)
	if err != nil {
		return nil
	}
	return v
}

// placements reads the registry as a view.
func (c *edgeClient) placements(verify bool) (*placementView, error) {
	var out struct {
		Rows   []placementRow    `json:"rows"`
		Host   map[string]string `json:"host"`
		Verify *placementVerify  `json:"verify"`
	}
	p := "/api/placements"
	if verify {
		p += "?verify=1"
	}
	if err := c.do("GET", p, nil, &out); err != nil {
		return nil, err
	}
	v := &placementView{Rows: map[string]placementRow{}, Host: out.Host, Verify: out.Verify}
	for _, r := range out.Rows {
		v.Rows[r.Service] = r
	}
	return v, nil
}

// placementReq is the body of every placement write (placements.Request). The
// keys are omitempty there too, so a zero handle is simply absent.
type placementReq struct {
	Service  string `json:"service,omitempty"`
	Host     string `json:"host,omitempty"`
	Reason   string `json:"reason,omitempty"`
	User     string `json:"user,omitempty"`
	Token    string `json:"token,omitempty"`
	Revision int64  `json:"revision,omitempty"`
	Force    bool   `json:"force,omitempty"`
}

// placementImport is placements.Import (the bootstrap body).
type placementImport struct {
	User       string           `json:"user,omitempty"`
	Reason     string           `json:"reason,omitempty"`
	Token      string           `json:"token,omitempty"`
	Revision   int64            `json:"revision,omitempty"`
	Force      bool             `json:"force,omitempty"`
	Placements []placementEntry `json:"placements"`
}

// placementEntry is placements.Placement: service -> host.
type placementEntry struct {
	Service string `json:"service"`
	Host    string `json:"host"`
}

func (c *edgeClient) placementPost(act string, r placementReq) (placementRow, error) {
	var out struct {
		Row placementRow `json:"row"`
	}
	err := c.do("POST", "/api/placements/"+act, r, &out)
	return out.Row, err
}

// reserve records the destination and the prior binding; nothing is routed to
// it yet. The returned row carries the token the move must present.
func (c *edgeClient) placementReserve(r placementReq) (placementRow, error) {
	return c.placementPost("reserve", r)
}

// placementCommit records that routing points at the destination.
func (c *edgeClient) placementCommit(r placementReq) (placementRow, error) {
	return c.placementPost("commit", r)
}

// placementRetire records that the source is being uninstalled.
func (c *edgeClient) placementRetire(r placementReq) (placementRow, error) {
	return c.placementPost("retire", r)
}

// placementRenew extends the lease on a reservation this move still holds.
func (c *edgeClient) placementRenew(r placementReq) (placementRow, error) {
	return c.placementPost("renew", r)
}

// placementRecover settles a fenced row from the hosts' own answers.
func (c *edgeClient) placementRecover(r placementReq) (placementRow, error) {
	return c.placementPost("recover", r)
}

// placementRemove rolls a placement back (or drops a first placement). The
// registry answers {"row":null} for a service that has no row, so the row is
// decoded through a pointer.
func (c *edgeClient) placementRemove(svc, token string, revision int64, force bool) (*placementRow, error) {
	var out struct {
		Row *placementRow `json:"row"`
	}
	p := "/api/placements/" + svc + "?user=" + exposeUser()
	if token != "" {
		p += "&token=" + token
	}
	if revision > 0 {
		p += fmt.Sprintf("&revision=%d", revision)
	}
	if force {
		p += "&force=1"
	}
	if err := c.do("DELETE", p, nil, &out); err != nil {
		return nil, err
	}
	return out.Row, nil
}

// supersededReservation reports whether a rollback was refused because the row
// is no longer the one the token belongs to: another client reserved the same
// host (which mints a new token) or the move ended, so the row now names a
// binding this caller never reserved. The registry answers 409 for that, and it
// is the healthy outcome of the race — there is nothing of ours left to drop.
func supersededReservation(err error) bool {
	var e *edgeHTTPError
	return errors.As(err, &e) && e.Code == 409
}

// placementImportResult is the answer to /import: the adopted and the skipped
// entries as strings ("svc on host", "svc on host (why)").
type placementImportResult struct {
	Imported []string `json:"imported"`
	Skipped  []string `json:"skipped"`
}

// placementImportPosts adopts an observed placement (the one-time bootstrap
// and `cnt place --adopt`).
func (c *edgeClient) placementImport(r placementImport) (placementImportResult, error) {
	var out placementImportResult
	err := c.do("POST", "/api/placements/import", r, &out)
	return out, err
}

// ---------------------------------------------------------------- `cnt place`

// registry is the read the resolution paths use: the cached view when one was
// already fetched in this run, else a fresh read (nil when nobody can).
var registryCache *placementView

func registry() *placementView {
	if registryCache != nil {
		return registryCache
	}
	if dryRun {
		return nil
	}
	registryCache = placementNow(false)
	return registryCache
}

// boundHost is the host the registry binds name to, "" when it binds none or
// the registry could not be asked.
func boundHost(name string) string {
	if v := registry(); v != nil {
		return v.Host[name]
	}
	return ""
}

// registryHosts is every host the registry knows about (bound, reserved and
// previously bound), so discovery also probes hosts the inventory no longer
// declares.
func registryHosts() []string {
	v := registry()
	if v == nil {
		return nil
	}
	set := map[string]bool{}
	for _, h := range v.Host {
		if h != "" {
			set[h] = true
		}
	}
	for _, r := range v.Rows {
		if r.Host != "" {
			set[r.Host] = true
		}
		if r.Previous != nil && r.Previous.Host != "" {
			set[r.Previous.Host] = true
		}
	}
	out := make([]string, 0, len(set))
	for h := range set {
		out = append(out, h)
	}
	sort.Strings(out)
	return out
}

// cmdPlace shows the registry, or records a placement.
//
//	cnt place                     rows: bound host, state, lease left
//	cnt place --verify            the same, plus where every bound service is
//	cnt place <svc> --host <h>    record a first placement (reserve+commit)
//	cnt place <svc> --adopt       adopt where discovery finds exactly one copy
//	cnt place <svc> --recover     settle a fenced row from the hosts' answers
//	cnt place <svc> --set <h>     move the binding onto <h> (recover-style)
//	cnt place --import            adopt every service discovery finds exactly once
//	cnt place <svc> --recover --token <t>  settle the move that holds <t>
func cmdPlace(args []string) error {
	f := parse(args, "verify", "import", "force", "adopt", "recover", "list")
	if f.bools["import"] {
		return cmdPlaceImport(f)
	}
	c, err := edgeClientFor()
	if err != nil {
		return fmt.Errorf("the placement registry needs this machine's key: %w", err)
	}
	svc := ""
	if len(f.pos) > 0 {
		svc = f.pos[0]
	}
	switch {
	case f.bools["recover"]:
		if svc == "" {
			return fmt.Errorf("usage: containers place <svc> --recover [--force]")
		}
		row, err := c.placementRecover(placementReq{Service: svc, User: exposeUser(),
			Token: f.vals["token"], Force: f.bools["force"]})
		if err != nil {
			return err
		}
		fmt.Printf("%s: %s -> %s\n", row.Service, row.State, dash(row.effective()))
		return nil
	case f.vals["set"] != "":
		if svc == "" {
			return fmt.Errorf("usage: containers place <svc> --set <host>")
		}
		return placeSet(c, svc, f.vals["set"], f.bools["force"])
	case f.vals["host"] != "":
		if svc == "" {
			return fmt.Errorf("usage: containers place <svc> --host <host>")
		}
		return placeSet(c, svc, f.vals["host"], f.bools["force"])
	case f.bools["adopt"]:
		if svc == "" {
			return fmt.Errorf("usage: containers place <svc> --adopt")
		}
		return placeAdopt(c, svc)
	case svc != "":
		return fmt.Errorf("usage: containers place [--verify] | place <svc> --host <host> | --adopt | --recover | --set <host>")
	}
	return placeList(c, f.bools["verify"])
}

// recordPlacement reserves a placement and commits it straight away, returning
// the row as the registry holds it. The caller has already decided where the
// service belongs; the registry still refuses a destination that is not running
// it yet.
//
// Every successful return is a row this call recorded: the reserve mints the
// token only for a reservation the caller took, and that token is the handle
// for the commit. A row that comes back without a token belongs to nobody (a
// reservation another client let go), and renewing it would announce a
// placement nothing committed — so that is refused here rather than reported as
// recorded.
//
// force belongs to the reserve alone: it is how an operator overrides a
// conflict while taking the reservation, and the token that reserve returns is
// the handle for everything after. A forced commit would skip checkToken and
// land a *replacement* reservation someone else made on the same host, so the
// commit presents the token and nothing else.
func recordPlacement(c *edgeClient, svc, host, reason string, force bool) (placementRow, error) {
	row, err := c.placementReserve(placementReq{Service: svc, Host: host, User: exposeUser(),
		Reason: reason, Force: force})
	if err != nil {
		return row, err
	}
	if row.Token == "" {
		// Nobody holds this row, so no token can commit it. Only the hosts'
		// own answers settle a reservation that outlived its client.
		return row, fmt.Errorf("%s is reserved for %s without a token; settle it with `containers place %s --recover`", svc, host, svc)
	}
	tok := row.Token
	row, err = c.placementCommit(placementReq{Service: svc, Host: host, User: exposeUser(),
		Token: tok})
	if err != nil {
		// Drop the reservation we made, and only that one. The rollback is
		// deliberately unforced: the token says the row is still ours, so a
		// 409 means another client has since reserved the same host and
		// owns the row now — deleting it (force) would destroy their
		// reservation along with the fence that keeps our stale token out.
		if _, rmErr := c.placementRemove(svc, tok, 0, false); rmErr != nil && !supersededReservation(rmErr) {
			return row, fmt.Errorf("%w (and the reservation could not be dropped: %v)", err, rmErr)
		}
		return row, err
	}
	return row, nil
}

// placeSet records a first placement or moves the binding onto host.
func placeSet(c *edgeClient, svc, host string, force bool) error {
	if dryRun {
		fmt.Printf("plan: place %s on %s (reserve, then commit)\n", svc, host)
		return nil
	}
	row, err := recordPlacement(c, svc, host, "cnt place --set", force)
	if err != nil {
		return err
	}
	resetFleetPlacement()
	fmt.Printf("%s: %s -> %s (revision %d)\n", row.Service, row.State, dash(row.effective()), row.Revision)
	return nil
}

// placeAdopt imports the placement discovery found, so a service that is
// already running somewhere does not need --host. It refuses unless exactly one
// copy is installed and every host answered: adopting one of two copies would
// strand the other on the same name.
func placeAdopt(c *edgeClient, svc string) error {
	s := service(svc)
	if dryRun {
		fmt.Printf("plan: adopt %s from discovery\n", svc)
		return nil
	}
	p := locate(s, fleetProbe)
	if len(p.unreachable) > 0 {
		return fmt.Errorf("cannot adopt %s: %s did not answer, so a copy there would be missed (bring it back, or place --set)", svc, joinHosts(p.unreachable))
	}
	switch len(p.found) {
	case 0:
		return fmt.Errorf("%s is installed on no host; nothing to adopt (deploy it with --host, then place --set)", svc)
	case 1:
	default:
		return fmt.Errorf("%s is installed on %s; pick one with place %s --set <host>", svc, joinHosts(p.found), svc)
	}
	res, err := c.placementImport(placementImport{User: exposeUser(), Reason: "cnt place --adopt",
		Placements: []placementEntry{{Service: svc, Host: p.found[0]}}})
	if err != nil {
		return err
	}
	resetFleetPlacement()
	for _, s := range res.Skipped {
		fmt.Printf("skipped: %s\n", s)
	}
	if len(res.Imported) == 0 {
		return fmt.Errorf("%s was not adopted (see above)", svc)
	}
	fmt.Printf("adopted: %s\n", res.Imported[0])
	return nil
}

// cmdPlaceImport is the one-time bootstrap: every service discovery finds on
// exactly one host becomes a placement. It prints what the registry adopted and
// what it skipped, and refuses to guess between two copies.
func cmdPlaceImport(f flags) error {
	c, err := newEdgeClient()
	if err != nil {
		return fmt.Errorf("the placement registry needs this machine's key: %w", err)
	}
	loadInventory()
	var entries []placementEntry
	var unknown []string
	for name := range inv.Services {
		s := inv.Services[name]
		p := locate(s, fleetProbe)
		switch {
		case len(p.found) == 1:
			entries = append(entries, placementEntry{Service: name, Host: p.found[0]})
		case len(p.found) > 1:
			unknown = append(unknown, fmt.Sprintf("%s on %s", name, joinHosts(p.found)))
		case len(p.unreachable) > 0:
			unknown = append(unknown, fmt.Sprintf("%s (a host did not answer: %s)", name, joinHosts(p.unreachable)))
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Service < entries[j].Service })
	if dryRun {
		for _, e := range entries {
			fmt.Printf("plan: import %s on %s\n", e.Service, e.Host)
		}
		for _, u := range unknown {
			fmt.Printf("plan: skip %s\n", u)
		}
		return nil
	}
	if len(entries) == 0 {
		return fmt.Errorf("nothing to import: no service was found on exactly one host")
	}
	res, err := c.placementImport(placementImport{User: exposeUser(), Reason: "cnt place --import", Force: f.bools["force"],
		Placements: entries})
	if err != nil {
		return err
	}
	resetFleetPlacement()
	for _, s := range res.Imported {
		fmt.Printf("imported: %s\n", s)
	}
	for _, s := range res.Skipped {
		fmt.Printf("skipped: %s\n", s)
	}
	for _, u := range unknown {
		fmt.Printf("undecided: %s\n", u)
	}
	return nil
}

func placeList(c *edgeClient, verify bool) error {
	v, err := c.placements(verify)
	if err != nil {
		return err
	}
	registryCache = v
	fmt.Print(placementTable(v))
	return nil
}

func placementTable(v *placementView) string {
	var b strings.Builder
	tw := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	head := "SERVICE\tSTATE\tBOUND\tPREVIOUS\tTOKEN\tCONFLICT"
	if v.Verify != nil {
		head += "\tLIVE"
	}
	fmt.Fprintln(tw, head)
	names := make([]string, 0, len(v.Rows))
	for n := range v.Rows {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		r := v.Rows[n]
		prev := "-"
		if r.Previous != nil {
			prev = r.Previous.Host
		}
		tok := "-"
		if r.Token != "" {
			tok = "held"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s", n, r.State, dash(r.effective()), prev, tok, dash(r.Conflict))
		if v.Verify != nil {
			fmt.Fprintf(tw, "\t%s", dash(verifyLine(v.Verify, n)))
		}
		fmt.Fprintln(tw)
	}
	tw.Flush()
	if len(names) == 0 {
		fmt.Fprintf(&b, "\nno placements\n")
	}
	if v.Verify != nil && v.Verify.Error != "" {
		fmt.Fprintf(&b, "\n! %s\n", v.Verify.Error)
	}
	return b.String()
}

// verifyLine is the live answer for one service: where it is actually
// installed, and whether that agrees with the binding.
func verifyLine(v *placementVerify, svc string) string {
	if h, ok := v.Stray[svc]; ok {
		return "stray on " + h
	}
	if h, ok := v.Bound[svc]; ok {
		return h
	}
	return ""
}

func joinHosts(hosts []string) string {
	out := ""
	for i, h := range hosts {
		if i > 0 {
			out += ", "
		}
		out += h
	}
	return out
}
