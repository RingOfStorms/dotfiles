# fleet-edge

Fleet dashboard, host health/metrics monitor, and h005's routing authority:
the placement registry, `cnt expose` overrides, and the reconciler that
keeps DNS, the o002 edge and the WAN forwards in line with where services
run. Packaged like `flakes/ports` (stdlib Go, no external Go deps, `go1.22`,
runtime `sqlite3` for time-series storage), with a NixOS module.
`MONITORING-PLAN.md` covers the monitoring roadmap.

One binary, `fleet-edge`, runs as several processes:

| Command | Runs on | Role |
|---|---|---|
| `fleet-edge` (no subcommand) | h005, `fleet-edge.service` | dashboard and poller (below); backup edits go through `/backup/` on `overrides` |
| `fleet-edge overrides` | h005, `fleet-edge-overrides.service` | placement registry, expose overrides, routing reconciler ([Routing authority](#routing-authority-fleet-edge-overrides)) |
| `fleet-edge dns-plan [--apply]` | h005, by hand | diff (and apply) the bunny zone against `dns-records.nix` `publicSpec` |
| `fleet-edge forwards-apply` | h005, root | install the reconciler's WAN forwards as `table ip fleet-wan-forwards` |
| `fleet-edge vhost-receive` / `vhost-expire` | o002, ssh forced command / timer | runtime edge vhosts in `/var/lib/fleet-edge-vhosts` |
| `fleet-edge stream-receive` / `stream-expire` | o002, ssh forced command / timer / boot | runtime TCP streams in `/var/lib/fleet-edge-streams` |
| `fleet-edge share-serve` / `share-apply` / `share-sweep` | o002 | `*.share` temporary sharing (`hosts/_shared_assets/utilities/share-receiver.nix`) |
| `fleet-edge import-beszel` | by hand | import historical Beszel metrics |

## Alerts and TLS expiry

Alerts go to ntfy. `services.fleet-edge.alerts.ntfyUrl` (CLI `--ntfy-url`,
environment `FLEET_EDGE_NTFY_URL`) is the complete ntfy topic URL; empty
disables sends, so alerts are opt-in per deployment.
`alerts.healthDownMinutes` defaults to 5.

Every minute, placed services are checked for a backup stamp older than 36h,
continuous non-active/unknown status or failing declared HTTP health endpoints,
and served HTTPS leaf certificates expiring in under 14 days. Missing backup
stamps get a 36h observation grace. `/services` shows certificate expiry and
probe errors even with notifications disabled. TLS inspection sends no app
credentials and intentionally reads expired/untrusted leaf certificates.
The monitor sends one notification per open condition, clears it on recovery,
and stores de-duplication state in the metrics SQLite DB (memory only with
`dbPath = ""`). Failed deliveries are retried; no repeated reminder spam.

LAN DNS incorporates unexpired LAN exposure overrides reported by the current
placement host; expiry/revoke removes that extra answer, and moves change its
address. Unknown host status keeps the last LAN answer. Public login routes
carry `loginPaths` to o002; exact case-insensitive endpoints retain normal proxy
settings plus global and strict login zones, 429 responses and fail2ban logs.

## Dashboard

- Reads a static inventory JSON file (the same shape the `containers` CLI
  produces via `nix eval --json <containers-flake>#inventory`:
  `services`, `hosts`, `containerHosts`). `routes` on a service is
  optional; when present, several fields (`name`, `fqdn`, `url`, `auth`,
  `health`) are nullable (e.g. on `tcp`/`udp` routes with no HTTP name),
  and `via` is a **list** of strings (e.g. `["edge"]`), not a single
  string. A missing `routes` map is treated as empty, never an error.
  The inventory carries no placement.
- Reads service-to-host bindings from the placement registry's loopback
  export (`--placements-url`, default
  `http://127.0.0.1:8098/internal/placements.json`). A service the registry
  does not bind is **unplaced**; an empty URL or an unavailable registry
  leaves every service unplaced rather than guessing.
- Polls each host's status endpoint (see contract below) every 30s with a
  3s timeout, tolerating failures. A host that can't be reached (timeout,
  refused, bad JSON) is recorded as unreachable; every service bound to
  that host shows `unknown` state rather than failing the page.
- Stores 30s time-series samples (`host_samples`, `fs_samples`), offline host
  snapshots (`host_last_state`), and host lineage events (`host_events`) in a
  SQLite WAL database (`/var/lib/fleet-edge/metrics.db`) with automatic 5m and
  1h rollups, plus `fleet-edge import-beszel` for migrating historical Beszel
  databases (including `h002` -> `h004` host replacement lineage).
- Authenticates requests via Zitadel OIDC Authorization Code + PKCE (`admin`
  role claim, `fleet_session` HMAC cookie) or `Bearer` / `X-API-Key` tokens.
  Auth is on when OIDC is (issuer **and** client ID set) or when any API key
  exists; with neither, the middleware is a no-op and everything is open —
  the deployment's nginx ACL is then the only gate. `--session-key-file` is
  optional: without it the HMAC secret is random per process, so every
  restart ends the browser sessions. `/healthz`, `/auth/login`,
  `/auth/callback` (also `/callback`), and `/auth/logout` are exempt from the
  session check; other `/auth/*` paths are not. GET/HEAD requests for the
  install manifest and its two icons are also exempt (see below). h005
  enables Zitadel with the `admin` role; dashboard pages, APIs, and all other
  static assets still require a session or API key.
- Serves, on `--listen` (default `127.0.0.1:8099`, behind nginx on `h005` at
  `https://fleet.joshuabell.xyz`):
  - `GET /` — start page of app tiles.
  - `GET /services` — every service grouped by its bound host (unplaced
    services last): polled state, backup age, routes, description, and the
    expose overrides.
  - `GET /hosts` — Fleet Health Overview split into Always-On Servers and
    Workstations & Laptops (`ONLINE` / `SLEEP` / `DOWN`), with 24h CPU & Net
    sparklines, bcachefs usable vs. raw storage bars, SMART, Fail2ban, and
    container badges.
  - `GET /hosts/{name}?range=1h|24h|7d|30d|1y` — Per-host drill-down with
    inline SVG time-series charts, bcachefs pool/device breakdown, SMART drive
    table, Fail2ban jails & banned IPs, and live systemd/container log viewer
    (proxying `:9101/logs.json`).
  - `GET /healthz` — `ok` (unauthenticated).
  - `GET /api/state.json` — the merged view as JSON.

### Install on a phone

After deploying Fleet Edge, open `https://fleet.joshuabell.xyz/` in Chrome,
sign in, then choose **Add to home screen → Install** (wording varies by
Chrome version). Use a normal tab, not Incognito. Installation needs a
trusted HTTPS connection; an HTTP LAN address or certificate-warning
bypass is not sufficient. Localhost is suitable for development checks.

The shared page head advertises `/manifest.webmanifest`. It uses the
configured dashboard title, a stable root app ID, root start URL/scope,
and standalone display. Embedded `/static/icon-192.png` and
`/static/icon-512.png` are PNG icons with maskable-safe artwork. These
three exact resources allow anonymous GET/HEAD so installers can fetch
them without a session cookie; they contain no inventory or user data.
Launching the installed app still requires the normal login and network
access (including the tailnet wherever required).

There is no service worker or offline dashboard cache. Current Chrome
[supports menu installation without a service worker](https://developer.chrome.com/blog/update-install-criteria).
This avoids persisting private fleet pages or displaying stale health
data offline. If installation remains unavailable after deployment,
reload the page and check Chrome DevTools **Application → Manifest** for
manifest/icon errors and verify the HTTPS certificate is trusted.

## Routing authority (`fleet-edge-overrides`)

`fleet-edge overrides` is a separate unit (its own DynamicUser, listening on
`127.0.0.1:8098`, keys via `LoadCredential`) so the dashboard process never
holds the bunny or ssh push key. h005 nginx proxies `/api/overrides` and
`/api/placements` to it from overlay addresses (o002 denied) and sets
`X-Fleet-Peer`; `/internal/*.json` exports stay loopback-only. State lives in
`/var/lib/fleet-edge-overrides` (persisted).

**Callers.** Every write carries a Zitadel machine token whose `sub` is in
`services.fleet-edge.overrides.writers` (from `fleet.global.overrideWriters`)
and must arrive from that writer's overlay IP (`internal/authority`). Writers
are per host, so a row records which device changed it. Every request,
refusals included, is a line in the audit log.

**Expose overrides** (`internal/overrides`): `cnt expose` raises a route's
exposure for a while. A public override is applied in a fixed order: the
request is validated against the built-in inventory and `publicSpec` and
reserved, the service host must report the public override in its status,
then h005 creates the bunny CNAME (TTL 60) and finally pushes the o002 vhost.
Removal runs the other way: o002 vhost, then the CNAME (deleted by record id
only while name, type and value still match), then the row. `--for`
defaults to **8h**; any duration is allowed, and `--for forever` means no
expiry. There is no cap on the number of overrides; the only throttle is a
per-host write limit of **30 writes per 10 minutes** (then 429 with
`Retry-After`; reads are never limited), shared with the placement API.
h005 owns expiry: a **30 s sweep** (also at startup) removes expired rows
(o002, then DNS), retries rows stuck in `removing`, and re-pushes live rows.
Expose vhosts carry the global edge rate limit on the whole server.

**Placement registry** (`internal/placements`): which host runs each
service. `placements.json` holds the rows and a registry-wide `revision`
counter. A row is `prepared` (a move reserved it), `committed`, `retiring`
(the source is being uninstalled) or `stale` (a reservation whose
**30-minute lease** expired; `cnt move` renews the lease as it advances, so
a slow move does not go stale). `GET /internal/placements.json` exports
`{rows, host, conflicts}`, where `host` is each service's effective host and
an absent entry means unplaced. The API (`/api/placements`): `import`,
`reserve`, `commit`, `retire`, `renew`, `recover`, `DELETE <svc>` (rollback),
`GET [?verify=1]`, and `GET /api/placements/routing` for the audit. A 30 s
sweep observes the hosts' status endpoints. See [Design notes](#design-notes)
for the rules.

**Reconciler** (`internal/reconcile`): runs at startup, every 30 s and after
every registry write, and makes these follow the effective hosts:

- **Tailnet and LAN DNS**: one `<ip> <fqdn>` file per route name in
  `/var/lib/fleet-edge-dns/tailnet/` (overlay IPs) and `.../lan/` (LAN IPs),
  read by h005's two dnsmasq instances as `hostsdir`s. Both instances keep
  `local=/<fqdn>/` for every inventory route name, so an unplaced name has
  no answer rather than a public one.
- **o002 vhosts**: each `public` + `via = edge` http route of a placed
  service is pushed as a `kind: placement` request to o002's vhost receiver
  (`proxy_pass http://<overlayIp>:8443`, the wildcard cert, the route's
  body/buffering/timeout/websocket settings). Placement vhosts have no expiry
  and no server-wide rate limit: they rely only on the global zone and the
  strict login zone on the route's `loginPaths`, plus o002's fail2ban login
  jails.
  The login log is pre-created by tmpfiles (`nginx:nginx 0640`) before nginx
  and fail2ban starts, including switches. Vhost, stream, share and certificate
  receiver config tests run as nginx so a missing log cannot become root-owned.
  Login jails use the file-polling backend: `fleet-login-arr` protects Jellyfin;
  `fleet-login-immich`, `fleet-login-vaultwarden` and `sshd` complete the intended list.
- **o002 streams**: each `public` + `via = edge` + `proto = tcp` route
  (forgejo ssh :3032) is pushed to o002's stream receiver, which writes
  `/var/lib/fleet-edge-streams/<port>.stream`
  (`server { listen <port>; proxy_pass <overlayIp>:<port>; }`). o002's
  firewall admits the port declaratively (`edgeStreamPorts`); only the
  destination is runtime. Eval assertions on o002 require every stream port
  in `allowedTCPPorts` and reject 80, 443 and 22. Streams go through the edge
  rather than a router forward because o002 already is the public address
  for these names: a DNAT would move the port's public identity to whichever
  home host holds the service and expose the home IP, while the stream lets
  forgejo move (or h001 be reinstalled) without touching the router or the
  service's Nix.
- **WAN forwards**: each `public` + `via = router` tcp/udp route of a placed
  service is written to `/var/lib/fleet-edge-forwards/forwards.json`. Root's
  `forwards-apply` (path unit, nftables start/reload hooks) validates it
  against the inventory, derives LAN IPs, and replaces
  `table ip fleet-wan-forwards` in one `nft -f` under flock. Forwards are
  IPv4 only and there is no hairpin NAT (LAN clients get the LAN answer from
  h005's DNS instead). They fail closed: a missing file is an empty table, an
  unplaced service has no forward, and invalid data leaves the applied table
  unchanged and exits nonzero.
- `cnt audit` prints `GET /api/placements/routing`: file contents, live A
  answers from both dnsmasq listeners, o002's vhost and stream lists, and the
  written vs applied forwards.

**Public DNS** (`internal/bunny`, `dns-plan`): `hosts/h005/dns-records.nix`
`publicSpec` declares names; effective registry placement filters service
membership in the desired zone. Only h005 holds the bunny key. `dns-plan`
reports create / update / keep / conflict / dynamic / unmanaged (plus
retire, retire-mismatch and override); dynamic records are the DDNS-managed
ones (`home`, from the router's WAN IPv4) that `dns-plan` never writes; `--apply`
executes only create/update rows and exact-match retires, refuses the whole
run on any conflict, and never deletes a record the spec does not own.

### Backup policy editor (`/backup/`)

`fleet-edge overrides --backup` serves the backup policy API
(`/api/backup`, containers/BACKUP-PLAN.md §2.3) and, on the same loopback
listener, a plain-HTML editor at `/backup/` (`internal/backupui`): per
subject a target select (registered targets plus `none`), local and B2
preset selects, an offsite toggle (disabled with the reason unless the
target is a pusher), *turn off* (target `none`, nothing deleted) and
*clear* (scope plus the subject name typed as confirmation). Writes call
the store's own `put`/`clear` under its lock, so validation, revisions
(stale → 409, shown on the page) and the `offsite needs a pusher` rule are
the API's. Each POST is one `backup-audit.log` line (`role: ui`, `user`).

- **Identity: one login for the whole UI.** The dashboard's Zitadel login
  (`auth.zitadel`) signs the `fleet_session` cookie with the session key
  (`auth.sessionKeyFile`, else a per-boot random key in
  `/run/fleet-edge-session/key`). `fleet-edge-overrides` gets the same key
  (`--session-key-file`, LoadCredential) and serves `/backup/` only to a
  valid session holding the dashboard's role (`--session-role`); a browser
  without one is redirected to `/auth/login` and comes back afterwards.
  Request headers are never identity. Writes need `overrides.backup.uiGroup`
  (`--backup-ui-group`, h005: `admin`) among the session's roles, or the
  login's name (email, else username) in `uiUsers` (`--backup-ui-users`);
  others get a read-only page.
- **CSRF:** every form carries `HMAC-SHA256(per-process secret, user)`; every
  POST must carry it and a same-host `Origin` (or `Referer`), else 403.
  POST only. Results come back via a redirect with an HMAC-signed message.

## Design notes

- **Unplaced is one state.** No row means no DNS name, no edge vhost or
  stream, no WAN forward, and "unplaced" on the dashboard. There is no
  enabled/disabled flag.
- **The token fences a move, not the clock.** `reserve` mints an opaque
  token; commit, retire, rollback, recover and renew must present it, and a
  mismatch is a 409. Any row that still carries a token refuses a second
  reserve. `force` is the only takeover and mints a fresh token, so the
  displaced client's handle stops working. A token from a move that has ended
  is refused, never read as "no reservation".
- **Revisions are incarnations.** Tokenless writes (`import`, `force`, a
  tokenless `DELETE`) compare-and-swap on the row's `revision`, minted from
  a counter in `placements.json` that no deletion resets, so a delayed
  request cannot hit a re-created row. A reserve carrying a token or
  revision for a service with no row is a 409 rather than a first placement,
  so a replay cannot bring a deleted row back.
- **An expired lease fences, it never rolls back.** A move stops its source
  before the destination serves, so the sweep marks an expired `prepared`
  row `stale` (effective host: none) and keeps `previous` and the token.
  Only `recover` (which asks both hosts) or `force` settles it; a host that
  did not answer, or both ends serving, decides nothing.
- **Serving, not installed.** Health tracks `installed` and `active`
  separately: commit and import need both, and only a confirmed uninstall of
  the previous host clears the rollback binding. Another host serving a
  bound service is flagged as a `conflict` and never resolved
  automatically. An unreachable host changes nothing: silence is not
  absence.
- **Persist before visible.** Each registry write builds the new rows and
  revision on a copy, writes it atomically, and only then swaps it in, so a
  failed write is a 500 that leaves memory and disk as they were.
- **Reconcile fails closed.** Changes are add-before-remove with one file
  (or push) per name or port, so a pass that dies halfway leaves earlier
  answers in place. A stale row, an unreachable host or a host without an
  address keeps its last answer; nothing is removed on a guess. The host's
  edge listener already returns 444 to anything it no longer serves.
- **Streams close by deletion.** nginx's `stream` module has no `return`,
  and a `server` with no `proxy_pass` fails `nginx -t`, so a closed stream
  port is a deleted file. The stream directory is persisted and owned only
  by the reconciler. An empty directory on a freshly reinstalled o002 stays
  closed until h005's next reconcile pass (at most 30 seconds).
- **Receivers never take nginx text.** h005 sends JSON over a forced-command
  ssh key; the receiver renders, writes atomically, runs `nginx -t` and
  reloads, and leaves a `.reload-pending` marker for a failed reload. h005 and
  o002 are deployed from the same tree, so the receivers have no
  compatibility path for older callers.
- **dnsmasq `hostsdir` quirks** (2.93): the directory must exist when dnsmasq
  starts (tmpfiles creates it), a hidden temp name is still read, so writes
  are `.new` + `rename`; deleting a file drops the record.
- **The public zone points only at our servers.** `Spec.Validate` refuses
  external CNAME targets and duplicate names (cookie scope of the SSO
  domain).

## Status endpoint contract

Each polled host runs fleet-agent's read-only status endpoint, enabled by
`ringofstorms.fleetAgent`. `fleet-edge` substitutes `{overlayIp}` (also
`{lanIp}`, `{host}`)
into `--status-url-template` (default
`http://{overlayIp}:9101/status.json`) per host from the inventory, then
does a `GET` with a short timeout.

Expected response, `200 application/json`:

```json
{
  "host": "h001",
  "time": "2026-10-17T00:00:00Z",
  "services": {
    "jellyfin": {
      "unit": "container@jellyfin",
      "active": "active",
      "enabled": true
    }
  }
}
```

- `time`: RFC3339, when the host generated the snapshot.
- `services`: keyed by service name (matching inventory service names).
  `active` is a systemd-style state string (`active` / `inactive` /
  `failed`, or anything else — fleet-edge passes it through verbatim);
  `enabled` reflects the unit's enablement.
- A service with no entry in `services` (or a host that can't be reached
  at all) renders as `unknown` on the dashboard — fleet-edge never guesses.

This contract is intentionally tiny: fleet-edge and the host status
endpoint share only this JSON shape, no code.

## Usage

```
fleet-edge \
  --listen 127.0.0.1:8099 \
  --inventory /path/to/inventory.json \
  --status-url-template 'http://{overlayIp}:9101/status.json' \
  --poll-interval 30s \
  --poll-timeout 3s
```

Generate the inventory file with, e.g.:

```
nix eval --json 'git+file:///home/josh/.config/nixos-config?dir=containers#inventory' \
  > /var/lib/fleet-edge/inventory.json
```

On h005 (`hosts/h005/fleet-edge.nix`) the inventory is generated at build
time from the `containers` flake input (`builtins.toJSON
inputs.containers.inventory` via `pkgs.writeText`). **Refreshing the
inventory = redeploying h005** (after `nix flake update containers` in
`hosts/h005`). Use `https://fleet.joshuabell.xyz/` for the dashboard and
PWA installation.

## NixOS module (used by h005)

```nix
{
  inputs.fleet-edge.url = "path:./flakes/fleet-edge"; # or a git ref

  # on the host (example only — not applied anywhere in this repo):
  imports = [ inputs.fleet-edge.nixosModules.default ];
  services.fleet-edge = {
    enable = true;
    listen = "100.64.0.1:8099"; # bind only to the overlay IP; nginx in front
    inventoryFile = "/var/lib/fleet-edge/inventory.json";
    statusUrlTemplate = "http://{overlayIp}:9101/status.json";
  };
}
```

The module runs the service as a hardened systemd unit: `DynamicUser`,
`ProtectSystem = "strict"`, `NoNewPrivileges`, `PrivateTmp`,
`RestrictAddressFamilies` limited to `AF_INET`/`AF_INET6`/`AF_UNIX`, empty
`CapabilityBoundingSet`, `SystemCallFilter = [ "@system-service" ]`,
`MemoryDenyWriteExecute`, and the usual `Protect*`/`Restrict*` hardening
knobs. See `flake.nix` for the full list.

## Development

```
cd flakes/fleet-edge
nix shell nixpkgs#go -c sh -c 'gofmt -l . ; go vet ./... && go test -count=1 ./...'
nix build . --no-link
```

Layout:

- `main.go` — flags, wiring, `dns-plan` and `import-beszel` subcommands.
- `internal/auth` — Zitadel OIDC PKCE + JWKS verification and API key auth.
- `internal/bunny` — Bunny DNS reconciliation.
- `internal/dash` — Start-page tile merging.
- `internal/inventory` — Inventory JSON parsing (`hosts`, `services`, `agentHosts`, `replaces`).
- `internal/state` — Status polling, log proxying, and merge into dashboard view.
- `internal/store` — SQLite WAL time-series store, rollups, and Beszel importer.
- `internal/server` — HTTP handlers and embedded `html/template` pages; `charts.go` renders history charts.
