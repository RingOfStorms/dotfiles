# Service placement: where a floating container runs

Design for removing `host` from `service.nix`. Today 19 of the 20
`containers/<svc>/service.nix` files name the host they run on (16 on h001,
`hello-nixos` on h003 after its recent move, `localai` on joe, `hello-podman` on
lio; `minecraft` is `host = null`, offline), and five Nix functions
(`edgeRoutes`, `edgeVirtualHosts`, `routeNamesByHost`, `dnsRecords`
and `webSourcesByHost` — all in `containers/lib.nix`, listed in §4)
derive network state from that one string. That makes Nix
the runtime answer to "which box runs X", which is wrong: placement changes on a
`cnt move`, and a Nix string that must be edited, committed, rebuilt and pushed
afterwards is a shadow copy that is either stale or a source of silent mistakes.

Target: **Nix describes what a service is; h005 describes where it runs.**
Placement is runtime state, recorded in one registry, and everything that must
follow it (DNS, o002 vhosts and streams, h005 WAN forwards, firewall admission,
the CLI's own guessing) reads that registry instead of a Nix attribute.

An unplaced service is **offline and unowned**: no row, no route, no DNS name, no
key on the edge. That is one state, not a flag — there is no `enabled`/
`inactive`/`disabled` field anywhere in this design. `minecraft` is the live
example (`host = null` today); its `service.nix` still declares the game and web
routes because those are facts about the service, but while it has no row the
25565 forward does not exist, `computerboyz` has neither a DNS record nor an
o002 vhost, and the dashboard lists it under "unplaced".

Status: **phase 1 done**, **phase 2 done**, **phase 3 implemented, not deployed**,
**phase 4a implemented, not deployed**. Deploy **h005 first**, then **o002**.
The stream layer rejects the old receiver's array reply without making changes.
o002 seeds an empty stream directory at boot/activation from a Nix snapshot
of its former static `3032 -> h001` stream, avoiding a cutover gap; thereafter
the reconciler owns it. Before and after deployment (and a test move), run
`git ls-remote ssh://git@git.joshuabell.xyz:3032/<repo>`.
No deployment or SSH verification is part of this implementation.

---

## 1. The registry

`flakes/fleet-edge/internal/placements`, served by the existing
`fleet-edge-overrides` unit on `127.0.0.1:8098` (same listener as
`internal/overrides`, mounted on one `http.ServeMux` in `main.go`).

State: `/var/lib/fleet-edge-overrides/placements.json` (0600, written atomically
under a mutex; the file is `{"revision": N, "rows": [...]}`, and `revision` is
the registry-wide counter that outlives the rows) and `placements-audit.log`
(one JSON line per request, refusals and rate-limited calls included). Same
`StateDirectory` as the expose authority: both are h005-local runtime state
owned by the same DynamicUser. The dashboard reads the loopback export over
HTTP; the phase-3 reconciler reads the registry in-process with `Snapshot()`.

Callers authenticate exactly like `cnt expose` (`internal/authority`): a Zitadel
machine token whose `sub` is in `fleet.global.overrideWriters`
(`hosts/fleet.nix:54-62`), sent from that host's overlay IP through h005 nginx
(`/api/placements`, deny o002, `X-Fleet-Peer` set from the loopback trusted peer).
Writers are per-host, so `Row.Device` is the host that made the change; that is
the whole point of the machine-identity scheme. The writers are lio, juni, gp3,
oren, h001, h003 and `joe`, so every container host can write. h001, h003 and
`joe` were added in phase 3 (planned for phase 2, deferred until their Zitadel
machine users were provisioned; all three run sec-agent, `hosts/joe/flake.nix:118`).
The writer set had to be complete *before* a host's own firewall rule can follow
its placement, because a host that cannot write a placement cannot close the rule.

### Row shape

| Field | Meaning |
|---|---|
| `service` | inventory service name (`containers/<svc>/service.nix`) |
| `host` | destination: where it should run |
| `state` | `prepared` \| `committed` \| `retiring` \| `stale` |
| `previous` | the prior binding, kept for rollback |
| `token` | the reservation handle; while it is set the row is fenced. Commit, retire, rollback, recover and renew all present it, and a handle from a move that has ended is refused rather than read as "no reservation" |
| `revision` | the row's incarnation: a number minted from the registry counter on every write, for compare-and-swap on the writes that carry no token (`import`, `force`, a tokenless `DELETE`). Numbers are never reissued — the counter survives the row it was read from |
| `device`, `user`, `reason` | who and why |
| `created`, `updated` | timestamps |
| `reserveSince` | last lease renewal (a move renews it as it advances) |
| `hostMissingSince`, `conflict`, `lastError` | sweep observations, never auto-resolved |

`Row.Effective()` is the single reader-facing answer: a `prepared` row still
serves from `previous` (a move in flight), a `committed` row serves from `host`,
a `prepared` first placement and a `stale` row serve nowhere (nothing is claimed
until commit or recovery decides). `GET /internal/placements.json` exports
`{rows, host: {svc: host}, conflicts}` so a reader never replays the state
machine, and an absent entry is what "unplaced" means.

### API

| Call | Effect |
|---|---|
| `POST /api/placements/import` | one-time bootstrap: adopt observed placements, skip existing rows unless `force`; a fenced row needs its `token` or `force`; CAS on `revision` |
| `POST /api/placements/reserve` | record destination + previous, mint a token; nothing routed to it yet. Repeating it with the same token and host renews the lease. A token or revision the existing row has moved past is a 409, and so is either handle on a service with no row left |
| `POST /api/placements/commit` | routing now points at the destination; destination must be installed *and* active; needs the token |
| `POST /api/placements/retire` | the source is being uninstalled; rollback now needs `force`; needs the token |
| `POST /api/placements/renew` | extend the lease on a `prepared` row you hold (a move longer than `ReserveTTL`) |
| `POST /api/placements/recover` | settle a `stale` row after checking both hosts (also `DELETE <svc>?recover=1`) |
| `DELETE /api/placements/<svc>?token=<t>[&force=1]` | rollback: restore the prior binding, or drop a first placement; refused on a `stale` row. On a row with no token, `?revision=<n>` (the incarnation read) stands in for it |
| `GET /api/placements[?verify=1]` | rows + effective hosts (+ live per-host verification) |

Every operation that finishes, undoes or extends a move presents the row's
`token`, and a mismatch is a 409: the token is how two clients moving the same
service stay apart. `force` is the only override, and it mints a fresh token so
the displaced client's handle stops working. Writes with no token (`import`, a
`DELETE`) CAS on `revision` and are refused if the row has changed since they
read it.

`revision` is an incarnation, not a counter on the row: it is minted from a
sequence in `placements.json` that no deletion resets. So a number cannot
outlive the placement it was read from either. Destroy a service, deploy it
again, and a delayed `DELETE ?revision=<old>` is a 409 against the replacement
rather than a hit — the replacement was minted above every number already
handed out, including those of rows that no longer exist.

A token is also refused once the move it belonged to has ended — the sweep
cleared it because the source was uninstalled, or the move was recovered or
rolled back. That handle matches nothing on a row that now has no token, and a
plain tokenless `DELETE` is not the fallback: it would drop or move a binding the
caller never reserved. So a `DELETE` carries the token, or — on a row whose move
has ended — the revision it read, or `force`. Ending a placement is always an
explicit act, never the absence of an argument.

The fence is the token itself, not the state or the lease: any row that still
carries one — `prepared`, `stale`, or a `committed`/`retiring` move whose source
is not yet uninstalled — refuses a second reserve. The 30-minute lease only
decides when the sweep *announces* a `prepared` row as `stale`; it never frees
the binding, because an expired move may have stopped its source already.

A reserve is fenced by both handles on *every* existing row, not only on one
that still carries a token: presenting a token the row no longer has is a 409
(the reservation it belongs to has ended), and so is a revision the row has
moved past. A delayed reserve — composed before a move finished, delivered
after the sweep cleared its token — is therefore refused instead of starting a
new move against the replacement binding it never reserved. The same holds
where there is no row left at all: a reserve carrying a token or a revision can
only belong to a placement that was since deleted, so it is a 409 rather than a
first placement — otherwise a replay would bring the deleted row back. A first
placement carries neither handle, so it is unaffected. `force` is the override,
and it mints a new token.

A write is persisted before it is visible. Each operation builds the new rows
and the next `revision` on a copy, writes that copy, and only then makes it the
registry's — so a state file that cannot be written (full disk, a read-only
state dir) is a 500 that leaves the row and the counter exactly as they were,
rather than a binding this process reports until the next restart takes it
away. Sweep commits its whole batch the same way: the row changes and the audit
lines for them either all land or none do.

Refusals carried over from the CLI's old `checkPlacement`/`moveSource` logic:
unknown service, host that is not a container host, a second reserve while one
is live, a move whose destination already runs the service (a second copy would
split it, `force` when that copy is the one to keep), commit before the
destination reports the copy *serving*, and a rollback onto a source that was
retired (`cnt move` renamed its data).

### Sweep (30 s)

Health is about a copy *serving*: a unit that is installed but stopped is not a
placement that is up, and it is not an absent one either. The two facts are
kept apart everywhere — `installed` and `active` — because they answer different
questions: commit needs both, import needs both, and only a confirmed
*uninstall* ends a rollback binding (a move stops the source before it removes
it, so an active-only feed would drop the way back mid-move).

- A reservation whose lease ran out (30 min) is **fenced as `stale`, never
  rolled back**. A move stops its source before it restores the destination, so
  "the reservation expired" does not mean "the source still serves": an
  automatic rollback could route the name at a stopped host while the move is
  still running. The row keeps `previous` and its token (a second move stays
  refused) and `Effective()` reports nowhere. `--recover` settles it by asking
  the hosts; a long move renews its lease instead (`renew`, or re-reserve with
  the token). Nothing settles a fence on a timer.
- A reachable destination that stops serving the service → `hostMissingSince`
  + `lastError`. Not deleted, no grace: a stopped copy is not a lost placement.
- Any *other* host *serving* the service → `conflict`. Never resolved
  automatically; `cnt place --verify` and the dashboard surface it. The
  previous host counts the same way **once the destination also serves**: a
  move stops its source before it commits, so a source still answering next to
  the committed destination is a split brain, not the middle of a move. It is
  flagged and left alone — the rollback binding and the token stay until the
  source is stopped or retired. A source that is stopped, or that serves alone
  while the move is still prepared, is the normal mid-move state and stays
  silent.
- A row that still carries a token refuses a second `reserve` (`prepared`,
  `stale`, and a `committed`/`retiring` move whose source is not yet uninstalled
  alike). The token and `previous` are cleared together: a `committed` row whose
  `previous` host no longer has the unit installed has completed its move, so
  there is nothing left to undo and the binding is free again. A
  `committed`/`retiring` row whose source is only stopped keeps both.
- An unreachable host changes nothing (silence is not absence).

`verify` reports a fenced row's service as `stale`, so `cnt audit` can tell "a
move is stuck and needs a human" apart from "the copy is down". It counts the
rollback copy as expected only while the destination is not serving: once both
serve, the previous host shows up as a stray, the same split brain the sweep
flags.

---

## 2. Move ordering (this is the part the old design got wrong)

`switchScript` (`flakes/fleet-agent/internal/containers/move.go:307`)
uninstalls the source and renames its data to `<dir>.moved-<date>`. The commit
therefore has to land **before** that rename (step 7 below), not after it: once
the data is renamed, rollback can no longer just point back at the source. That
is the bug in the old design, which wrote the repo after the switch. The registry
splits the old "update the repo after the move" into three calls, all on the safe
side of the irreversible step. `cnt move` prints these labels (`move.go:337-524`):

```
1 preflight (target, source)                      ─ unchanged
2 final backup on source, stop, snapshot id        ─ unchanged (data intact), then
  RESERVE destination            ← registry: previous = source, state = prepared,
                                   mint a token. Reserved here, not in step 1,
                                   because the preflight uninstalls leftovers on
                                   the destination and a stranded reservation
                                   would keep routing blind until its lease ran
                                   out. (Effective host is still the source: DNS
                                   and o002 keep pointing at it.)
3 restore snapshot + live DB clusters on target    ─ unchanged
4 deploy + route health on target                  ─ unchanged
5 restore check on target (scratch dir)            ─ unchanged
6 first backup on target                          ─ unchanged; the move marker
                                   is cleared here, so steps 7-9 are registry
                                   bookkeeping an interrupted run can repeat
7 COMMIT (with the token)         ← registry: published host = destination,
                                   state committed. Nothing polls the hosts:
                                   `GET ?verify=1` validates *what they run*,
                                   not DNS, so the operator's check is
                                   `cnt place <svc> --verify` / `cnt audit`
                                   after the move. A failure here stops the
                                   move with both hosts as they are — the
                                   destination serving, the source stopped.
8 RETIRE source (with the token)  ← registry: previous kept, state retiring, so
                                   a rollback onto the source now needs force.
9 uninstall source, data → .moved-<date>           ─ switchScript, unchanged
   (sweep clears `previous` once the source is confirmed uninstalled)

Steps 2, 7 and 8 are the placement registry; 1 and 3-9 are unchanged.

Why this order and not the reverse: routing must never point at a host that has
not proven it can serve the data, and the source must never be destroyed before
routing has demonstrably moved off it. Reserving early is what makes the DNS half
of the cutover a flip rather than a guess.

Any failure in steps 2-6 undoes the target: stop confirmed (killed if needed),
uninstall, data moved aside as `<svc>.failed-move-<time>`, marker removed last;
then `DELETE /api/placements/<svc>?token=<t>`, which restores the *prior* binding
(it never invents or deletes one), and the source starts again if it was
running. If that rollback fails the source is not started — both stay stopped and
the error says what to do by hand. A commit that fails (step 7) takes the same
undo path, so the reservation is not left behind. After the commit only the
operator rolls back, with `cnt place <svc> --recover`. A retire that trips over
a takeover is fatal and stops before the switch; any other retire failure is a
warning and the move finishes, because the destination is already live and the
sweep will settle the source.

**The token, not the clock, decides who may act.** Each reserve mints an opaque
handle and keeps it; commit, retire, rollback, recover and renew present it, so a
client that wakes up late cannot finish or undo a move someone else has since
taken over. "Live" here means the row carries a token, whatever its state or the
age of its lease: a second reserve is refused (409) rather than treated as a hint
that the binding is free, and `force` is the only takeover — it mints a fresh
token, which is exactly what makes the displaced handle stale.

**A long move keeps its lease; it does not get resolved by it.** Step 3→7 can
exceed `ReserveTTL` on a large service, so `cnt move` calls `renew` between steps.
If it does not (crash, killed terminal), the sweep fences the row as `stale`
rather than rolling back: mid-move the source is stopped and the destination is
not serving, so a rollback would point the name at a dead host. Nothing moves
until `cnt place --recover <svc>` asks the hosts which copy is live — the
destination serving means the move landed (record the commit); the source serving
means it did not (restore `previous`); the source installed-but-stopped means it
is still in flight (refuse and say so). Two answers decide nothing, because both
are the same guess: a host that did not answer (the silent end may still be
serving) and both ends reporting the service (the move stopped short of a clean
cutover, so either binding strands the other copy). Both give a 409 naming the
hosts; `--force` records the prior binding anyway (or the destination, when the
fence sat on a first placement with nothing to go back to).

While a fence is on, the CLI does not place anything: `resolveHost` refuses a
row whose token is set and whose `effective()` is empty before it considers
`--host` or discovery (a `stale` row, and a first `prepared` one), because the
only two hosts that could be right are the ones the move just touched. Reads
and `stop` still work through `hostForRead`; the two ways out are
`cnt place <svc> --recover` and `cnt place <svc> --set <host> --force`.

Phase 4 landed this: `cnt move` owns the row (`move.go`, `movestate.go`), so the
old `moveWarning` and the "update `host =` in service.nix" step are gone. The
reservation *is* the record, and the only remaining must-do after a move is
`cnt place <svc> --verify` / `cnt audit` finding nothing.

---

## 3. What stays declarative, what becomes runtime

**Stays in Nix** (still describes the service, not the box):

- `routes` (`exposure`, `auth`, `via`, `proto`, `port`, `fqdn`, `websockets`,
  request/response limits), `net.*`, `persist`, `requires`, `backupHook`,
  `tcpPorts`/`udpPorts`, `kind`, `description`.
- The **container host set** (`containerHosts` in `containers/flake.nix`, plus
  `agentHosts`) — a host has to be rebuilt to join, so this is not runtime.
- Host facts: `hosts` from `hosts/fleet.nix` (`overlayIp`, `lanIp`, `trust`).
- `firewallHighTrustIps`, `sshGuardAssertion`, `tailnetExcludedOverlayIps`
  (`containers/lib.nix`): they depend on host trust and overlay IPs, never on
  which service runs where.
- **Ports, protocols and names, never destinations.** A `proto`/`port` in
  `service.nix` is a service fact (which port it listens on, whether it needs a
  WAN port); *which box* answers is not, and every derivation of the second from
  the first is what this plan deletes.

**Becomes runtime** (recorded in the registry):

- Which host runs a service.
- The tailnet/LAN DNS answer for every route name (host overlay/LAN IP).
- The o002 vhost target for every `public` + `via = edge` route.
- The o002 **stream** target for every `public` + `via = edge` + `proto = tcp`
  route (forgejo's SSH :3032) now follows placement via the stream receiver.
- The h005 **WAN forwards** for every `public` + `via = [ "router" ]` non-HTTP
  route (minecraft's 25565) now follow the placed host's inventory `lanIp`.
  Unplaced services contribute no forward; stale rows retain the last answer.
- `:80`/`:443` admission on the host that received the placement (firewall).
- The CLI's resolution of "the host" for every command.

### Two worked examples

**`minecraft` (offline, unowned).** `containers/minecraft/service.nix` keeps
declaring what the service *is*: a Velocity/Paper stack, the WAN game port
25565 (`proto = "tcp"`, `exposure = "public"`, `via = [ "router" ]`), and the
`computerboyz` web route on 8080 (`exposure = "public"`, `via = [ "edge" ]`
default). What it does not carry — and never again will — is a `host`, an
`enabled`/`inactive` flag, or any per-host artefact. While there is no row:

- no `computerboyz` DNS record anywhere: no `hostsdir` entry on either dnsmasq
  instance (the per-name files derive from effective hosts), and no `public`
  CNAME either, because the published name set is filtered by "has a placement"
  (§5);
- no o002 vhost for `computerboyz` exists, hand-kept or pushed;
- no h005 DNAT for 25565 exists;
- the dashboard lists it under "unplaced" and `cnt place` says "no placement";
- `cnt deploy`/`start` refuse without `--host`; with `--host` they make a first
  placement (reserve+commit), and *that* is what recreates the record, the vhost
  and the forward on the next reconciler pass.

The import (`cnt place --import`) adopts only a copy that is installed **and**
active, so a stale unit left on a host from an old run does not get adopted
behind the operator's back; it is listed as skipped with the reason.

**`forgejo` (public TCP, moving off h001).** `containers/forgejo/service.nix`
declares `routes.web` (3000, `git`, public via the edge) and `routes.ssh`
(`port = 3032`, `proto = "tcp"`, `exposure = "public"`, `via = [ "edge" ]`).
The SSH route is a *declared public TCP route on the edge*, not a hard-coded
stream on one destination: h005 pushes `:3032 → <placed host overlay>:3032` to
o002's stream receiver, so moving forgejo to h003 rewrites one file on o002 and
SSH keeps working. Nothing about the move touches `service.nix`, `_constants.nix`
or the router. o002's firewall keeps `3032` literal, because "the edge accepts
public :3032" is a property of the edge, not of where forgejo happens to run.
This matters right now: h001 is scheduled for a fresh reinstall, and the old
hand-kept `proxy_pass 100.64.0.13:3032` would have made that reinstall an SSH
outage with no Nix-level trace.

---

## 4. Consumer inventory (break + change per consumer)

Derived-from-`s.host` Nix functions and their call sites:

| Consumer | Site | Phase | Change |
|---|---|---|---|
| `edgeRoutes` | `lib.nix`, filtered by `r.service.host != null` | 5 | Delete; o002 vhosts come from the runtime reconciler |
| `edgeVirtualHosts` | `lib.nix`, called `hosts/oracle/o002/nginx.nix:23`; eval test `containers/tests/edge-vhosts.nix` | 5 | Delete (and the eval test). o002 gets a reserved-name list + the existing `edgevhost` receiver |
| `routeNamesByHost` | `lib.nix`, called `hosts/h005/wildcard-cert.nix:37` (`routeHosts`) | 5 | Delete. Every route name is a single label under `*.${domain}`, so the cert needs no per-name SAN and the push target set becomes the static container-host list |
| `webSourcesByHost` | `lib.nix:533-604`, filtered by `s.host != null`; called `containers/host-module.nix:31` | 5 | Delete; the runtime firewall allowlist (see §7) supersedes it, and the module keeps only what depends on host trust |
| `dnsRecords` | `lib.nix`, called `hosts/h005/dns-records.nix:12` → `hosts/h005/mods/networking.nix:22`; consumed at `:44` (`host-record`, tailnet), `:49` (`local=`, tailnet) and `:249` (`host-record`, LAN) | 3,5 | Phase 3: h005 writes per-name files into **two** runtime `hostsdir`s (`tailnet/`, `lan/`) from the registry; the `host-record` lines go away, the `local=` does not. Phase 5: **not** deleted — drop the `s.host != null` filter and the IP fields, keeping the `local=` name list and the `public` CNAME list |
| h005 WAN forwards | `internal/wanforward`, `internal/reconcile` | 4a implemented | Static generator deleted. Root validates the registry-derived file and replaces one nft table atomically; port/protocol remain declarative |
| o002's `streamConfig` | `hosts/oracle/o002/nginx.nix` | 4a implemented | Runtime include replaces the hard-coded target; `edgeStreamPorts` is placement-free admission, and boot/activation seed the pre-cutover stream when empty |
| `DeclaredHost` | deleted; `state.ServiceView.BoundHost` (`flakes/fleet-edge/internal/state/state.go:261`, set in `binding` at `:666-671`), sorted `server/server.go:480`, host page `:694`, `dash/dash.go:158,189,225-231`, `topology/layout.go:442`; template `internal/server/templates/services.html:24-31` | 2,5 | Phase 2 done: the registry's binding wins, a service it does not name is "unplaced", and the page groups by it. Phase 5 drops the declarative fallback (`bound == nil`) and the `host` seed |
| CLI `resolveHost` | `fleet-agent/internal/containers/main.go:502` | 2 | The answer, in order: `--host` > registry row > discovery. A fenced row that names no host — a `stale` reservation, or a first placement that has not committed (token set, `effective()` empty) — is refused ahead of both branches, naming the device holding the move, its destination and both settles: `--recover` (asks the hosts themselves) and `--set <h> --force` (takes the name over). Letting it through is how a deploy or start lands a second copy on a host the move may have stranded, ahead of any registry write that could refuse it. A binding onto a host that does not answer refuses and names both escapes (`--set <h> --force`, `--recover --force`); `--host` may not override a different live binding; the first `--host` deploy records it |
| CLI `resolvedHost` | `main.go:563` | 2 | Registry row, else the declared `host`, else `""`; never probes and never refuses, so table/script builders can use it |
| CLI `hostForRead` | `main.go:611` | 2 | `installedHere` local shortcut first, else `hostFor` (so a registry row wins and an unreachable bound host still refuses). Read-only commands and `stop` only: they keep working on a fenced row, while `start`/`restart` resolve through `resolveHost` and refuse both a fence and a local copy the registry binds elsewhere |
| CLI `containerHosts` | `main.go:643` | 2 | Inventory `containerHosts` ∪ the hosts the registry knows ∪ every declared host (the seed stays until phase 5). This is the discovery set; a host in none of them is still reachable with `--host` |
| CLI `locate` | `main.go:666` | 2 | Kept as the discovery fallback and for `place --verify`; never the primary answer |
| CLI `checkPlacement` | — | 2 | Deleted; the registry refuses the conflicting writes itself |
| CLI `moveSource` | `main.go:1614`, dry-run fallback `move.go:348-350` (`from = s.Host`) | 4 | Kept unchanged: `--from` wins, else complete discovery decides, because a move needs the host that *holds a copy*, not the row that says which copy is authoritative (a split brain is exactly what it has to be told about). The dry-run fallback still reads `s.Host` until phase 5 deletes the field |
| CLI `moveWarning` | deleted (was `main.go:1589`, printed at `move.go:458`) | 4 | Done: the binding is the registry's, so there is no `host =` line left to edit. `TestMoveWarning` went with it |
| CLI `cmdMove` | `move.go:344-554`, `movestate.go` | 4 | Done: reserves on the destination before any host is touched (preflights included), `renew`s around the final backup and between steps, commits after the restore check and first backup, retires before the switch. The token is never taken from a read: a move resumes only with one its caller holds (the local move-state file `$XDG_STATE_HOME/fleet-containers/moves/<svc>.json`, or `--resume-token`), else reserves fresh, unforced unless `--force`, so a held or fenced row stops it with zero remote calls. Any failure up to the commit first confirms ownership with the token (renew, re-reserve), then rolls the target back, drops the reservation and restarts the source; lost or unconfirmable ownership leaves both hosts untouched. Only a machine with no registry client moves unrecorded; a configured registry that cannot be used refuses unless `--force` |
| CLI `status`/`ls` note | `main.go:840-864` (`!! placed on … this is a stray copy`, else the legacy `!! declared … set host = …`) | 2 | Done: a copy where the registry does not bind it is a stray, with the `--set` that settles it. The `host =` note survives only for a service with no row at all until phase 5 |
| CLI `cmdDestroy` | `main.go:1585-1645` | 2 | Done: `--host` on a host the registry does not bind removes that stray copy (after a probe confirms it is installed there), never touches the row, and retires only that `(svc, host)` pair before `refreshCallers`. The bound copy needs `--force`, which also removes the row (unforced `DELETE`, revision-guarded); a fenced row refuses without `--force`. Tests: `TestDestroyStrayCopyLeavesTheBinding`, `TestDestroyRefusals` |
| CLI `detail` header | `main.go:1900-1905` (`declared: %s`) | 2,5 | Shows the bound host with the declared one beside it; phase 5 deletes the `(declared: …)` half |
| CLI `backendOf` | `port.go:183` | 2 | Done: `resolvedHost(s) != host` per service |
| CLI `routes` overrides fetch | `routes.go:730-736`, table `routesTableWith` `753-772` (HOST column `769,772`) | 2 | Done: overrides are fetched per `resolvedHost(s)`, and the HOST column prints it; a service with no binding prints `-` |
| CLI `audit` listeners | `routes.go:893` | 2 | Done: `resolvedHost(s) != host` decides which service a listener belongs to |
| CLI `netExceptions` | `routes.go:1090-1116` | 2 | Done: `th := resolvedHost(t)`, and a target with no binding gets no exception |
| CLI `callerIPs` | `routes.go:1178-1190` (`sh`/`ch`) | 2 | Done: both sides resolved through the registry; `net.uses` between two services on the same host keeps the `10.233.0.1` path |
| CLI `expose` | `expose.go:353,383` | 2 | Done: `hostFor`, so `--host` > registry row > discovery |

Tests that pin `s.Host` are the phase-2 residue: the matrix in
`fleet-agent/internal/containers/placement_test.go` pins resolution, the
split-brain start refusal, the deploy recording (and its non-fatal warning), the
deploy leaving a reservation another client made during the deploy untouched —
unforced, with the warning naming that move, `TestDeployLeavesAForeignReservation`
— that the escape hatches reach the registry with `force` on the
reserve/recover only, and that a fenced row naming no host refuses `deploy` and
`start`/`restart` — stale with a rollback binding, and a first `prepared`
placement, with and without `--host` — before any ssh, `systemctl` or registry
write. The rest still assert the declared seed until phase 5 deletes the field.

The move's own matrix is `fleet-agent/internal/containers/movestate_test.go`,
driven by a stateful fake registry (`moveRegistry`) that mirrors the real
handlers' 409s: `TestMoveThenDeployFollowsTheRegistry` (reserve → commit → retire
in order, every later write carrying the reserve's token, and a deploy with no
`--host` landing on the destination even when discovery reports a copy on both
hosts), `TestMoveFailureReleasesTheReservation` (a failed restore check rolls the
target back and drops the token, leaving the name on the source),
`TestMoveTakeoverStopsBeforeTheSwitch` (a foreign token stops the move before the
source is uninstalled, and neither the restart nor the target rollback runs),
`TestMoveRefusedWhileAnotherMoveHoldsTheDestination` (a prepared or stale row
held by another token refuses a second move with zero remote calls and no token
adopted), `TestMoveResumesWithTheHeldToken` (the move-state file or
`--resume-token` resumes and finishes), `TestMoveRefusedWhenTheRegistryIsDown`
(a configured but unreachable registry refuses with zero remote calls),
`TestMoveTakeoverThenDeployFailureLeavesBothHosts` (an ordinary deploy failure
after a takeover neither rolls back nor restarts), and
`TestMoveFailedRestoreCheckRollsBack` for the unrecorded path.

#### Remaining Nix readers of `host` (phase-3 checklist)

Phase 2 left the CLI reading the registry; these Nix builders still derive from
the `host` seed and are the complete set to delete or move at runtime. Anything
found here that is *not* on the list is a phase-3 regression:

- [ ] `edgeRoutes` — `containers/lib.nix:458-468`, filter `r.service.host != null`; call site `hosts/oracle/o002/nginx.nix:23` (via `edgeVirtualHosts`), eval test `containers/tests/edge-vhosts.nix`
- [ ] `webSourcesByHost` — `containers/lib.nix:533-604`, filter `s.host != null` at `:542`; call site `containers/host-module.nix:31`
- [ ] `edgeVirtualHosts` — `containers/lib.nix:616-648`, consumes `edgeRoutes`; call site `hosts/oracle/o002/nginx.nix:23`
- [ ] `routeNamesByHost` — `containers/lib.nix:659-671`, filter `s.host != null` at `:664`; call site `hosts/h005/wildcard-cert.nix:37`. There is no `tlsNamesByHost`; the cert's SANs come from this map
- [ ] `dnsRecords` — `containers/lib.nix:726-798`, filter at `:740`; call site `hosts/h005/dns-records.nix:12` → `hosts/h005/mods/networking.nix:22`, consumed at `:44` (`host-record`, tailnet), `:49` (`local=`) and `:249` (`host-record`, LAN)
- [ ] `containers/flake.nix:92-97` `containerHosts` — keep the list (it is host membership, not placement), and drop the declared-host fallback that `cli`'s `containerHosts()` still adds
- [ ] the `host = null` default (`containers/lib.nix:408`), then the `host` line in all 20 `service.nix` files

One item was phase 3 but is not a reader of `host`: adding `h001`, `h003` and
`joe` to `fleet.global.overrideWriters` (`hosts/fleet.nix:54-62`). It was
deferred out of phase 2 until their Zitadel machine users were provisioned,
and is now done.


### Hand-kept per-host entries (the audit)

Every place the tree still says "this name/port lives on that box" by hand, and
what removes it. Anything not in this list either stays for a reason that is not
placement (host membership, identity, trust) or was missed:

| Hand-kept entry | Where | Dies how |
|---|---|---|
| `containerVhosts` (every container vhost generated at eval time) | `hosts/oracle/o002/nginx.nix:23-26` | Phase 5 deletes the binding and the `clash` assert with it; the names arrive as pushed `edgevhost` files. The `hosts/_shared_assets/utilities/edge-vhost-receiver.nix` `reserved` list is built from o002's own `virtualHosts`, so removing `containerVhosts` is also what makes those names pushable |
| `streamConfig` | `hosts/oracle/o002/nginx.nix` | Phase 4a implemented: runtime stream include; the hard-coded upstream constant is deleted |
| o002 firewall `3032` | `hosts/oracle/o002/nginx.nix:207-211` | **Stays.** "The edge accepts public :3032" is a property of the edge; the destination behind it is the runtime part |
| o002 hand vhosts `www`, `sso-proxy`; public A/CNAMEs `o002`, `headscale`, `www`, `sso-proxy`, `*.share` | `hosts/oracle/o002/nginx.nix` `handVhosts` (:93-160), `hosts/h005/dns-records.nix:76-105` | **Stay.** Not container routes; `headscale` and the o002 anchors are h005/o002's own services. The `clash` eval already refuses a hand name that becomes generated |
| `computerboyz`, `minecraft` CNAMEs | `hosts/h005/dns-records.nix:96-103` (`map (cname "o002") [ … "computerboyz" … ]`, `map (cname "home") [ "minecraft" ]`) | Delete now: the `computerboyz` vhost is already gone from o002, so this CNAME is currently resolving to the `_` reject. After phase 3 the published set derives from placements and an unplaced service must have no name at all; `minecraft`'s `via = router` CNAME would otherwise point at a closed forward |
| Static router forwards | `hosts/h005/router-forwards.nix` | Phase 4a implemented: only the WAN-to-LAN DNAT accept rule and option remain; runtime application is wired in `fleet-edge.nix` |
| `routeHosts` / `targetNames` (TLS push targets) | `hosts/h005/wildcard-cert.nix:37-47` | Phase 5: pinned literal `h001, h003, joe, lio, o002` — the cert is a wildcard, so the target set is host membership, not placement |
| `overrideWriters` | `hosts/fleet.nix:54-62` | **Stays** (identity, not placement). `h001`, `h003` and `joe` were added in phase 3 (deferred from phase 2 until their Zitadel machine users were provisioned), so every container host can write a placement and close its own firewall rule |
| `containerHosts` | `containers/flake.nix:92-97` | **Stays.** A host must be rebuilt to join. The CLI's `containerHosts()` is this list ∪ the hosts the registry knows ∪ every declared host; phase 5 drops the declared-host loop, which is why a host that only ever held one service must appear here |
| "set `host` in `service.nix`", "point `computerboyz` in `hosts/oracle/o002/nginx.nix` at the new host", "WAN port-forwards on the router" | `containers/minecraft/README.md:16,82-83`, `containers/README.md:400-404` | Phase 6 rewrites the move instructions: there is nothing to edit, `cnt move` is the whole procedure |

The invariant to check at the end of phase 5: `grep -rn 'upstreamHost\|containerVhosts\|\.host\b' hosts/oracle/o002/*.nix hosts/h005/*.nix containers/lib.nix` returns only host-membership and trust facts, and no file names a service next to a host.

## 5. Where the reconciler lives

Phases 3 and 4a add one loop to the same `fleet-edge-overrides` unit (it already
owns the state dir, the sweep and the local secrets), fed by the registry export
and the inventory's declarative routes:

- **Tailnet + LAN DNS**: one plain hosts file per name in *two* directories —
  `/var/lib/fleet-edge-dns/tailnet/` and `.../lan/` — because the instances must
  answer the same name with different addresses (overlay IP vs LAN IP, i.e.
  `dnsRecords.tailnet` vs `.lan`). One shared directory cannot serve both; each
  instance watches its own with `hostsdir`. Each file is one line,
  `<ip> <fqdn>`.
  `hostsdir` rather than `host-record` in a `conf-dir`, because it re-reads on
  change with no signal and no restart (inotify), and `ROUTING-PLAN.md:445`
  already records that choice. Verified against dnsmasq 2.93, which pins three
  details this design depends on:
  - the directory **must exist when dnsmasq starts**: a missing `hostsdir` is
    accepted at start-up but never watched, so no later file is ever read.
    `systemd.tmpfiles.rules` on h005 creates both, empty;
  - a **hidden temp name is still read** as a hosts file (`.a.tmp` was served),
    so the atomic write is plain `.new` + `rename`, and a temp left by a crash
    is overwritten on the next pass;
  - **deleting a file drops its record** and the name falls through to the
    `server=` upstreams, which is what a removal needs; an unreachable host keeps
    its file, so its last answer stands.

  Wiring: the tailnet instance adds `hostsdir=/var/lib/fleet-edge-dns/tailnet`
  to its `writeText` conf (`hosts/h005/mods/networking.nix:28-53`), the LAN one
  `services.dnsmasq.settings.hostsdir`. Files 0644 in 0755 directories — the
  tailnet unit runs `DynamicUser` + `ProtectSystem=strict`
  (`networking.nix:320-333`), which still reads `/var/lib`, so no new
  permission, capability or reload path is needed, but the modes are load
  bearing.
  - Both dnsmasq instances keep `local=/<fqdn>/` for every inventory route
    name, with no host or placement filter. Only addresses move into the
    hostsdirs; unplaced names answer locally without an A record rather than
    following a public CNAME. Hand-kept host records remain declarative.
  - Of the three lists `dnsRecords` returns, `tailnet` (every non-local route →
    overlay IP) and `lan` (lan+public routes → LAN IP, only hosts that have one)
    depend on placement for the *address*. `public` targets `o002`/`home`
    regardless of which host holds the service, so the bunny `publicSpec` needs
    only the route *set* — and that set must also become "routes of placed
    services", so the resolver feeds it the set of effective hosts (names only,
    no addresses) while the CNAME target stays declarative. `dns-plan` never
    learns a host.
  - The LAN instance also reserves every inventory route name with `local=`.
    Non-route names retain the existing external `server=` fallthrough.
  - This reverses the "No runtime path" call recorded in
    `ROUTING-PLAN.md:739-745` — the same paragraph already names this extension
    ("Revisit with `cnt expose`/`move` … where a hostsdir fed by fleet-edge is
    the natural extension"). That decision assumed records change only when a
    `service.nix` changes, which is exactly the assumption the registry removes.
  - Ordering is add-before-remove with one file per name and no directory-wide
    rewrite, so a pass that dies halfway leaves the previous answers in place
    for every name it did not reach.
  - Implemented in `internal/reconcile`, in the overrides unit: startup,
    every 30 seconds, and non-blocking registry write notifications. Stale
    rows and unknown/unaddressable hosts keep their last files. The static
    `fleet-edge-dns` group grants the DynamicUser write access to 0775
    hostsdirs; atomic files are chmod 0644 before rename.
  - Authenticated `GET /api/placements/routing` compares files, actual A
    answers from the overlay listener and `127.0.0.1:9053`, and o002's list.
    `cnt audit` prints `== routing (h005)` and treats it as diagnostic only;
    machines without a key omit the section quietly.
- **o002 vhosts**: for each `public` + `via = edge` route whose service has an
  effective host, send the existing runtime receiver
  (`internal/edgevhost.Request{Op: "add", Kind: "placement", FQDN, Host, Until: 0, MaxBody,
  Websockets, Buffering, RequestBuffering, Timeouts}` over the same restricted
  SSH key, `/var/lib/fleet-edge-vhosts/<fqdn>.conf`, `nginx -t` + reload,
  `.reload-pending` marker). `Render` already produces the same block
  `edgeVirtualHosts` emits at eval time — `proxy_pass http://<overlayIp>:8443`,
  the pushed wildcard, the same buffering/timeout/body directives — so the only
  Nix change is dropping `containerVhosts` from `hosts/oracle/o002/nginx.nix:23`.
  Note the direction of the `reserved` list
  (`hosts/_shared_assets/utilities/edge-vhost-receiver.nix:33-35`):
  it is built from o002's *own* `virtualHosts`, so today it refuses a runtime
  push of any container name; removing `containerVhosts` is what makes those
  names pushable. Hand vhosts stay reserved, unchanged.
  Startup pushes every desired placement vhost; later passes list first and
  add/fix before removing only placement-kind leftovers. Placement vhosts
  have no expiry or rate limit, and expose audit ignores them. SSH pushes are
  serialized with the expose authority. `edgeVirtualHosts` stays in lib.nix
  for the eval test until phase 5.
- A route that loses its placement, or drops to a non-`public` exposure, gets
  `Op: "remove"` and a reload. The push order is add-before-remove, and a host
  that stops answering never causes a removal — the host's own edge listener
  already fails closed to 444, so an unreachable host leaves a vhost that
  returns 502 (visible to `cnt audit`) rather than deleting state on a guess.
- **o002 streams (non-HTTP public routes)**: same loop, same key, a second
  receiver. For each `public` + `via = edge` + `proto = tcp` route whose service
  has an effective host, h005 pushes `{"op":"add","kind":"placement","port":3032,"host":"h001"}`;
  o002 writes `/var/lib/fleet-edge-streams/<port>.stream` holding
  `server { listen <port>; proxy_pass <overlayIp>:<port>; }` and runs the same
  `nginx -t` + reload dance. `nginx.nix`'s `streamConfig` becomes
  `include /var/lib/fleet-edge-streams/*.stream;`; the hard-coded upstream
  constant is deleted. The receiver follows
  `hosts/_shared_assets/utilities/edge-vhost-receiver.nix`: shared forced-command key,
  JSON on stdin (never nginx text), atomic write, `.reload-pending` on a failed
  reload, `fleet-stream-expire` timer **and** boot unit before `nginx.service`,
  `systemd.tmpfiles` for the directory (not persisted, like the vhost dir).
  Expiry **deletes** the file, which is the stream equivalent of the vhost
  receiver's `return 444`: nginx's `stream` module has no `return`, and a
  `server` block without `proxy_pass` fails `nginx -t`, so a closed port is the
  only fail-closed rendering. One file per port, add-before-remove, Kind/Host-fenced
  removal; stale, duplicate-port and missing-IP entries keep their last answer.
  Assertions require every admitted stream port in `allowedTCPPorts` and reject
  collisions with 80/443/22. The firewall's 3032 is admission, not placement.
  Why the push and not a router forward: o002 is the public edge and already
  accepts this traffic; a DNAT would move the port's public identity to whichever
  host holds forgejo, and h001 is scheduled for a fresh reinstall — SSH has to
  survive the move without touching the router or the service's own Nix.
- **WAN forwards**: for each `public` + `via = [ "router" ]` non-HTTP route whose
  service is placed, h005 atomically writes `/var/lib/fleet-edge-forwards/forwards.json`
  (`{forwards:[{proto,port,host,source}]}`). Root's `forwards-apply --inventory …
  --wan IF --lan IF` validates every entry and derives LAN IPs from inventory,
  then replaces `table ip fleet-wan-forwards` in one `nft -f` transaction under
  flock, logging every applied set. Missing file means an empty table; invalid
  data leaves the table unchanged and exits nonzero. A PathChanged unit and
  failure-ignored nftables start/reload hooks trigger it. The directory is
  `0775 root:fleet-edge-dns`, writable by the reconciler. Stale, duplicate and
  missing-LAN-IP keys carry over from the current file. `cnt audit` reports
  both `stream` and `wan` layers, including written-but-not-applied forwards.
- **Reload debt** is already tracked by the vhost receiver's `.reload-pending`
  marker and retried (`edgeReloadPending`); the stream receiver gets the same
  marker under its own name, and one reload serves both (a single `nginx -t` +
  reload covers `http` and `stream`). The placement loop reports through those
  markers instead of adding a third. `dns-plan` needs no address input: the
  `public` CNAMEs point at `o002`/`home` regardless of host, so the bunny side
  gets the name set and nothing else.

## 6. The CLI (`cnt`) once placement is runtime

Resolution order for every command: `--host` > registry row > discovery.

| Situation | `deploy`/`start`/`restore` (mutating) | `status`/`logs`/`attach`/`shell`/`online` (reading) |
|---|---|---|
| row exists | use `Effective()` | use `Effective()`, fall back to the host that answers |
| no row, `--host` given | deploy there, then `reserve`+`commit` (first placement) | fine, read there |
| no row, one copy discovered | adopt it (import, printed note), then act there | act there |
| no row, several copies | refuse: `cnt place <svc> --host <h>` | show all, refuse to pick |
| no row, nothing discovered | refuse unless `--host` (a first placement needs a destination) | error |
| row exists, host unreachable | refuse (silent absence is not absence) | note, read elsewhere if the service answers |

- `cnt place` shows rows, `--verify` shows live per-host state (including a
  `stale` row's fence), `--set <svc> --host <h>` records a first placement,
  `--recover <svc>` settles a fenced row (asks both hosts, then commits or
  restores; refuses when the source is installed-but-stopped, i.e. still in
  flight), `--import` is the one-time bootstrap (below). Two refusals are
  deliberate: it decides nothing when a host did not answer (the silent end may
  still be serving), and nothing when both ends report the service running
  (picking either copy strands the other on the same name) — the 409 names both
  hosts, and `--force` is how an operator records that choice. `cnt move` calls
  reserve/commit/retire itself, reserves before it touches any host, holds the
  token for the whole run (saved locally so only its own re-run can resume it),
  and renews the lease as it advances so a slow move never fences.
- `cnt deploy` on a service whose registry host is not the host it deployed to is
  a bug in the CLI, not a user error: it resolves once, then uses that string.
- **`joe` is in `containerHosts` (done).** The CLI's `containerHosts()` also
  adds every declared `s.Host` and every host the registry knows, which is why
  `localai` was discoverable before. Once the field is gone the probe set is
  exactly `inv.ContainerHosts` ∪ the registry's hosts, so a host that only ever
  held one service must be listed there or it silently disappears from
  discovery. The registry's own probe set (`statuses`, `placements.go:904`) has
  the same shape and would miss it for the same reason.

## 7. Firewall and certificates

- **Firewall**: do not open `:80`/`:443` on every container host. Today
  `host-module.nix` derives its `extraInputRules` from `webSourcesByHost` in
  `lib.nix`, i.e. from `s.host`; the runtime half (the ports file) is already
  live, so what remains is that build-time source set. After phase 5 it is
  gone, and the rules
  become a runtime allowlist the host owns — set by `cnt deploy`/`move` when a
  placement lands, cleared when the last one leaves, applied as an nft set that
  the module always creates (empty = closed). Owner: `fw-narrow`.
  What stays in Nix is only what depends on host trust, not on placement: the
  tailnet broad-accept and the per-excluded-IP drops
  (`tailnetExcludedOverlayIps`), the guest `net.uses`/`net.egress` set, and the
  LAN subnet. A failed close is reported by `cnt audit`, not retried silently.
- **Certificates**: `security.acme.certs.${domain}` already carries
  `extraDomainNames = [ "*.${domain}" ]` (`hosts/h005/wildcard-cert.nix:138`), so
  a move never needs a new cert, a new SAN, or a new ACME order. The only
  host-derived input is the *push target* list (`wildcard-cert.nix:37-47`):
  `routeHosts = attrNames (routeNamesByHost …)`, which evaluates to exactly
  `h001` and `joe` today (evaluated), unioned with the literal
  `[ "joe" "lio" "h003" "o002" ]`. So the current target set is
  `h001, joe, lio, h003, o002`, and phase 5 pins exactly that as a literal —
  `h001`/`h003`/`lio`/`joe` are `containerHosts`, `o002` is the public edge.
  Push behaviour is unchanged (no name gains or loses
  a target), and a host that has never served a route can still terminate TLS
  before the first `move` lands there.

## 8. Bootstrap and migration

1. Turn on the unit with the registry empty (nothing reads it yet).
2. Discovery import: for each inventory service, probe every container host and
   import the single copy that is installed **and** active
   (`POST /api/placements/import`). The response lists what was skipped and why
   (`installed but not running`, `not installed`, `did not answer`). Services
   with no serving copy, or with two, are printed and left unplaced for a human —
   the import refuses to guess, never suggests a host from Nix, and never adopts
   a stopped unit on the strength of its data directory.
3. Only once the registry matches reality do phases 2–5 flip their readers.

There is no path that seeds the registry from `service.nix`. That is the point:
a Nix seed would re-create the shadow copy the design removes.

Three facts the plan starts from, so nothing downstream re-derives them:
`hello-nixos` now runs on **h003** (its `service.nix` says so and the generated
DNS follows), and `computerboyz`'s o002 vhost is **already deleted and deployed**
— the `_` reject vhost answers that name now. The public CNAME for it is still in
`hosts/h005/dns-records.nix:96-99`, pointing at an edge that no longer knows the
name, so deleting that line is a live fix, not just phase-5 cleanup. h001 is
scheduled for a **fresh reinstall**, which is why forgejo's SSH must not depend
on anything stored in h001's Nix.

## 9. Phases

| Phase | Scope | Files | Risk |
|---|---|---|---|
| **1 (done)** | Registry: rows, state machine, sweep, API, loopback export, auth, audit; reservation tokens + revision CAS; `installed` vs `active` health; fenced expiry with `recover`/`renew`; shared writer auth in `internal/authority`; one listener in `main.go`; flake option text; h005 `/api/placements` nginx location | `flakes/fleet-edge/internal/{authority,placements}/*`, `internal/overrides/overrides.go`, `flakes/fleet-edge/{main.go,flake.nix}`, `hosts/h005/fleet-edge.nix` | None: nothing reads the registry yet |
| **2** | Read paths: CLI resolution (`resolveHost`/`resolvedHost`/`hostForRead`, `containerHosts`, `backendOf`, `routes.go`, `expose.go`, drift/status output; `checkPlacement` deleted), dashboard grouping, `overrides.Check`; `joe` in `containerHosts`; discovery import command (`cnt place`, including `--recover`); record the binding after a first `--host` deploy; refuse to start a leftover local copy the registry binds elsewhere. `overrideWriters` moved out of this phase (see §9 row 3) | `flakes/fleet-agent/internal/containers/{main.go,move.go,port.go,routes.go,expose.go,placements.go}`, `flakes/fleet-edge/internal/{overrides,state,server,dash,topology}`, `containers/flake.nix` | Medium: a wrong resolution starts a second copy; the refusals above are the guard. CLI tests cover the matrix (`internal/containers/placement_test.go`) |
| **3** | Reconciler: two DNS `hostsdir`s (tailnet overlay IPs, LAN IPs) written from the registry export, o002 runtime vhosts, `dns-plan` keeps its declarative input (only the CNAME *set* follows the registry, and an unplaced service contributes no name). Writers **done**: `h001`, `h003` and `joe` are in `overrideWriters` (`hosts/fleet.nix:54-62`) by their sec-agent machine userIds, subs unique, and h005's `fleet-edge.nix` maps each to its `overlayIp` | `flakes/fleet-edge/internal/{reconcile,dnsplan,server}`, `hosts/h005/{dns-records.nix,mods/networking.nix}`, `hosts/oracle/o002/nginx.nix`, `hosts/fleet.nix` | High: DNS and o002 are shared. Fail-closed ordering (add before remove, keep the old answer when a host is unreachable) and `cnt audit` checks |
| **4 (done)** | Move rebind, in `cmdMove` (`move.go:344-554`) + `movestate.go`: reserve on the destination before any host is touched (resume only with a token the caller holds: local move-state file or `--resume-token`), `renew` around the final backup and between the long steps, commit after the restore check and first backup, retire just before the switch; rollback with the token on any failure before the commit (ownership confirmed first, unforced `DELETE`, target down, source restarted), `--recover` after it, and a takeover or unconfirmable ownership stops the move with both hosts untouched. `moveWarning` and its test deleted; the help text and `move.go`'s head comment describe the steps | `flakes/fleet-agent/internal/containers/{move.go,movestate.go,movestate_test.go,move_test.go,main.go,transfer_test.go}`, `containers/{README.md,PLACEMENT-PLAN.md}` | High: irreversible step, so the order is the design. Dry-run prints the same steps without touching the registry; the recorded path, the rollback, the takeovers, the resume and the refusals each have a test against a fake registry |
| **4a (implemented, not deployed)** | Non-HTTP public routes follow placement: o002 stream receiver, boot seed/expire and timer; h005 validated atomic WAN forwarding; stream/WAN audit | `flakes/fleet-edge/internal/{edgestream,wanforward,reconcile}`, CLI audit, receiver and host Nix modules, `containers/lib.nix`, `containers/tests/edge-streams.nix` | Deploy h005 first (old receiver fails closed), then o002 (seed avoids a gap). Verify `git ls-remote ssh://git@git.joshuabell.xyz:3032/<repo>` before and after deployment and a test move |
| **5** | Nix stops declaring placement: remove the `host` line from all 20 `service.nix` files (19 name a host, `minecraft` is `null`) and the `host = null` default in `lib.nix`, delete the functions in §4, delete the stale `computerboyz`/`minecraft` hand DNS, runtime firewall allowlist (with `fw-narrow`), cert targets pinned | `containers/*/service.nix`, `containers/lib.nix`, `containers/host-module.nix`, `containers/flake.nix` inventory, `hosts/h005/{dns-records,wildcard-cert}.nix`, `containers/tests/edge-vhosts.nix` | High, and the point of no return; done last so every reader already ignores the field |
| **6** | Docs: `containers/README.md`, `containers/minecraft/README.md` (drop the "point computerboyz / set host" move instructions), `ROUTING-PLAN.md` (§5.2 table, §5.3, §8 step 9, the §8 step 4 "no runtime path" paragraph), `flakes/fleet-edge/README.md` | docs | Low |

Each phase is one deployable cutover: phase *n* leaves the tree working with
every caller migrated, and no phase adds a field or an alias that a later phase
has to remember to delete. 4a is separate from 4 because it touches the public
edge and can land before or after the move rebind, but not during one.

## 10. Open items

- **Split brain** is reported, never resolved. Deciding which copy to keep is a
  human call (`cnt place --host`, `force`).
- **`dataRoot` is per host**, not shared, so a placement is not a lease: two
  hosts can both hold valid data dirs after a failed move. The registry's job is
  to say which one is *authoritative*, not to clean up the other.
- **`net.uses` across hosts** (`callerIPs`, `routes.go:1178`) compares two
  registry hosts (`resolvedHost`), so a same-host pair keeps the
  private-network path and a cross-host pair gets the overlay allow — but only
  the *next* deploy of either service picks up the change. `cnt audit` flags
  the drift in between.
- **No `enabled` flag, by design.** An unplaced service *is* the offline state:
  no row, nothing routed, nothing named. `minecraft` needs no encoding beyond
  that (`host = null` becomes "no row"), and the import adopts only a copy that
  is installed **and** active, so the stale unit left from its last run is
  skipped with a printed reason rather than resurrecting a placement. Decided;
  nothing left to choose in phase 2.
- **Restore** (`cnt restore <svc> <file>`) writes data on a host; it must target
  the bound host, and it already refuses when the copy is running there.
