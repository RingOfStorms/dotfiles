# Service placement: where a floating container runs

Design for removing `host` from `service.nix`. Today 19 of the 20
`containers/<svc>/service.nix` files name the host they run on (17 on h001,
`localai` on joe, `hello-podman` on lio; `minecraft` is `host = null`, inactive,
which is already the shape the registry wants: *no row*), and six Nix functions
(`edgeRoutes`, `edgeVirtualHosts`, `routeNamesByHost`, `httpExposureByHost`,
`dnsRecords`, `routerForwards` — all in `containers/lib.nix`) derive network
state from that one string. That makes Nix the runtime answer to "which box runs
X", which is wrong: placement changes on a `cnt move`, and a Nix string that must
be edited, committed, rebuilt and pushed afterwards is a shadow copy that is
either stale or a source of silent mistakes.

Target: **Nix describes what a service is; h005 describes where it runs.**
Placement is runtime state, recorded in one registry, and everything that must
follow it (DNS, o002 vhosts, firewall admission, the CLI's own guessing) reads
that registry instead of a Nix attribute.

Status: **phase 1 done** (registry + API + unit wiring). Phases 2–6 below.

---

## 1. The registry

`flakes/fleet-edge/internal/placements`, served by the existing
`fleet-edge-overrides` unit on `127.0.0.1:8098` (same listener as
`internal/overrides`, mounted on one `http.ServeMux` in `main.go`).

State: `/var/lib/fleet-edge-overrides/placements.json` (0600, written atomically
under a mutex) and `placements-audit.log` (one JSON line per request, refusals and
rate-limited calls included). Same `StateDirectory` as the expose authority: both
are h005-local runtime state owned by the same DynamicUser, and no other process
opens the files — the dashboard (and, in phase 3, the reconciler) read the
loopback export over HTTP, the same way `--overrides-url` already works
(`main.go:55`).

Callers authenticate exactly like `cnt expose` (`internal/authority`): a Zitadel
machine token whose `sub` is in `fleet.global.overrideWriters`
(`hosts/fleet.nix:54-59`), sent from that host's overlay IP through h005 nginx
(`/api/placements`, deny o002, `X-Fleet-Peer` set from the loopback trusted peer).
Writers are per-host, so `Row.Device` is the host that made the change; that is
the whole point of the machine-identity scheme. Today only lio/juni/gp3/oren are
writers, of which just `lio` is a container host; phase 2 adds h001, h003 and
`joe` — all three already run sec-agent (`hosts/joe/flake.nix:118`), so they
have a machine key. The writer set has to be complete *before* phase 3, because
a host that cannot write a placement also cannot close its own firewall rule.

### Row shape

| Field | Meaning |
|---|---|
| `service` | inventory service name (`containers/<svc>/service.nix`) |
| `host` | destination: where it should run |
| `state` | `prepared` \| `committed` \| `retiring` |
| `previous` | the prior binding, kept for rollback |
| `device`, `user`, `reason` | who and why |
| `created`, `updated`, `reserveSince` | timestamps (`reserveSince` = reservation start) |
| `hostMissingSince`, `conflict`, `lastError` | sweep observations, never auto-resolved |

`Row.Effective()` is the single reader-facing answer: a `prepared` row still
serves from `previous` (a move in flight), a `committed` row serves from `host`,
a `prepared` first placement serves nowhere. `GET /internal/placements.json`
exports `{rows, host: {svc: host}, conflicts}` so a reader never replays the state
machine.

### API

| Call | Effect |
|---|---|
| `POST /api/placements/import` | one-time bootstrap: adopt observed placements, skip existing rows unless `force` |
| `POST /api/placements/reserve` | record destination + previous; nothing routed to it yet |
| `POST /api/placements/commit` | routing now points at the destination; destination must report the service |
| `POST /api/placements/retire` | the source is being uninstalled; rollback now needs `force` |
| `DELETE /api/placements/<svc>[?force=1]` | rollback: restore the prior binding, or drop a first placement |
| `GET /api/placements[?verify=1]` | rows + effective hosts (+ live per-host verification) |

Refusals carried over from the CLI's old `checkPlacement`/`moveSource` logic:
unknown service, host that is not a container host, a move whose destination
already runs the service (a second copy would split it, `force` when that copy is
the one to keep), commit before the destination reports the copy, and a rollback
onto a source that was retired (`cnt move` renamed its data).

### Sweep (30 s)

- A reservation older than `ReserveTTL` (30 min) rolls back to `previous` — this
  is the "the move never cut over" case, and the reason rollback is free.
- A reachable destination that stops reporting the service → `hostMissingSince`
  + `lastError`. Not deleted, no grace: a stopped copy is not a lost placement.
- Any *other* host reporting the service → `conflict`. Never resolved
  automatically; `cnt place --verify` and the dashboard surface it.
- A non-prepared row whose `previous` host stops reporting → `previous` cleared,
  the move is complete.
- An unreachable host changes nothing (silence is not absence).

---

## 2. Move ordering (this is the part the old design got wrong)

`switchScript` (`flakes/fleet-agent/internal/containers/move.go:288-294`)
uninstalls the source and renames its data to `<dir>.moved-<date>`. The commit
therefore has to land **before** that rename (step 9 below), not after it: once
the data is renamed, rollback can no longer just point back at the source. That
is the bug in the old design, which wrote the repo after the switch. The registry
splits the old "update the repo after the move" into two calls, both on the safe
side of the irreversible step (today's `1/7`…`7/7` labels map to 1, 3–6 and 9
below):

```
1 preflight (target, source)                      ─ unchanged
2 RESERVE destination            ← registry: previous = source, state = prepared
                                   (effective host is still the source: DNS and
                                    o002 keep pointing at it)
3 final backup on source, stop                    ─ unchanged (source stopped, data intact)
4 restore snapshot + live DB clusters on target    ─ unchanged
5 deploy + route health on target                  ─ unchanged
6 restore check, first backup on target            ─ unchanged
7 COMMIT                         ← registry: published host = destination. h005's
                                   reconciler writes DNS and the o002 vhost on its
                                   next pass (phase 3; until then the Reconcile
                                   step does not exist and this is just the flip).
                                   `cnt move` then polls `GET ?verify=1` until the
                                   destination reports `ok` and no host reports a
                                   stray copy. That endpoint validates *what the
                                   hosts run*, not DNS: name resolution is checked
                                   by `cnt audit` (phase 3) against the same
                                   registry. On timeout the source is untouched, so
                                   `DELETE` rolls back.
8 RETIRE source                  ← registry: rollback now needs force
9 uninstall source, data → .moved-<date>           ─ switchScript, unchanged
   (sweep clears `previous` once the source stops reporting the service)
```

Any failure before step 7 is undone by redeploying the target down and restarting
the stopped source, then `DELETE /api/placements/<svc>` — which restores the
*prior* binding, it never invents or deletes one. A failure between 7 and 8 (a
rollback the operator wants) is `DELETE` plus restarting the source: the source
copy is intact because step 9 has not run. After 8 only `force` applies, and the
printed recovery is the same one `move` prints today.

Why this order and not the reverse: routing must never point at a host that has
not proven it can serve the data, and the source must never be destroyed before
routing has demonstrably moved off it. Reserving early is what makes the DNS half
of the cutover a flip rather than a guess, and makes an abandoned move
self-healing after 30 minutes.

A move no longer needs `moveWarning` and the "update `host =` in service.nix"
step: the reservation *is* the record, and the only remaining must-do is
`cnt place --verify` / `cnt audit` finding nothing.

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
- **The o002 non-HTTP stream and WAN forwards**: `routerForwards`
  (`containers/lib.nix`, consumer `hosts/h005/router-forwards.nix:23`)
  evaluates to **`[]` today** — evaluated, not assumed: the only
  `via = [ "router" ]` route in the tree is minecraft's 25565
  (`containers/minecraft/service.nix:32`), and the function skips `host = null`
  services, so the list is empty while minecraft is inactive. Forgejo's SSH
  :3032 is `via = [ "edge" ]` and is *not* generated at all: o002's
  `streamConfig` (`hosts/oracle/o002/nginx.nix:196-201`) hard-codes
  `${upstreamHost}:3032` with `upstreamHost = "100.64.0.13"` (h001,
  `hosts/oracle/o002/_constants.nix:16`). Both become one hand-kept list in
  `hosts/h005/router-forwards.nix` with an explicit `host` field — a DNAT is a
  WAN decision with a hand-checked port, and it will be at most two entries, not
  a derivation.

**Becomes runtime** (recorded in the registry):

- Which host runs a service.
- The tailnet/LAN DNS answer for every route name (host overlay/LAN IP).
- The o002 vhost target for every `public` + `via = edge` route.
- `:80`/`:443` admission on the host that received the placement (firewall).
- The CLI's resolution of "the host" for every command.

---

## 4. Consumer inventory (break + change per consumer)

Derived-from-`s.host` Nix functions and their call sites:

| Consumer | Site | Phase | Change |
|---|---|---|---|
| `edgeRoutes` | `lib.nix`, filtered by `r.service.host != null` | 5 | Delete; o002 vhosts come from the runtime reconciler |
| `edgeVirtualHosts` | `lib.nix`, called `hosts/oracle/o002/nginx.nix:23`; eval test `containers/tests/edge-vhosts.nix` | 5 | Delete (and the eval test). o002 gets a reserved-name list + the existing `edgevhost` receiver |
| `routeNamesByHost` | `lib.nix`, called `hosts/h005/wildcard-cert.nix:37` (`routeHosts`) | 5 | Delete. Every route name is a single label under `*.${domain}`, so the cert needs no per-name SAN and the push target set becomes the static container-host list |
| `httpExposureByHost` | `lib.nix`, called `containers/host-module.nix:31` | 5 | Delete; runtime firewall allowlist (see §7) |
| `dnsRecords` | `lib.nix`, called `hosts/h005/dns-records.nix:12` → `hosts/h005/mods/networking.nix:22`; consumed at `:44` (`host-record`, tailnet), `:49` (`local=`, tailnet) and `:249` (`host-record`, LAN) | 3,5 | Phase 3: h005 writes per-name files into **two** runtime `hostsdir`s (`tailnet/`, `lan/`) from the registry; the `host-record` lines go away, the `local=` does not. Phase 5: **not** deleted — drop the `s.host != null` filter and the IP fields, keeping the `local=` name list and the `public` CNAME list |
| `routerForwards` | `lib.nix`, called `hosts/h005/router-forwards.nix:23` | 5 | Becomes a hand-kept list with explicit hosts |
| o002's `streamConfig` | `hosts/oracle/o002/nginx.nix:196-201` proxies :3032 to `_constants.nix:16` `upstreamHost = "100.64.0.13"` (h001), not to a route's host | 5 | Forgejo's SSH route is `via = edge`, `proto = tcp`; the stream has to follow placement. Either drive it from the registry or move :3032 to a router forward with an explicit host. Left alone it keeps working only while forgejo is on h001 — a `move` breaks SSH silently, with no Nix-level trace |
| `DeclaredHost` | `flakes/fleet-edge/internal/state/state.go:666`, `polls[svc.Host]` at `678`; `server/server.go:355` (sort), `564` (host detail); `dash/dash.go:158,189,225-231`; `topology/layout.go:170` | 2,5 | Rename to the registry's effective host (`BoundHost`), fed by the export; group/sort by it; a service with no row is "unplaced" |
| CLI `hostFor` | `fleet-agent/internal/containers/main.go:485` | 2 | `--host` > registry row > discovery (`deploy/start/destroy` matrix, §6) |
| CLI `hostForRead` | `main.go:506` | 2 | Same, but `installedHere` stays the cheap local shortcut |
| CLI `containerHosts` | `main.go:534` | 2 | Drop the "plus every declared host" loop; the set is `containerHosts` from the inventory |
| CLI `locate` | `main.go:554` | 2 | Kept as the discovery fallback and for `place --verify`; never the primary answer |
| CLI `checkPlacement` | `main.go:590` | 2 | Delete; the registry refuses the conflicting writes itself |
| CLI `moveSource` | `main.go:1368` | 4 | Read `row.Effective()` |
| CLI `moveWarning` | `main.go:1349`, printed `move.go:451` | 4 | Delete |
| CLI `ls` drift note | `main.go:788-804` (`!! declared … set host = …`) | 2 | Show `registry` vs `observed` and flag a mismatch as drift to fix with `cnt place` |
| CLI `status` banner | `main.go:1681` (`declared: %s`) | 2 | Show the bound host and, when they differ, the observed host |
| CLI `move` source pick | `move.go:333` (`from = s.Host` dry-run fallback) | 4 | `row.Effective()` |
| CLI `backendOf` | `port.go:189` (filters `s.Host != host`) | 2 | Take the effective host per service |
| CLI `routes` overrides fetch | `routes.go:460-461`, table `495,498,619` | 2 | Same, via the effective host |
| CLI `callerIPs` | `routes.go:891-915` (`c.Host == s.Host` decides same-host private network) | 2,4 | Both sides resolved through the registry; `net.uses` between two services on the same host keeps the `10.233.0.1` path |
| CLI `expose` | `expose.go:353,382` | 2 | `hostFor` → registry |
| Dashboard services page | `server/templates/services.html:24-31` | 2 | Header per bound host; an unplaced service under "unplaced" |

Every one of these has a test that pins `s.Host`; those tests either gain a fake
registry client or move to the phase that deletes the field.

## 5. Where the reconciler lives

Phase 3 adds one loop to the same `fleet-edge-overrides` unit (it already owns
the state dir, the sweep and the local secrets), fed by the registry export and
the inventory's declarative routes:

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
  - Only the IP half moves. `local=/<fqdn>/` lines carry no address, so
    `dnsRecords` keeps generating them; they exist only on the **tailnet**
    instance (`networking.nix:49` maps `dnsRecords.tailnet`) — the LAN instance
    answers from `host-record` and `server=` with no `local=` at all. A name with
    `local=` plus a `hostsdir` entry answers locally instead of following the
    public CNAME chain (verified: A answered, AAAA `NOERROR`/empty), which is why
    `local=` must survive the removal of `host-record`. Phase 5 therefore does
    not delete `dnsRecords`: it drops the `s.host != null` filter and the
    address fields, leaving the `local=` name list and the `public` CNAME list.
  - Of the three lists `dnsRecords` returns, only `tailnet` (every non-local
    route → overlay IP, 25 names today) and `lan` (lan+public routes → LAN IP,
    13 names, only hosts that have one) depend on placement. `public` (13) is
    the same set as `lan` and targets `o002`/`home` regardless of host, so the
    bunny `publicSpec` needs the route *set* and nothing else — which is why
    `dns-plan` stays a declarative reconcile and never reads the registry for a
    target.
  - The LAN instance keeps its current shape — no `local=`, `server=` fallthrough
    for everything not in a file — so nothing about LAN AAAA behaviour changes
    in this phase.
  - This reverses the "No runtime path" call recorded in
    `ROUTING-PLAN.md:739-745` — the same paragraph already names this extension
    ("Revisit with `cnt expose`/`move` … where a hostsdir fed by fleet-edge is
    the natural extension"). That decision assumed records change only when a
    `service.nix` changes, which is exactly the assumption the registry removes.
  - Ordering is add-before-remove with one file per name and no directory-wide
    rewrite, so a pass that dies halfway leaves the previous answers in place
    for every name it did not reach.
- **o002 vhosts**: for each `public` + `via = edge` route whose service has an
  effective host, send the existing runtime receiver
  (`internal/edgevhost.Request{Op: "add", FQDN, Host, Until: 0, MaxBody,
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
- A route that loses its placement, or drops to a non-`public` exposure, gets
  `Op: "remove"` and a reload. The push order is add-before-remove, and a host
  that stops answering never causes a removal — the host's own edge listener
  already fails closed to 444, so an unreachable host leaves a vhost that
  returns 502 (visible to `cnt audit`) rather than deleting state on a guess.
- **Reload debt** is already tracked by the receiver's `.reload-pending` marker
  and retried (`edgeReloadPending`); the placement loop reports through that
  marker instead of adding a second one. `dns-plan`/`publicSpec` is unchanged:
  public records CNAME `o002`/`home` regardless of host, so the bunny side needs
  no placement input at all.

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

- `cnt place` shows rows, `--verify` shows live per-host state, `--set <svc>
  --host <h>` records a first placement, `--import` is the one-time bootstrap
  (below). `cnt move` calls reserve/commit/retire itself.
- `cnt deploy` on a service whose registry host is not the host it deployed to is
  a bug in the CLI, not a user error: it resolves once, then uses that string.
- **Add `joe` to `containerHosts` in phase 2, not phase 5.** Today the CLI's
  `containerHosts()` adds every declared `s.Host`, which is the only reason
  `localai` (declared `host = "joe"`) is discoverable at all. Once the field is
  gone the probe set is exactly `inv.ContainerHosts`, so a host that only ever
  held one service would silently disappear from discovery. The registry's own
  probe set (`statuses`, `placements.go:577`) has the same shape and would
  miss it for the same reason during the bootstrap import.

## 7. Firewall and certificates

- **Firewall**: do not open `:80`/`:443` on every container host. Today
  `host-module.nix` derives its `extraInputRules` from `httpExposureByHost` in
  `lib.nix`, i.e. from `s.host`; after phase 5 that input is gone, so the rules
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
  `h001`/`h003`/`lio` are `containerHosts`, `joe` becomes one in phase 2,
  `o002` is the public edge. Push behaviour is unchanged (no name gains or loses
  a target), and a host that has never served a route can still terminate TLS
  before the first `move` lands there.

## 8. Bootstrap and migration

1. Turn on the unit with the registry empty (nothing reads it yet).
2. Discovery import: for each inventory service, probe every container host and
   import the single running copy (`POST /api/placements/import`).
   Services with no copy, or with two, are printed and left unplaced for a human
   — the import refuses to guess, and never suggests a host from Nix.
3. Only once the registry matches reality do phases 2–5 flip their readers.

There is no path that seeds the registry from `service.nix`. That is the point:
a Nix seed would re-create the shadow copy the design removes.

## 9. Phases

| Phase | Scope | Files | Risk |
|---|---|---|---|
| **1 (done)** | Registry: rows, state machine, sweep, API, loopback export, auth, audit; shared writer auth in `internal/authority`; one listener in `main.go`; flake option text; h005 `/api/placements` nginx location | `flakes/fleet-edge/internal/{authority,placements}/*`, `internal/overrides/overrides.go`, `flakes/fleet-edge/{main.go,flake.nix}`, `hosts/h005/fleet-edge.nix` | None: nothing reads the registry yet |
| **2** | Read paths: CLI resolution (`hostFor`, `hostForRead`, `containerHosts`, `checkPlacement`, `backendOf`, `routes.go`, `expose.go`, drift/status output), dashboard grouping, `overrides.Check`; add h001, h003 and `joe` to `overrideWriters`; add `joe` to `containerHosts`; discovery import command (`cnt place`) | `flakes/fleet-agent/internal/containers/{main.go,move.go,port.go,routes.go,expose.go}`, `flakes/fleet-edge/internal/{overrides,state,server,dash,topology}`, `hosts/fleet.nix`, `containers/flake.nix` | Medium: a wrong resolution starts a second copy; the refusals above are the guard. CLI tests cover the matrix |
| **3** | Reconciler: two DNS `hostsdir`s (tailnet overlay IPs, LAN IPs) written from the registry export, o002 runtime vhosts, `dns-plan` keeps its declarative input (only the CNAME *set* follows the registry) | `flakes/fleet-edge/internal/{reconcile,dnsplan,server}`, `hosts/h005/{dns-records.nix,mods/networking.nix}`, `hosts/oracle/o002/nginx.nix` | High: DNS and o002 are shared. Fail-closed ordering (add before remove, keep the old answer when a host is unreachable) and `cnt audit` checks |
| **4** | Move rebind: reserve → … → commit → retire, rollback, expired-reservation recovery; delete `moveWarning` and the `host = %q` message | `flakes/fleet-agent/internal/containers/{move.go,main.go}`, tests | High: irreversible step. Dry-run prints the same 9 steps; every failure path has a test |
| **5** | Nix stops declaring placement: remove `host` from the 20 `service.nix` files and the `host = null` default in `lib.nix`, delete the functions in §4, runtime firewall allowlist (with `fw-narrow`), cert targets pinned, o002's :3032 stream given an explicit host | `containers/*/service.nix`, `containers/lib.nix`, `containers/host-module.nix`, `containers/flake.nix` inventory, `hosts/h005/{dns-records,router-forwards,wildcard-cert}.nix`, `hosts/oracle/o002/{nginx,_constants}.nix`, `containers/tests/edge-vhosts.nix` | High, and the point of no return; done last so every reader already ignores the field |
| **6** | Docs: `containers/README.md`, `ROUTING-PLAN.md` (§5.2 table, §5.3, §8 step 9, the §8 step 4 "no runtime path" paragraph), `flakes/fleet-edge/README.md` | docs | Low |

Each phase is one deployable cutover: phase *n* leaves the tree working with
every caller migrated, and no phase adds a field or an alias that a later phase
has to remember to delete.

## 10. Open items

- **Split brain** is reported, never resolved. Deciding which copy to keep is a
  human call (`cnt place --host`, `force`).
- **`dataRoot` is per host**, not shared, so a placement is not a lease: two
  hosts can both hold valid data dirs after a failed move. The registry's job is
  to say which one is *authoritative*, not to clean up the other.
- **`net.uses` across hosts** (`callerIPs`, `routes.go:891`) currently compares
  two Nix hosts. After phase 2 it compares two registry hosts, so a same-host
  pair keeps the private-network path and a cross-host pair gets the overlay
  allow — but only the *next* deploy of either service picks up the change.
  `cnt audit` flags the drift in between.
- **"Inactive" loses its encoding.** `minecraft` is off today via `host = null`
  plus a comment (`containers/minecraft/service.nix:9-11`); the CLI refuses to
  act on it without `--host`. Once the field is gone, that state *is* "no row",
  which is also what a brand-new service looks like. The behaviour is the same
  (mutating commands demand `--host`, readers print it as unplaced), so nothing
  breaks — but `cnt place` has nowhere to say "this one is deliberately off,
  don't import it". Either leave it implicit or add an `inactive` flag to the
  row; decide in phase 2, before the import runs, since the import would
  otherwise adopt a stale copy on whatever host still has the data.
- **Restore** (`cnt restore <svc> <file>`) writes data on a host; it must target
  the bound host, and it already refuses when the copy is running there.
