# fleet-edge

Read-only fleet dashboard and host health/metrics monitor. Packaged like
`flakes/ports` (stdlib Go, no external Go deps, `go1.22`, runtime `sqlite3`
for time-series storage), with a NixOS module.

See `containers/ROUTING-PLAN.md` §5.2/§5.4 and `MONITORING-PLAN.md` for the
design.
## What's implemented (this skeleton)

A single Go binary, `fleet-edge`:

- Reads a static inventory JSON file (the same shape the `containers` CLI
  produces via `nix eval --json <containers-flake>#inventory`:
  `services`, `hosts`, `containerHosts`). `routes` on a service is
  optional per-service (absent entirely on services that haven't adopted
  it); when present, several fields (`name`, `fqdn`, `url`, `auth`,
  `health`) are nullable (e.g. on `tcp`/`udp` routes with no HTTP name),
  and `via` is a **list** of strings (e.g. `["edge"]`), not a single
  string. A missing `routes` map is treated as empty, never an error.
- Polls each host's status endpoint (see contract below) every 30s with a
  3s timeout, tolerating failures. A host that can't be reached (timeout,
  refused, bad JSON) is recorded as unreachable; every service declared on
  that host shows `unknown` state rather than failing the page.
- Stores 30s time-series samples (`host_samples`, `fs_samples`), offline host
  snapshots (`host_last_state`), and host lineage events (`host_events`) in a
  SQLite WAL database (`/var/lib/fleet-edge/metrics.db`) with automatic 5m and
  1h rollups, plus `fleet-edge import-beszel` for migrating historical Beszel
  databases (including `h002` -> `h004` host replacement lineage).
- Authenticates requests via Zitadel OIDC Authorization Code + PKCE (`admin`
  role claim, `fleet_session` HMAC cookie) or `Bearer` / `X-API-Key` tokens.
- Serves, on `--listen` (default `127.0.0.1:8099`, behind nginx on `h005` at
  `https://fleet.joshuabell.xyz`):
  - `GET /` — start page of app tiles.
  - `GET /services` — table of every service: name, declared host, polled state,
    backup age, routes, description.
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

## What's planned (not in this skeleton — see ROUTING-PLAN §5.2)

In rough order, per the plan's step list:

- **DNS**: tailnet + LAN DNS record generation (dnsmasq `hostsdir`), and
  public DNS via the bunny API (CNAMEs per §2.2, DDNS for `home`).
  `fleet-edge` is meant to become the sole holder of the bunny key.
- **Router forwards**: an nft port-forward map on h005 for `via = "router"`
  routes, added/removed by `cnt deploy/move/expose`.
- **Certificates**: wildcard issuance via DNS-01 on h005, distributed to
  the hosts that terminate TLS (replacing h001's copy of the ACME/bunny
  key).
- **Overrides**: authoritative store for temporary `cnt expose` overrides
  (by/at/until/reason), with expiry enforced on both h005 and the host.
- **Standalone DNS records**: non-service records in the zone (CNAMEs,
  TXT, MX), with `cnt dns ls|diff|apply`, and record-ownership tracking so
  `fleet-edge` never touches records it didn't create.
- **Narrow, authenticated API** for the above, on h005's overlay IP only,
  logged.
- **Dashboard actions** (start/stop/expose/move), behind a separate admin
  group, starting as "copy this `cnt` command" buttons before any
  deploy rights are granted (ROUTING-PLAN §5.4).
- **Audit**: cross-check declared routes against actual listeners, nft,
  DNS answers and o002 vhosts (ROUTING-PLAN §6.1).

None of that exists here. This package only reads inventory and polls
status endpoints.

## Status endpoint contract

Each host that `fleet-edge` polls is expected to run a small, read-only
HTTP endpoint (to be added by the host module later; not part of this
flake). `fleet-edge` substitutes `{overlayIp}` (also `{lanIp}`, `{host}`)
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
nix eval --json .#inventory > /var/lib/fleet-edge/inventory.json
```

On h005 (`hosts/h005/fleet-edge.nix`) the inventory is generated at build
time from the `containers` flake input (`builtins.toJSON
inputs.containers.inventory` via `pkgs.writeText`). **Refreshing the
inventory = redeploying h005** (after `nix flake update containers` in
`hosts/h005`). It is served tailnet-only at `http://h005.net.joshuabell.xyz/`.

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
- `internal/server` — HTTP handlers, inline SVG chart generator, and embedded `html/template` pages.
