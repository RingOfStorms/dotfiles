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

`/topology` is a route atlas drawn as three vertical columns. Outside on the
left are the public edge, the yellow public DNS name cloud, the separate
purple overlay name cloud, and Bunny DNS. The middle is one green rack
enclosure containing the modem, h005 router/dashboard, switches, servers,
consoles and UPS units; rack order reads down the first internal column, then
the next. The right contains the home LAN and roaming workstations. There is
no separate internet-uplink or Headscale station and no generic simulated
client: journeys start at the actual declared name badge.
Every drawn connection is a Bezier: the server emits `L` legs joined by
tangent `Q` corners for the physical, control and per-route paths, so there
are no hard right angles, and the browser composes each traffic journey from
those same `d` strings rather than restating the geometry. Traffic dots ride
the rendered SVG through `getPointAtLength`, so a marker is always on the ink
the reader sees, at whatever zoom and fit the map is shown in.

The drawing combines the hand-written physical/layout spec, inventory route
declarations, actual agent reports and the placement registry's current
service-to-host binding:

```
fleet-edge --topology /path/to/topology.json      # or FLEET_EDGE_TOPOLOGY
```

`--topology` is an alternative to the environment variable; the NixOS module
sets `FLEET_EDGE_TOPOLOGY` from `services.fleet-edge.topology`. With neither,
every inventory host is drawn in one zone.

Service ownership uses `--placements-url` / `FLEET_EDGE_PLACEMENTS_URL`
(default `http://127.0.0.1:8098/internal/placements.json`), not a fallback to
inventory placement. An empty URL or unavailable registry leaves services
unplaced: the map does not invent their owning hosts or route branches.

### Reading the map

The page is one full-width canvas, with no permanent sidebar or explanatory
disclosure. Station state, available CPU/memory gauges, simulated disk-usage
rings, declared service counts, service failures, drive advisories and ban
enforcement are glanceable without a click. Unknown metrics are not healthy
zeros; bans are protective enforcement, not faults.

Drag to pan; wheel or pinch to zoom; `+` / `-` zoom, `0` or `fit` returns to
the whole atlas, `Escape` closes the detail panel. The page **opens on the
whole map**, at both a laptop and a phone: the server sizes the viewBox to the
stage's aspect ratio, so scale 1 already means every station and every name is
on screen. On a phone that is a smaller map rather than a clipped one, and the
reader zooms in when they want to read a name.

A click on a station (Enter/Space when it has focus) opens a selection popover
with its addresses, role, every served FQDN and route key, services and exposure,
SMART findings, filesystem/pool details, fail2ban jails and wiring. Its Space
list has one row per reported primary mount, with recorded bytes beside the
explicitly simulated fill and a swatch matching the mount's blue ring;
submount aliases are listed under their primary rather than becoming extra
rings. On a narrow screen the popover becomes a bottom drawer. The URL
fragment carries the selection, so a station can be linked to.

Roles and membership tags stay in station tooltips and the popover rather
than crowding the resting map; health readouts remain on the canvas.

Picking a station adds a selection ring without dimming anything else. A name
badge may emphasise its route, but never hides another route. All public and
overlay name badges, collectors and owner branches stay visible at baseline
in Overview, Physical and Control, including routes not selected for a trace.

The map refreshes every 30 s while the tab is visible, preserving zoom,
selection and view. Polling and animation stop when the tab is hidden.

### Views

Three view buttons choose which *cabling* leads; they never hide a station,
a name or a route web.

| view | draws |
| --- | --- |
| Overview | the known cabling quiet, every route web at full strength |
| Physical | the recorded cabling at full weight: WAN, ethernet, trunk, shared L2 fabric, KVM, power |
| Control | the poll and control paths at full weight (agent polls, dashboard fan, DNS and proxy pushes) |

Cabling that is not emphasised stays drawn at reduced weight: a view says
what to look at first, it does not turn the physical picture into a rumour.
The public and overlay webs are painted by the same layers in all three
views.

Cable detail — port, trunk, VLAN — is the cable's **tooltip**, never printed
on the resting map, so no wall of "switch/port not recorded" crosses the
stations. The same text appears in the selected station's wiring list.

### What the drawing means

Public names hang off one yellow curly brace and collector, leading through
o002 and branching to **every current owning host**. Overlay names use their
own purple curly brace and collector, branching once per owning host. Bunny
DNS is outside the rack: h005's control link manages its declarations, and
light declaration paths connect Bunny to the public names. A declaration is
not evidence of a live DNS lookup or working service.

Connections use Bézier curves instead of sharp elbow corners. Traffic dots
follow the same curved public/overlay collector and owner paths drawn on the
map; this changes geometry, not route visibility or pause/replay semantics.

Disk-usage rings are **simulated**, always shades of one blue hue, and vary
deterministically by snapshot hour, host and primary mount. Capacity bytes,
CPU/memory utilisation, service state, drive advisories and bans come from
actual agent reports, not that simulation. CPU and memory bars carry numeric
percentages when available; a missing metric reads `—` without a fabricated
bar. The popover keeps recorded capacity beside the simulated figure.

Recorded WAN, trunk, switch-interlink, console and power wiring is solid.
The neutral shared LAN fabric connects both switches and the wired LAN
hosts with dashed logical attachments: `VLAN 20 shared fabric` on the switch
side and `switch/port not recorded` on the host side. These assert L2
membership, not an invented switch, port or patch cable. Roaming workstations
have no permanent wire because the repo records none.

### Traffic: simulated by default, honest about it

The badge reads **Simulation** from first paint: requests are generated from
the routes the repo declares, and no traffic is measured. Every journey starts
at a chip the server actually laid out — a public name enters on its own chip,
through the shared yellow trunk, the edge proxy and on to the host the route
names; an overlay name leaves its purple cloud along the branch for its host.
Switching to **Real** with no capture provider keeps the mode unavailable:
the badge reads *No traffic provider*, the mode note explains that no measured
source is connected, and no dot is drawn. Real capture is intentionally not
configured. A connected provider's events distinguish measured from simulated
traffic. A host/route pair without a declared badge draws no fictional path
and creates no invented client box.

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

Playback has one clock: pausing freezes the label, slider, in-flight dot
positions and fade, and queued events wait. Traffic polling stays stopped
through recorded playback and pause. A pure pause/resume continues from the
exact cursor with the fetched window and queue intact; each event is consumed
once. Scrubbing, **Live** and a mode switch are new intents that cancel an
in-flight frame request. A stale play response arriving after pause is ignored
instead of moving the stopped cursor or replacing its SVG. Only play requests
carry the whole traffic window; a scrub asks at the cursor, so play after a
scrub fetches that full window before continuing.

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
page still resolves countries on a machine with no egress. A configured
path that is missing or malformed fails startup rather than serving a partial
index, so a half-parsed database can never answer wrongly; leaving the option
empty is the supported way to disable lookups.

Banned addresses in the station panel then carry a flag and country name, and the
attribution line names the source (DB-IP Lite Country, CC BY 4.0). The country
is where the address block is *registered*: it is an estimate about an
address, never a claim about a person, and private, loopback, link-local,
CGNAT, documentation and IPv6 ULA space is deliberately left unlabelled
instead of guessed.

### Schema

`topology.Spec` in `internal/topology/topology.go`:

| key | meaning |
| --- | --- |
| `width` | SVG width in units (0 = 1500) |
| `height` | minimum height in units (0 = whatever the tallest column needs) |
| `columns[]{id,label,flex,zones[]}` | columns ordered left to right; width shares use `flex` (0 means 1) |
| `columns[].zones[]{id,label,kind,flex,layout,cols,fill,box,group}` | regions stacked top to bottom; `flex` shares the column's leftover height (0 means natural content height) |
| `nodes[]{id,host,label,kind,zone,role,badges[],lines[],href,segment}` | station placement and non-derived detail; `id` defaults to `host`, role/badges remain in tooltips and the popover, `segment` draws a fabric bar rather than a device head |
| `links[]{from,to,kind,label}` | declared connection between node ids; the label is available in its tooltip and wiring detail |
| `dns{zone,external[],records[]}` | public DNS catalogue; external names are managed elsewhere |
| `dns.records[]{name,type,value,ttl,source,declared,host,service,route}` | relative name, record type and target, optional TTL/source; ownership fields are derived from declared routes, not hand-assigned |
| `defaultZone` | station zone receiving inventory hosts not explicitly placed; empty leaves them out |
| `hide[]` | inventory hosts excluded from automatic placement |
| `hubs{tailnet,edge,router,dashboard}` | node ids for derived edge families; empty skips that family (h005 uses `edge = "o002"`, `dashboard = "h005"`, empty `tailnet`/`router`) |

Zone `kind` selects a tint (`cloud`, `tailnet`, `home`, `rack`, `lan`,
`roaming`; other values are neutral). `layout` accepts `flow` (the default:
pack stations and wrap), `stack` (one station per row), or `routes` (a derived
name cloud instead of stations). A routes region requires `group: "public"`
or `"overlay"`, with at most one region per group. `cols: 0` fits as many
stations as possible; a positive value caps items per row. `fill` accepts
`row` (default) or `column` (down, then across). `box: true` draws one solid
enclosure; h005's rack uses `layout: "flow", cols: 2, fill: "column"`.

DNS record types are `A`, `AAAA`, `CNAME`, `TXT`, `MX`, `NS`, `SRV` and `CAA`.
`available` belongs to the derived public-zone metadata, not the input schema.

Link `kind` picks the style and the layer it belongs to: `wan`, `ethernet`,
`trunk`, `wifi`, `kvm`, `power` (physical), `lan` (a visually dashed
attachment whose switch port is not recorded), `tailnet`, `public`,
`agent`/`control`.

### The route clouds

Route-cloud regions are derived rather than hand-placed. h005 imports
`dns = (import ./dns-records.nix { inherit fleet; }).publicSpec`; this is the
same public catalogue used by DNS planning, not a second list of FQDNs.
The inventory supplies service routes and their current owning hosts.

- **public** (`group: "public"`) has one badge per catalogue FQDN, labelled
  with its relative name. For example `git.joshuabell.xyz` is Forgejo,
  `location.joshuabell.xyz` is Dawarich, and `life.joshuabell.xyz` is Life;
  all currently belong to h001 and lead through o002. The yellow collector
  branches once per owner, not once per selected route.
- **overlay** (`group: "overlay"`) contains the declared non-public names.
  Trilium appears as `notes.joshuabell.xyz`, not a made-up service hostname;
  `litellm.joshuabell.xyz` is another example. Its purple collector branches
  once per owner.

A DNS-only name without a placed declared route stays faint and unowned
(`declared: false`, no host). It gets no simulated journey or guessed host,
even when its record names o002 or resolves through a CNAME chain. Unknown
DNS availability stays unknown rather than being painted healthy.

`Diagram.RouteMeta` is the JSON behind `#topo-routes`
(`{groups[],dns,links[]}`): the placed chips with their absolute coordinates,
the collector points, brace/trunk paths, and public and overlay owner
branches. Traffic events resolve by host and route key to the exact declared
badge the server drew, never a synthesised one. Selection changes emphasis
only, not the baseline route graph.

### Simulated disk rings

`Node.Rings` draws one ring per **reported primary mount**, with a distinct
shade of the same blue hue. Pool submounts/aliases remain attached to their
primary and do not create rings; separate reported primary mounts are not
collapsed merely because they share a filesystem or device. The simulated
fraction is deterministic in `(snapshot hour, host, mount)`, so an hour's
replay is repeatable. It never modifies recorded capacity, SMART, filesystem
health or service state. A mount with no report gets no guessed ring.

### What is derived, never declared

- **Inventory hosts and live state** — the inventory supplies hosts, addresses,
  roles, placement and declared services/routes; fleet-agent polls supply
  reachability, metrics and health. Unplaced inventory hosts appear in
  `defaultZone` unless hidden, so a new host needs no spec placement edit.
- **Service and drive detail** — the station panel lists every declared service with
  its exposure, proto, port and URLs, every drive with its SMART finding, the
  filesystems and the fail2ban jails. A red service count means something is
  not running; a ban is protective enforcement and is never counted as a
  fault. Missing SMART is unknown, not healthy, and a standby drive is quiet
  rather than failing.
- **`hubs.tailnet`** — optional coordination-server edges. h005 leaves it
  empty: overlay membership is a station tag and routes remain direct owner
  branches, not a permanent Headscale station/fan.
- **`hubs.edge`** — public paths to every placed `via = "edge"` owner.
- **`hubs.router`** — the same for `via = "router"` routes (`minecraft` has no
  host today, so h005 leaves this empty rather than draw an empty fan).
- **`hubs.dashboard`** — an edge from the dashboard host to every host with a
  fleet-agent.

Only facts the inventory cannot derive are hand-written: physical gear,
recorded cabling, VLAN membership, placement and station detail. Unknown
switch/port attachments use the shared dashed LAN fabric instead of guessed
ethernet edges. Technical explanations live here, not in schema notes or
collapsible prose on the canvas.

### Validation

`topology.Validate` runs at startup; a bad spec fails the service rather than
drawing a wrong diagram. It rejects empty/duplicate zone ids, empty columns,
negative dimensions/flex/column caps, unsupported layout/fill/group values,
duplicate route-cloud groups, and columns too narrow for their stations.
It also rejects undeclared station zones, stations placed in route regions,
an invalid `defaultZone`, duplicate node ids or host placements, unknown
inventory hosts, hostless ids colliding with auto-placed hosts, unknown link
kinds/endpoints, self-loops, and hubs naming absent nodes. DNS records require
a zone, a name, a supported type and a value; duplicate name/type pairs fail.
Column widths are computed after gaps and proportional flex allocation.

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
