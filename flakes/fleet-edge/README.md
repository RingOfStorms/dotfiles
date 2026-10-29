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
  Auth is on when OIDC is (issuer **and** client ID set) or when any API key
  exists; with neither, the middleware is a no-op and everything is open —
  the deployment's nginx ACL is then the only gate. `--session-key-file` is
  optional: without it the HMAC secret is random per process, so every
  restart ends the browser sessions. `/healthz`, `/auth/login`,
  `/auth/callback` (also `/callback`), and `/auth/logout` are exempt from the
  session check; other `/auth/*` paths are not. h005 enables Zitadel with
  the `admin` role, so its dashboard, topology/SVG, APIs and static assets
  all require a session or API key.
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
  - `GET /topology` — pan/zoom SVG of the rack, switches, VLANs, tailnet and
    public paths with live status; `/topology.svg` serves the same diagram
    standalone for download and for the page's 30s refresh. See
    [Topology](#topology-topology).
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
nix eval --json 'git+file:///home/josh/.config/nixos-config?dir=containers#inventory' \
  > /var/lib/fleet-edge/inventory.json
```

On h005 (`hosts/h005/fleet-edge.nix`) the inventory is generated at build
time from the `containers` flake input (`builtins.toJSON
inputs.containers.inventory` via `pkgs.writeText`). **Refreshing the
inventory = redeploying h005** (after `nix flake update containers` in
`hosts/h005`). It is served tailnet-only at `http://h005.net.joshuabell.xyz/`.

## Topology (`/topology`)

`/topology` is a route atlas of the edge: internet, the Oracle Cloud node, the
rack, the home LAN and the roaming laptops as fixed-size stations in open
labelled regions. It answers "what is where, what is up, and what talks to
what" from a single screen; per-service chips are gone, so a host carrying
sixteen services still reads as one box.

The drawing is a hand-written spec merged with everything the inventory
already knows:

```
fleet-edge --topology /path/to/topology.json      # or FLEET_EDGE_TOPOLOGY
```

`--topology` is an alternative to the environment variable; the NixOS module
sets `FLEET_EDGE_TOPOLOGY` from `services.fleet-edge.topology`. With neither,
every inventory host is drawn in one zone.

### Reading the map

Drag to pan; wheel or pinch to zoom; `+` / `-` zoom, `0` or `fit` returns to
the whole-fleet overview, `Escape` clears the selection. A click on a station
(Enter/Space when it has focus) opens its details in the sidebar: addresses,
declared role, lines, services with their exposure, drives with their SMART
finding, filesystems, fail2ban jails and the wiring it participates in. The
URL fragment carries the selection, so a sidebar can be linked to.

The opening view is not the fitted overview. A 1800-unit atlas fitted into a
1440 px stage renders station names at 7.5 px, so the page opens at whatever
zoom makes a name clear (at least 11.5 px) and centres the host carrying the
most declared services among those currently online — a router or a cloud
region makes a poor centre because no fleet service is anchored to it. If no
host is online yet it falls back to `hubs.edge`, then to the middle of the
diagram; no host id is hardcoded. `fit` is the explicit overview you return
to. A view saved on a wide screen is raised to the same floor when it is
restored on a phone, so a station name is never illegible after a resize:
the saved centre is kept and only the scale moves.

The map refreshes every 30 s while the tab is visible, preserving zoom,
selection and layer state. Polling and animation stop when the tab is hidden.

### Views and layers

Three view buttons choose which wiring is drawn:

| view | draws |
| --- | --- |
| Overview | stations, regions and labels only — no static wiring |
| Physical | the known cabling: WAN, ethernet, trunk, KVM, power |
| Control | the poll and control paths (agent polls, dashboard fan) |

Overview hides the declared rails on purpose: the page's job there is the
shape of the fleet, and journeys are drawn on demand instead. Journeys and
traffic dots live in their own overlay, so selecting a host or switching mode
draws a route over an Overview without turning the rails back on.

The layer checkboxes (Physical links, Tailnet paths, Public paths, Agents &
control) filter link families independently of the view. Toggles persist in
`localStorage`, as do zoom and selection.

### Traffic: simulated by default, honest about it

The badge reads **Simulation** from first paint: requests are generated from
the routes the repo declares (public through the edge hub, tailnet from a
virtual overlay client), and no traffic is measured. Switching to **Real**
does not invent anything — with no provider connected the badge reads *No
traffic provider*, the sidebar says "no measured source is connected", and no
dot is drawn. Only a provider that reports events animates, and each event is
styled as measured or simulated.

Animations respect `prefers-reduced-motion`: the travelling dot is replaced
by a marker that appears at the destination. At most 64 dots are in flight and
each event id is consumed once.

### History and replay

Snapshots are recorded every 30 s and kept for 24 h (`/api/topology/timeline`,
clamped to 1–24 h). Where that history lives depends on the NixOS option
`services.fleet-edge.dbPath` (default `/var/lib/fleet-edge/metrics.db`), which
the module passes as `--db` / `FLEET_EDGE_DB`. With a database, snapshots are
written to SQLite, survive a restart, and the timeline reports
`persistent: true`; its 24 h window is the last 24 h of stored rows, so it
reaches back before a restart. With `dbPath = ""` persistence is off and the
same 24 h is held in a bounded in-memory ring: the page behaves identically for
the life of the process, but every restart starts with an empty strip
(`persistent: false`) and the window can only ever cover time since that
process started.

The strip above the scrubber is the visual history: one bar per slice at the
worst finding in it, so a disk warning stays visible instead of collapsing into
a hairline. Slices with no snapshot are left empty — a recording gap never
reads as healthy time — and a replay that reaches one stops with "No recording
covers that moment…" rather than showing a healthier map than what was
recorded.

The scrubber seeks; ▶ replays from the current cursor at 1×/4×/16×/64× (64× ≈
22 min for a day); **Live** returns to the newest snapshot. A replay frame is
requested with `trafficWindow=full` so its whole 30 s window is queued and
released by the replay clock; a scrubbed frame shows recorded health without
traffic; pausing playback freezes any dots already in flight. A frame older
than its snapshot window is labelled with its age instead of pretending to be
current.

Playback has one clock: pausing stops it, so the label, the slider and every
dot freeze where they are, and the page stops polling `/api/topology/traffic`
until the map is live again. Events the replay has queued but not yet reached
wait with it. Resuming continues from that exact cursor — the queue and the
window already fetched are kept, so no event is replayed twice or dropped.
Scrubbing, **Live** and a mode switch are new intents: they cancel a frame
request that is still in flight, and a replay frame that arrives after the
pause is ignored rather than drawn behind a stopped clock. Only play requests
carry the whole window; a scrub asks again at the cursor, so playing straight
after a scrub still queues that window.

### Country flags

Set `services.fleet-edge.geoipCountryFile` (or pass `--geoip-country-file` /
`FLEET_EDGE_GEOIP_COUNTRY_FILE`; the module default is empty, which disables
lookups entirely). The value is a path to the offline **DB-IP Lite Country**
CSV, plain or gzip-compressed — `.csv` and `.csv.gz` are both accepted, chosen
by sniffing the file header rather than the extension, so a decompressed dump
works without renaming it. Example:
`/var/lib/fleet-edge/dbip-country-lite.csv.gz`.

The file is parsed once at startup and queried in memory; nothing is
downloaded and no banned address ever leaves the host for a lookup, so the
sidebar still resolves countries on a machine with no egress. A configured
path that is missing or malformed fails startup rather than serving a partial
index, so a half-parsed database can never answer wrongly; leaving the option
empty is the supported way to disable lookups.

Banned addresses in the sidebar then carry a flag and country name, and the
attribution line names the source (DB-IP Lite Country, CC BY 4.0). The country
is where the address block is *registered*: it is an estimate about an
address, never a claim about a person, and private, loopback, link-local,
CGNAT, documentation and IPv6 ULA space is deliberately left unlabelled
instead of guessed.

### Schema

`topology.Spec` in `internal/topology/topology.go`:

| key | meaning |
| --- | --- |
| `width` | SVG width in units (0 = 1800) |
| `rows[].zones[]{id,label,kind,flex}` | horizontal bands; zones share a row, widths proportional to `flex` |
| `nodes[]{id,host,label,kind,zone,role,badges[],lines[],href}` | one station; `host` binds it to an inventory host, `role` is the muted line under the name, `badges` the declared tags |
| `links[]{from,to,kind,label}` | one declared connection between two node ids |
| `defaultZone` | zone that receives every inventory host the spec doesn't place |
| `hide[]` | inventory hosts never auto-placed |
| `hubs{tailnet,edge,router,dashboard}` | node ids the derived edges attach to (`""` skips that family) |
| `notes[]{title,text}` | the explanation paragraphs |

Zone `kind` picks the tint (`internet`, `cloud`, `tailnet`, `home`, `rack`,
`lan`, `roaming`; anything else is neutral). Link `kind` picks the style and
the layer it belongs to: `wan`, `ethernet`, `trunk`, `wifi`, `kvm`, `power`
(physical), `tailnet`, `public`, `agent`/`control`.

### What is derived, never declared

- **Inventory hosts and their live state** — the state dot, overlay/LAN IPs,
  role, metrics and per-service detail come from the inventory, not the spec.
  Every inventory host the spec doesn't place appears in `defaultZone`, so a
  new fleet host shows up without a spec edit (use `hide` for non-fleet
  things like the printer).
- **Service and drive detail** — the sidebar lists every declared service with
  its exposure, proto, port and URLs, every drive with its SMART finding, the
  filesystems and the fail2ban jails. A red service count means something is
  not running; a ban is protective enforcement and is never counted as a
  fault. Missing SMART is unknown, not healthy, and a standby drive is quiet
  rather than failing.
- **`hubs.tailnet`** — an edge to every placed host with an overlay IP.
- **`hubs.edge`** — an edge to every placed host carrying `via = "edge"`
  routes, labelled with the count.
- **`hubs.router`** — the same for `via = "router"` routes (`minecraft` has no
  host today, so h005 leaves this empty rather than draw an empty fan).
- **`hubs.dashboard`** — an edge from the dashboard host to every host with a
  fleet-agent.

Only the parts the inventory can't know live in the spec: physical gear,
cabling, VLANs and the prose. A declared cable is drawn only when the repo
records it (the h005 trunk, the switch interlink, the KVM, UPS and console
wiring); a host whose switch port is unrecorded gets no ethernet edge at all
rather than a guessed one — zone membership already says which network it is
on.

### Validation

`topology.Validate` runs at startup; a bad spec fails the service instead of
drawing a wrong diagram. It rejects duplicate or empty zone ids, a
`defaultZone` that isn't a zone, nodes in an undeclared zone, duplicate node
ids, `host` values not in the inventory, a host placed twice, a hostless
node id that collides with an auto-placed host name, links with an unknown
kind/endpoint or a self-loop, and a hub naming a node the spec doesn't
place.
Negative widths/flex are rejected, and every computed zone must be at least
`topology.MinWidth` (224 SVG units) wide, after the row's gaps and
proportional flex allocation.

h005's spec is `hosts/h005/topology.nix`, wired in `hosts/h005/fleet-edge.nix`
as `topology = import ./topology.nix { inherit fleet constants; };` — it reads
`fleet.hosts` and `_constants.nix` (VLAN ids, leases) so addresses can't
drift from the router config.

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
- `internal/topology` — `/topology` spec handling: validation against the
  inventory, zone/row layout, edge routing and the derived hub edges.
