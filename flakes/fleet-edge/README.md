# fleet-edge

Read-only fleet dashboard. Packaged like `flakes/ports` (stdlib Go, no
external deps, `go1.22`), with a NixOS module. This is a skeleton: it has no
write paths anywhere, and it is not wired into any host yet.

See `containers/ROUTING-PLAN.md` §5.2 ("Generated pieces and who writes
them") and §5.4 ("Dashboard") for the full design this implements a first
slice of.

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
- Serves, on `--listen` (default `127.0.0.1:8099`, meant to sit behind
  nginx per ROUTING-PLAN §5.4 — tailnet-only, `oauth2-proxy` gated, o002
  excluded):
  - `GET /` — table of every service: name, declared host, polled state
    (`active`/`inactive`/`failed`/`unknown`), routes (fqdn as a link,
    exposure, auth), description.
  - `GET /hosts` — per host: overlay IP, LAN IP, last poll result
    (reachable/unreachable + error + timestamp).
  - `GET /healthz` — `ok`.
  - `GET /api/state.json` — the same merged view as JSON, for scripting or
    a future UI.
- No POST handlers anywhere. No action can be taken from this server; it
  only reads the inventory file and polls read-only HTTP endpoints.

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

(exact generation/refresh mechanism — static file vs. a timer — is left to
the host that imports this module; this flake only reads the file).

## NixOS module (not wired into any host yet)

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

- `main.go` — flags, wiring.
- `internal/inventory` — inventory JSON parsing.
- `internal/state` — status polling + merge into dashboard view.
- `internal/server` — HTTP handlers + embedded `html/template` pages.
