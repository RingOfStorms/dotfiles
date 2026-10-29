# Routing, exposure and auth for floating containers

Design for routing that follows a service across hosts. Goal: every service says **in one place**
who can reach it, how, and through what auth. The tooling makes the network
match that statement, lets it change at runtime (move, temporarily public),
and shows it on one tailnet-only page.

Status: **being implemented**; see §8 for per-step status. Done: step 1
(`routes` schema, generated host vhost + ports, `cnt routes`, `cnt audit`),
step 2 (`cnt port`, per-host `trustInterface = false` fleet-wide),
step 3 (internal/edge listener split), step 6 (fleet oauth2-proxy, sso-proxy
now public via o002's edge listener on h005),
step 7 (`cnt expose` overrides with expiry, tailnet/lan only), step 8
(read-only dashboard in fleet-edge, homepage-dashboard retired).
Partial: step 2 (`cnt port open|ls|close` and no-`tailscale0`-trust rolled
out on h001/h003/h004/h005/i001/joe/lio/o002; juni, oren, gp3, l002, t
still trust `tailscale0`), step 4 (DNS/bunny and wildcard certs done;
router forwards code
done, off by decision), step 5 (private networking mechanism built, rollout
service-by-service), step 9 (`cnt move`, blocked on §9.1). Decisions are
in §7; §6 lists
requirements every step must meet. §9 holds the open items carried over from
the finished migration plan (all services float since 2026-10-17).

Roles assumed: **h005 = router** (WAN, port forwards, DDNS, LAN + tailnet
DNS, always on), **h004 = NAS**, **o002 = public TLS edge**, h001/h003/lio/joe
= service hosts.

## 1. Today (audit 2026-10-14, h001)

This section is a historical snapshot (audit date below); §8 tracks what has
since changed.

How a request gets in now:

```
public client ─▶ o002 nginx (per-name ACME, hand-written list in o002/nginx.nix)
                   └─ http://100.64.0.13:80 (hard-coded upstreamHost) ─▶ h001 nginx ─▶ 127.0.0.1:<port>
tailnet client ─▶ h005 dnsmasq-tailnet (fleet.nix h001Subdomains, hand list) ─▶ 100.64.0.13 ─▶ h001 nginx
LAN client     ─▶ h001 :80/:443 (open on LAN) ─▶ h001 nginx
any tailnet node ─▶ h001:<any port on 0.0.0.0>   (tailscale0 is a *trusted* interface)
```

Exposure is spread over five places that must agree by hand: `service.nix`
`nginx` strings, `tcpPorts`, `fleet.nix` `h001Subdomains`,
`o002/nginx.nix`, and per-host firewall snippets (litellm's 8094).

Findings:

- **Every 0.0.0.0 listener on h001 is reachable from every tailnet node,
  bypassing nginx**, because `flakes/common/nix_modules/tailnet` puts
  `tailscale0` in `trustedInterfaces`. Live examples: sonarr 8989, radarr
  7878, prowlarr 9696, bazarr 6767, seerr 5055, audiobookshelf 9292,
  shelfmark 6336, sabnzbd 8087, jellyfin 8096, immich ML 3003
  (unauthenticated), immich postgres 5432 (scram, `immich_ro` only),
  homepage 8082, litellm 8094. "Tailnet" today means *all your devices*
  (headscale ACL: full mesh for `josh@`; only `tag:lowtrust` is limited).
- **Host networking means no isolation between services.** Every container
  shares h001's loopback: a compromised arr app can call vaultwarden
  `127.0.0.1:8222`, sec `127.0.0.1:8300`, litellm, and so on.
  "localhost-only" protects against the network, not against neighbours.
- Ports are hand-allocated, globally per host (8080 = life on h001, localai
  on joe, the minecraft map on h003). That's a move-time collision risk.
- Public non-HTTP traffic used a second path: minecraft went through a DNAT
  on the old router (h003) plus the DDNS name. That's gone since h003 stopped
  being the router, and h005 has no port forwards yet.
- "Tailnet-only" names are tailnet-only **by DNS**, not by policy. h001's
  :80/:443 is open to the LAN and to o002, and nginx picks the vhost by the
  `Host` header. Anyone on the LAN can reach any h001 vhost with
  `curl -H 'Host: x.joshuabell.xyz'`.
- o002 issues one http-01 cert per public name (each name is in the
  Certificate Transparency logs, which is fine for public ones). h001 holds
  the `*.joshuabell.xyz` wildcard via DNS-01 with the bunny key, a key that
  can rewrite the whole zone.
- Postgres inside containers is fine. The effective pg_hba is socket-only
  everywhere except immich (scram for `immich_ro` from 100.64/10) and life
  (md5 on loopback).

## 2. The model: `routes` in service.nix

One attrset replaces the free-form `nginx` string, `tcpPorts` and the
hand-kept DNS/edge lists. The CLI and host module generate everything else.

```nix
routes = {
  web = {
    port = 2283;                  # backend port inside the service
    name = "photos";              # -> photos.joshuabell.xyz (default: service name)
    exposure = "public";          # see §2.1, the ONE knob
    auth = "native";              # see §4
    # optional HTTP knobs (sane defaults, all generated into nginx):
    websockets = true;
    maxBody = "50G";              # default 100m
    buffering = false;            # streaming uploads/downloads
    timeouts = "1h";
    extraLocations = { "/api/socket" = ''...''; };  # escape hatch, rare
  };
  ml = { port = 3003; exposure = "local"; };              # immich ML: no route at all
  db = { port = 5432; proto = "tcp"; exposure = "tailnet";
         allow = [ "lio" ]; };                              # immich_manager only
};
```

### 2.1 Exposure levels (one enum, ordered, nothing implicit)

Two client tiers exist on the tailnet: **high trust** (untagged `josh@`
nodes, full mesh) and **`tag:lowtrust`** (can't reach other nodes). Low-trust
nodes count as **internet clients** everywhere in this plan; "tailnet" below
always means high trust.

| Level | Who can reach it | What gets generated |
|---|---|---|
| `local` | The service itself | Nothing. No vhost, no DNS, no firewall. With private networking (§3) not even the host's other containers can reach it. |
| `tailnet` | High-trust tailnet nodes (optionally only those in `allow`) | Vhost on the host's **internal listener** (§2.3), allowed only from high-trust overlay IPs, **o002 excluded**. Record in tailnet DNS only. Raw TCP/UDP: firewall rule on `tailscale0` for that port and those sources. |
| `lan` | Tailnet + home LAN (`10.12.14.0/24`, so guests on wifi too) | As `tailnet`, plus the LAN subnet and a record in the LAN DNS. |
| `public` | Internet (incl. low-trust nodes) | As `lan`, plus one or more **public paths** (§2.4). Refused unless `auth != "none"` or `publicWithoutAuth = true` is set explicitly. |

**Three-tier DNS for one name.** `jellyfin.joshuabell.xyz` with
`exposure = "public"` resolves differently depending on who asks:

| Resolver | Who uses it | Answer |
|---|---|---|
| Public (bunny) | Internet, low-trust nodes off-LAN | CNAME → `o002.joshuabell.xyz` (or `home.joshuabell.xyz` for `via = "router"`) |
| LAN DNS on h005 | Anything on `10.12.14.0/24` (wifi guests, low-trust phones at home) | Service host's **LAN IP**, so traffic skips the edge |
| Tailnet DNS on h005 (headscale split DNS) | High-trust nodes anywhere | Service host's **overlay IP** |

All three are generated from the same route by `fleet-edge` (§5.2), so they
can't drift. A `lan` route has only the last two answers; a `tailnet` route
only the last one.

Rules that make this trustworthy:

- **Default is `local`.** A route without `exposure` is not reachable at all.
  Adding a service never opens anything by accident.
- **Policy is enforced at nginx and the firewall, by transport peer**, not
  by DNS and never by forwarded headers (§2.3).
- **No raw app ports on the network.** Apps listen inside their own network
  namespace (§3). Only nginx, sshd and declared `proto` routes are
  reachable. No host trusts `tailscale0` (§5.1).

### 2.2 Names

- One name per route, `<name>.joshuabell.xyz`, the same everywhere
  (split-horizon, §2.1). Clients never need `:port`.
- **Public DNS convention** (hard-coded for now, zone `joshuabell.xyz`
  only; other domains are not managed):
  - Two anchor A/AAAA records: `o002.joshuabell.xyz` (edge, static) and
    `home.joshuabell.xyz` (router, kept current by DDNS).
  - Every public route name is a **CNAME** to one of them: `via = "edge"`
    → `o002`, `via = "router"` → `home`. A home IP change or an o002
    rebuild touches one record.
  - A route with both paths gets the `edge` CNAME; the router path then
    needs its own name (e.g. `mc.` vs `mc-web.`), since one name can't be
    two CNAMEs.
- **Namespace** (retired the `zone = "private"` option; FLOWS-AUDIT target
  design (a)): every route is `<name>.joshuabell.xyz`, covered by the
  zone wildcard, which every container host now holds a pushed copy of
  and terminates locally (hosts/h005/wildcard-cert.nix). So no per-name
  certificates are needed.
- The app must know its external URL (immich `IMMICH_SERVER_URL`, forgejo
  `ROOT_URL`, paperless `PAPERLESS_URL`, open-webui `WEBUI_URL`,
  vaultwarden `DOMAIN`, ...). `mkNixosContainer` passes
  `routes.<r>.url` into the guest via `specialArgs`, so container.nix reads
  it instead of hard-coding it. Rename the route and the app follows. No
  sub-path hosting (`/app/`): every app gets a subdomain, which avoids
  rewrite rules almost entirely.

### 2.3 Telling edge traffic from tailnet traffic

o002 reaches service hosts over the tailnet from `100.64.0.2`, which sits
inside `100.64.0.0/10`. A plain "allow tailnet" rule would therefore also
admit whatever o002 forwards, so a stale or hand-edited o002 vhost could
keep a downgraded or expired route public. The decision therefore **never**
uses `X-Forwarded-For` or `Host`. It's made on the transport peer and the
listener:

- Each service host runs **two nginx listeners** (three with router HTTP):
  - **internal** (`:80`/`:443` on the LAN and overlay IPs) carries **every
    non-`local` route, public ones included**. LAN and high-trust clients
    reach public routes directly through it, so promoting a route to
    `public` doesn't change their URL or path. The firewall admits it on
    `tailscale0` and the LAN and **drops o002's overlay IP** (any edge peer)
    before any allow. Each vhost also checks `$realip_remote_addr` (the real
    TCP peer, unaffected by `real_ip`) against its allow set, with an
    explicit `deny 100.64.0.2` first. Public routes allow LAN + high-trust
    here too; internet traffic never uses this listener.
  - **edge** (`<overlayIp>:8443`) carries **only routes that are currently
    `public` via edge**. The firewall admits it only from o002. A downgrade
    or an expired override removes the route here, so even a stale o002
    vhost gets 444 from the host.
  - For an HTTP route with `via = "router"`, h005 DNATs to a third
    listener (`:8444`) with the same rules as edge: only currently public
    routes, admitted only for forwarded WAN traffic.
- `real_ip` (`set_real_ip_from 100.64.0.2`) is enabled **only on the edge
  listener**: correct client IPs for logs and rate limits there, and no
  spoofing on the internal one.
- Router-forwarded traffic (§2.4) keeps the internet client's source address
  through DNAT. It can't match a tailnet/LAN allow set, and the host's
  firewall admits WAN-sourced traffic only on ports currently forwarded for
  `public` routes. That set is driven by the same state, so it fails closed
  too.

#### 2.3.1 Step 3 as built (2026-10-20)

Corrections to the text above: o002's overlay IP is **`100.64.0.5`**
(`fd7a:115c:a1e0::5`), not `.2` (that's oren). The edge listener binds
`:8443` on all addresses; the **firewall** limits it to o002 on
`tailscale0`. Binding the overlay IP would add a startup race without
adding protection.

- **Host module** (`nginx.edge.{port,peers,blockInternal}`, default 8443,
  o002 v4+v6) adds three things to the http block:
  - `map $realip_remote_addr $fleet_edge_peer` (1 = o002);
  - `$fleet_edge_block_internal` (1 = o002, only when `blockInternal`);
  - a `:8443` `default_server` returning 444, plus
    `/etc/fleet-containers/nginx-edge-realip.conf` (`set_real_ip_from` o002,
    `X-Forwarded-For`, not recursive).

  The firewall gets `iifname tailscale0 ip(6) saddr <o002> tcp dport 8443
  accept` and nothing else for 8443. The CLI renders no IPs.
- **Generated vhost** (`routesVhost`): every non-local http route gets the
  **internal** server (`:80/:443`, wildcard cert, no `real_ip`, `if
  ($fleet_edge_block_internal) return 444`). Public `via = edge` routes also
  get an **edge** server (`:8443`, the realip include, `if ($fleet_edge_peer
  = 0) return 444`). Tailnet and lan routes get only the internal server;
  their allow lists come with fleet-edge. Downgrading a route and
  redeploying removes its edge server, so o002 gets 444 from the catch-all
  even with a stale vhost.
- **o002** calls `containers/lib.nix` `edgeVirtualHosts { dir; hosts; }`
  (imported by path like `fleet.nix`, so no new flake input). For each
  public `via = edge` http route it proxies to
  `http://<host overlayIp>:8443` with the route's
  `maxBody`/buffering/`requestBuffering`/timeouts/websockets. `X-Forwarded-*` comes from
  `recommendedProxySettings`. Non-container names (apex, www, ellalala,
  headscale, computerboyz) and unconverted h001 services (notes, sso-proxy,
  jellyfin, books, media) stay hand-kept. Unconverted ones still go to
  h001 `:80`. An eval assertion refuses a name that is both hand-kept and
  generated. Test: `nix eval --impure --expr 'import
  ./containers/tests/edge-vhosts.nix'`.
- **TLS on o002: now the h005-pushed wildcard.** o002 has no bunny key (its
  sec grants are join/git tokens only); the wildcard is issued on h005 and
  pushed via `wildcard-push` (deployed 2026-10-21, §8 step 4, Certificates
  bullet). Per-name http-01 is no longer used on o002.
- **`blockInternal` is on for h001** (2026-10-20, generation 818,
  `hosts/h001/floating-containers.nix`). It only fills
  `$fleet_edge_block_internal`, which only generated (routes) vhosts check.
  So o002 now gets 444 (empty reply) for generated names on h001 `:80/:443`,
  and the unconverted nginx-string sites (notes, sso-proxy, jellyfin, books,
  media) still reach `:80` from o002 as before. Each service that gets
  converted is covered automatically.
- **Migration (zero downtime).** It's additive first, then switches the
  consumer:
  1. h001 rebuild: maps, catch-all and firewall rule. No route uses `:8443` yet.
  2. `cnt deploy <svc>` for each public route service: adds the edge
     servers, and the internal ones keep serving o002 on `:80`.
  3. o002 rebuild: the generated vhosts point at `:8443`.
  4. `blockInternal = true` on h001 (done; legacy sites unaffected, see above).

  Rollback is the reverse at any point. o002's previous generation points
  at `:80`, which keeps working throughout, and the h001 additions are inert
  without o002. Each rebuild ran as `test` under a 5-minute
  `systemd-run` auto-revert.

### 2.4 Public paths

`public` says *who* may connect; `via` says *how* the internet gets in. A
route can list several:

```nix
routes.web  = { port = 2283; exposure = "public"; via = [ "edge" ]; };   # default for HTTP
routes.game = { port = 25565; proto = "tcp"; exposure = "public";
                via = [ "router" ]; name = "computerboyz"; };       # DDNS + h005 DNAT
```

| `via` | Path | Good for | Generated |
|---|---|---|---|
| `edge` | client → o002 (TLS, rate limits) → tailnet → host edge listener | HTTP(S); hides the home IP | CNAME → `o002`, o002 vhost or `stream`, host edge-listener entry |
| `router` | client → `home` (DDNS) → h005 DNAT → host LAN IP:port | Games, UDP, WireGuard, large transfers that shouldn't hairpin via Oracle | CNAME → `home`, h005 forward + DNAT entry, host WAN-source rule for that port |

- **The router path is runtime-managed on h005** by `fleet-edge` (§5.2). It
  owns an nft map of forwards (`proto . port → host:port`) and the
  `home` record. `cnt deploy/move/expose` ask it to add or remove entries. The rest
  of h005's ruleset stays declarative, and expired forwards are dropped by
  h005 itself (fail closed).
- The router path **exposes the home IP** for that name. `cnt routes` and
  the dashboard mark it.
- HTTP over `router` is allowed (TLS terminates on the service host), but
  `edge` is the default for HTTP.

## 3. Isolation: private container networking (the default)

Host networking is the root of the shared-loopback and port-collision
problems. **Decided: private networking is the default for every container,
arr included.**

- Each container gets a veth with a stable `10.233.<n>.2` (allocated from
  the service name, recorded on the host). Apps keep their **native** ports
  (no global port registry, no collisions on move).
- Host nginx proxies `http://10.233.<n>.2:<port>`. The container's own
  firewall admits only the host side of the veth, and only on route ports.
- Container → container traffic (open-webui → litellm/searx) uses a declared
  `uses = [ "litellm.web" ]` that adds exactly that allow rule. Otherwise it
  goes through the tailnet name like any other client.
- `network = "host"` stays available as an explicit, reasoned exception, and
  the dashboard flags it.
- Podman-kind gets the same treatment (publish to the bridge IP, never
  0.0.0.0).

**arr on private networking** is the hardest case:

- The VPN namespace (sabnzbd, transmission) moves *inside* the guest, which
  owns its WireGuard netns. `51820/udp` stops being a host port.
- QSV: bind `/dev/dri/renderD128` into the guest as now. It works the same
  on a private network.
- NFS stays mounted on the host and bind-mounted in, and the h004 guard
  still binds `container@arr`.
- Every arr UI becomes a route through host nginx: sonarr, radarr, prowlarr,
  bazarr, sabnzbd, transmission, jellyfin, seerr, kavita, audiobookshelf,
  shelfmark. `mods/arr-nginx.nix` and the host `:9091` proxy go away, and
  each app's base/external URL matches its route.
- The apps keep talking to each other on the guest's loopback (same
  container), so their stored API URLs (`localhost:8989`, ...) keep working.
- Jellyfin DLNA/discovery (UDP 1900/7359) doesn't cross a veth. Drop it, or
  declare `lan` UDP routes if TV clients rely on it.

Rollout is per service through the existing deploy → verify loop. arr goes
last on h001 because it has the most state and external clients (TV apps).

## 4. Auth

Per route, `auth` is one of:

| Value | Meaning | nginx does |
|---|---|---|
| `native-oidc` | App logs in against zitadel itself | nothing |
| `native` | App has its own accounts (not SSO) | nothing |
| `oauth2-proxy` | Gate in front: zitadel login, optional `groups = [...]` | `auth_request` to a shared oauth2-proxy, `X-Auth-Request-*` headers to the app |
| `none` | Truly open | nothing; refused for `public` (see §2.1) |

`oauth2-proxy` routes also take `bypass = [ "/api/" ]` for paths used by
mobile apps/CLIs with their own tokens. Those paths must authenticate
natively, so the plan lists them per service.

**One oauth2-proxy for the whole fleet**, not one per host or per app.
oauth2-proxy keeps sessions in an encrypted cookie on `.joshuabell.xyz`, so
one instance can gate any number of apps on any host: every host's nginx
does `auth_request` to it, and per-route `allowed_groups` come along as a
query parameter. Per-host instances would only save a LAN round trip
(about 1 ms per request) and would mean several cookies and client
registrations. Trilium's private instance folds into it.

**Cookie trust boundary.** A cookie on `.joshuabell.xyz` is sent to *every*
HTTPS subdomain. Encryption and `HttpOnly` don't stop the receiving server
from replaying it, so:

- **Every name under `joshuabell.xyz` must point at a server we control**
  (o002, home, fleet hosts). `fleet-edge` refuses CNAMEs/A records to
  external targets inside the zone; anything external lives on another
  domain. If that ever has to change, switch oauth2-proxy to host-scoped
  cookies (one login per app) first.
- **nginx strips the SSO cookie before proxying to any backend**
  (`proxy_set_header Cookie` with the `_oauth2_proxy*` cookies removed,
  generated for every route, gated or not). A compromised app never sees a
  fleet session. It gets identity via `X-Auth-Request-*` headers only,
  which nginx overwrites on every request so the client can't inject them.
- Cookie flags: `Secure`, `HttpOnly`, `SameSite=Lax`, short expiry with
  refresh.

Placement: **h005** (always on). Logging in still needs zitadel on h001,
but existing sessions keep working on h003/lio if h001 is down. If h005 is
down, the LAN is down anyway. Gated routes fail closed (nginx returns 500 if
`auth_request` can't reach the proxy). It runs as a container like any other
service, so it can move if h005 turns out too small.

Current and proposed (✓ = verified in this repo, ? = check the app's docs
at the pinned version before relying on it):

| Service | Today | Proposed | Clients that can't do a browser login |
|---|---|---|---|
| open-webui | native OIDC ✓ | `native-oidc` | API keys |
| life | own auth + OIDC ✓ | `native-oidc` | — |
| trilium | fleet oauth2-proxy ✓ (2026-10-21) | `oauth2-proxy` groups=notes, tailnet | trilium sync clients (no bypass yet) |
| vaultwarden | native | `native` (SSO support ?) | **all Bitwarden apps**, so never gate |
| atuin | native (sync key) | `native` | atuin CLI, so never gate |
| forgejo | native | `native-oidc` (? supported) | git over https, SSH :3032 |
| opengist | native | `native-oidc` (? supported) | git over https |
| immich | native | `native-oidc` (? supported) | mobile app |
| paperless | native | `native-oidc` (? allauth) | mobile apps (API token) |
| dawarich | native | `native` / OIDC (?) | OwnTracks/Overland push |
| puzzles | none known | check, else `oauth2-proxy` | — |
| jellyfin, kavita, audiobookshelf | native | `native` (OIDC plugins ?) | TV/mobile apps |
| sonarr/radarr/prowlarr/bazarr/sabnzbd/seerr | native forms | `oauth2-proxy` + the app's "external" auth mode, `bypass=/api/` (API key) | each other, via API keys |
| searx | none | `oauth2-proxy` if ever > tailnet | — |
| litellm | API keys | `native`, tailnet | all clients |
| beszel hub | native (+OAuth ?) | `native`, tailnet | agents (SSH key, separate port) |
| homepage / dashboard | none | `oauth2-proxy`, tailnet | — |
| immich ML, immich pg | none / scram | `local` / `tailnet` allow=[lio] | — |

## 5. Making it real

### 5.1 Firewall

- **Decided: no host trusts `tailscale0`.** The shared tailnet module
  (`flakes/common/nix_modules/tailnet`) stops adding it. Each host opens
  exactly what it serves: the internal and edge nginx listeners (§2.3), sshd
  and declared `proto` routes, narrowed to their `allow` sources.
- Runtime: the host module already has a runtime port set filled by
  `cnt deploy`. Extend the per-service file from "port" to
  "port, proto, interface, sources".
- **Ad-hoc ports** (an `ssh -R` tunnel, a dev server): today that's the
  `ports_expose` shell helper (`essentials/unix_utils.func.sh`). It inserts an
  nft rule that only goes away with `ports_reset` or a reboot. Replace it
  with `cnt port open 8000 [--on tailnet|lan] [--from lio] [--for 1h]`. That
  uses the same runtime set, has a mandatory expiry, and shows up in
  `cnt routes --host` and the dashboard. `ports_expose` becomes a thin
  wrapper around it.
- Roll out carefully: sshd, the beszel hub (agents connect out to it),
  sec-agent, nix-serve (lio), DNS on h005 and headscale DERP all rely on
  the trust today. Inventory
  each host with `ss -ltnup` first, then add the needed rules to the host
  config **before** removing the trust.
- Headscale ACL: high trust = untagged `josh@` nodes (full mesh, as now),
  `tag:lowtrust` = treated as internet. Give servers a `tag:server` only if
  a need comes up; per-route `allow` covers device-level limits.
- **Low-trust devices don't use tailnet DNS** (decided): they run with
  `--accept-dns=false` (the "Use Tailscale DNS" toggle off in the app).
  At home they ask the LAN DNS on h005 and get the LAN IP; away they ask
  public DNS and go through o002. That's the right answer in both places.
  - Rejected alternative: an ACL letting `tag:lowtrust` reach h005 `:53`.
    Headscale ACLs can be that narrow (`dst = [ "h005:53" ]`), but h005 would
    then answer over the overlay with public IPs, and low-trust phones at
    home would go out through o002 instead of staying on the LAN.
  - This is a per-device client setting, so it can be forgotten.
    `cnt audit` can't see it; the onboarding note for low-trust devices
    has to say so. If one is missed, its `joshuabell.xyz` lookups most
    likely time out (h005 is unreachable for it): noticeable and safe, but
    untested.

### 5.2 Generated pieces and who writes them

| Piece | Source today | Generated by | Where |
|---|---|---|---|
| Host vhost | `nginx` string | `cnt deploy` from `routes` | `/var/lib/fleet-containers/nginx/<svc>.conf` (exists) |
| Firewall | `tcpPorts` + host files | `cnt deploy` | runtime port set (exists, extended) |
| Tailnet + LAN DNS | `fleet.nix` `h001Subdomains`, h005 `_constants.nix` host records | `fleet-edge` on h005 | dnsmasq `hostsdir` (re-read via inotify, no restart) |
| Router forwards | none (h005 has no forwards) | `fleet-edge` on h005 | nft map |
| Public DNS | hand edits in bunny, h005 `ddns.nix` (`home`) | `fleet-edge` on h005 | bunny, CNAMEs per §2.2; DDNS folds in |
| Public edge (o002) | `o002/nginx.nix` | `cnt deploy`/`move`/`expose` | o002 runtime include dir (o002 gets the host module with `nginx.enable`) |
| Certificates | h005-issued wildcard, pushed to h001 + o002 (§8 step 4) | `fleet-edge` on h005 | wildcards issued on h005, distributed via sec to the hosts that terminate TLS |

**`fleet-edge` on h005.** h005 is the always-on networking box, so it owns
everything that touches the bunny key or the WAN:

- It's the **only** holder of the bunny API key: DDNS, public records and
  DNS-01 for the wildcards. h001's `security.acme` and its copy of the key
  are gone (§8 step 4, done 2026-10-21/22).
- It manages tailnet/LAN DNS records, router forwards and DDNS names for
  `via = "router"` routes.
- It also manages **standalone DNS records** in `joshuabell.xyz` that
  aren't tied to a service (CNAMEs to `o002`/`home`, TXT, MX). External
  targets are refused (§4, cookie boundary).
  They're declared in one file (`flakes/fleet-edge/records.nix` or the h005
  config), and `cnt dns ls|diff|apply` shows and syncs them. Runtime
  `cnt dns set <name> CNAME x --for 1d` works like `expose`: an override with
  an expiry.
- **Record ownership**: it only ever touches records it created (tracked in
  its state, keyed by bunny record id). Unknown records in the zone are
  reported by `cnt dns diff` and can be adopted explicitly, never deleted
  silently. The first run is an import: diff only.
- **Validation is against the declared route plus effective exposure**, not
  the baseline. A request is accepted if the route exists in the deployed
  service definition with that target host:port, and its effective
  exposure (baseline, or an authorized override that hasn't expired)
  allows it. So `cnt expose puzzles.web public --for 2h` works for a route
  declared `tailnet`, but nobody can forward a port that no service
  declares.
- **h005 is the authority for overrides.** It stores them (by, at, until,
  reason) and expires them itself, then tells the host to reload. Hosts keep
  a copy so their own listeners also close at expiry if h005 can't reach
  them. Both sides fail closed.
- Its API is narrow and authenticated, on h005's overlay IP, from admin
  devices only. Every change is logged.
- **Packaging**: a separate top-level flake, `flakes/fleet-edge` (stdlib
  Go, like `flakes/ports`), with a NixOS module. h005 imports it as an
  input. The CLI talks to it over HTTP and shares no code beyond a small
  JSON schema.

Ordering, so a half-done change fails closed: on add, backend → host vhost →
DNS → edge; on remove or downgrade, the reverse. Each step is validated
(`nginx -t`) with the existing keep-previous/`.broken` rollback.

### 5.3 Runtime changes

```
cnt routes [svc]                         # declared vs effective, per route
cnt expose puzzles.web public --for 2h   # temporary override, auto-expires
cnt expose puzzles.web tailnet           # back down now
cnt expose --reset puzzles               # drop overrides, back to service.nix
```

- service.nix is the baseline. Overrides carry `by`, `at`, `until` and a
  reason and are shown everywhere as **overridden**. h005 (`fleet-edge`)
  holds the authoritative copy and the service's host keeps a mirror in
  `/var/lib/fleet-containers/overrides/<svc>.json`.
- Expiry is enforced by both h005 and the host (a timer re-applies the
  baseline), never by the CLI remembering.
- `cnt move` carries the overrides and re-points DNS, o002 and router
  forwards to the new host.
  The edge proxies to the new overlay IP only after the backend passes its
  health check there.
- `cnt expose` changes **ingress**. `cnt online` (already in the CLI) changes
  **egress** for `internet = false` services. They're independent, and
  the dashboard shows both.
- Upgrades to `public` print the auth mode and ask for confirmation. `none` +
  `public` needs `--no-auth-i-am-sure`.

### 5.4 Dashboard (read-only first, decided)

Served by **`fleet-edge` on h005** (`net/http`, `html/template`, embedded
assets; no JS framework):

- **Read-only first**: every container on every host: host, state,
  declared vs actual host, each route (name, exposure, auth, overridden and
  until when), health (HTTP check through the same path a client uses),
  backup age, requirements. Also DNS records, router forwards and cert
  expiry.
- **Data source**: each host runs a tiny read-only status endpoint (from
  the host module) that h005 polls over the tailnet. h005 does **not** get
  ssh keys to the fleet, so the box facing the WAN can't run commands on
  other hosts.
- Route `exposure = "tailnet"`, `auth = "oauth2-proxy"` groups=admin, nginx
  on h005 in front.
- **Actions later** (start/stop/expose/move), behind a separate admin group.
  Every action is written to an audit log. Exposure and DNS actions can be
  done by fleet-edge itself. Lifecycle actions start as "copy this `cnt`
  command" buttons; h005 would only get deploy rights after a deliberate
  decision.
- Replaces homepage-dashboard's link list (the links are generated from
  `routes`, so they can't go stale).

## 6. Requirements

Every item here is in scope. Each is built in the step (§8) that introduces
the piece it protects.

1. **Audit command**: `cnt audit [host]` compares the declared routes against
   actual listeners (`ss -ltnup`), the nft ruleset, DNS answers and o002
   vhosts, and flags anything reachable that isn't declared. Run it in CI or
   nightly. Today it would flag the 0.0.0.0 list in §1. It also flags
   bunny records `fleet-edge` doesn't own and stale o002 sites.
2. **Mobile/CLI clients vs oauth2-proxy**: gating breaks Bitwarden, immich,
   Jellyfin, atuin, git-over-https. Those stay `native` or need `bypass`
   paths that authenticate natively.
3. **Forwarded headers**: trusted only on the edge listener, from o002
   (§2.3). Access decisions never use them.
   - **Stale edge config**: if o002 is unreachable during a downgrade, it
     keeps the old vhost. That's harmless because the host's edge listener no
     longer serves the route; `cnt audit` reports the leftover.
   - **Router forwards bypass o002's protections** (rate limits, hidden home
     IP). Keep them for non-HTTP routes and list each one loudly. If h005 is
     down, they're all closed.
4. **Edge hardening on o002**: per-route `rateLimit`, `maxBody`, optional
   geo/allow lists, and fail2ban/crowdsec on auth endpoints of `public` +
   `native` routes (vaultwarden, immich, jellyfin logins).
5. **HSTS**: don't send `includeSubDomains` on the apex while some names are
   plain http on the tailnet.
6. **The bunny DNS key** can rewrite the zone, so only `fleet-edge` on h005
   holds it (§5.2). A single issuer also stays well clear of Let's Encrypt
   rate limits.
7. **Split-horizon drift**: if tailnet DNS and the edge disagree after a
   move, tailnet users and public users hit different hosts. `cnt move`
   updates both, and `audit` checks them.
8. **Non-HTTP**: forgejo SSH 3032, minecraft 25565, the arr WireGuard
   51820/udp and immich pg are `proto = "tcp"`/`"udp"` routes. Public ones use
   `via = "router"` or an o002 `stream` (no TLS termination, no auth, so they're
   listed loudly on the dashboard).
9. **Health checks**: per route `health = "/api/health"`. They drive the
   dashboard, gate `move`, and could feed an alert (ntfy) when a public
   route goes down.
10. **Secrets in URLs/headers**: never put API keys in generated nginx
    files. Those files are readable on the host and shown by `cnt status`.
11. **IPv6**: every rule needs a v6 twin (nginx `listen [::]`, nft ip6). The
    audit covers both.
12. **h005 is now a single point of failure** for DNS, routing, auth
    (oauth2-proxy) and the dashboard. That's acceptable because it already is
    one for the LAN. Its config stays small, it gets its own restic job for
    `fleet-edge` state, and that state can be rebuilt from git (routes +
    records) and bunny. Its UPS (NUT) is already there.
13. **The WAN-facing box holds the most powerful key.** Keep it tight:
    `fleet-edge` runs as its own user with systemd sandboxing, listens only
    on the overlay IP (never WAN), and isn't reachable from `tag:lowtrust`.
    The bunny key goes through sec, scoped if bunny ever supports per-zone
    keys.
14. **Who can call fleet-edge**: authenticate the CLI with per-device
    tokens (or tailnet identity via headscale's whois, if exposed) rather
    than one shared secret, so one lost laptop can be revoked.
15. **Certificate distribution**: a renewal on h005 has to reach every TLS
    host before the old cert expires. Hosts pull from sec on a timer and
    reload nginx. The dashboard and `audit` show each host's cert expiry,
    and an alert fires at < 14 days.
16. **DNS TTLs**: use short TTLs (60–300 s) for records that `move`/`expose`
    change, or a move is slow to take effect for public clients. Negative
    caching (a lookup before the record existed) lasts as long as the SOA
    minimum.
17. **Dynamic home IP**: router names are CNAMEs to `home` (§2.2), so DDNS
    updates one record. IPv6 router forwards are firewall opens, not DNAT;
    both are generated.
18. **Hairpin**: LAN clients that only have the public name of a
    router-path route (e.g. a friend's console on your wifi) get the LAN
    answer from h005's DNS, so no NAT reflection is needed. Clients with
    hard-coded DNS (8.8.8.8) need reflection or won't connect; decide per
    route.
19. **Bootstrap / ordering**: fleet-edge needs DNS, sec and the tailnet up.
    The router's own LAN/WAN must never depend on it, so it only adds to
    the declarative base and a broken fleet-edge leaves h005 routing
    normally (with forwards closed).
20. **Rate limits**: Let's Encrypt (wildcards, so few certs) and the bunny
    API. Batch DNS changes per deploy and back off on 429s.
21. **Undeploy**: removing a service (or a route) must remove its DNS,
    forwards, o002 site and overrides. `cnt destroy <svc>` (exists today)
    does this, and `audit` finds orphans.
22. **SSO cookie scope** (§4): no external targets in the zone, the SSO
    cookie stripped before every backend, `X-Auth-Request-*` always set by
    nginx.

## 7. Decisions

Taken 2026-10-16:

1. **Private container networking is the default**, arr included (§3).
2. **Namespace chosen per route** (`zone = "main" | "private"`, §2.2).
3. **No host trusts `tailscale0`**. Each gets an explicit per-service
   firewall, and ad-hoc ports use `cnt port open --for` (§5.1).
4. **Dashboard starts read-only**, served by `fleet-edge` on h005 (§5.4).
5. **Public paths are `edge` (o002) or `router` (h005 DNAT + DDNS)**, both
   runtime-managed (§2.4).
6. **h005 runs `fleet-edge`** and is the only holder of the bunny key (§5.2).
7. **One fleet-wide oauth2-proxy on h005** (§4).
8. **Trust tiers**: untagged = high trust (tailnet), `tag:lowtrust` = public
   client. One name resolves three ways: public → edge, LAN → host LAN IP,
   high-trust tailnet → overlay IP (§2.1).

9. **Low-trust devices use `--accept-dns=false`** (§5.1).
10. **Public DNS**: zone `joshuabell.xyz` only, every public name a CNAME to
    `o002` (edge) or `home` (router) (§2.2).

## 8. Suggested order

1. **Done.** `routes` schema in service.nix + CLI generation of the host vhost and
   firewall, keeping the `nginx` string as an escape hatch while services
   are converted. `cnt routes` and `cnt audit` (read-only) exist
   (`containers/cli/routes.go`).
2. **Done 2026-10-22.** `cnt port open|ls|close` exists (`containers/cli/port.go`):
   it opens a port on a host for a limited time without a rebuild, by
   adding elements to three nft sets (`cnt-tmp`, `cnt-tmp4`, `cnt-tmp6`)
   that the host module's firewall rules match and the kernel expires;
   `port ls` lists the live elements and `port close` removes them early.
   `ringofstorms.tailnet.trustInterface = false` per host (`firewall.nix`);
   live `nft` trusts only `lo`. Rolled out with a 10-min auto-revert and
   probes before/after:
   - h001 (gen 845): 9101 from h005 only.
   - h003 (gen 10): 80/443 on tailscale0; 9101 from h005 only.
   - h004 (gen 7): none (NFS is LAN, opened globally).
   - h005 (gen 28): 53 tcp/udp and 80 on tailscale0; 443 (private-zone);
     oauth2-proxy rule.
   - i001 (gen 39): none (tailnet LLMNR 5355 now refused).
   - joe (gen 73): localai 8080 from h005 only (pre-DNAT).
   - lio (gen 1231): 22 on tailscale0; nix-serve 5000 from juni/gp3/oren.
     Verified by store path only (no root here).
   - o002 (gen 64): none (80/443/3032, 3478/udp are public).
   - juni (gen 159), gp3 (gen 8), oren (gen 25), deployed 2026-10-22:
     none on tailscale0 (laptops; global 22, kdeconnect 1714-1764,
     41641/udp and oren's 9991 remain; beszel agent connects out).
     Inventory: only sshd, kdeconnect, LLMNR 5355, tailscaled. Probes from
     lio after `test`: ssh 22 and kdeconnect 1716 open, tailnet LLMNR 5355
     now refused (9991 on oren has no listener). The tailscaled peerapi port
     still answers: tailscaled serves it itself, so nft doesn't see it.
     oren's opencode build fixed by bumping it to lio's pin (8a8bd62)
     with lio's node_modules hash and `postInstall = ""` overrides.
   - l002, t: **not on the module.** They have no NixOS config in this repo,
     only ssh aliases in `fleet.nix`, outside `deployableHosts`. t is a
     macOS laptop (Darwin, no tailscale CLI). l002 (public IP, root) timed
     out on 22.
   - The edge hop o002 → host is plain `http://<overlayIp>:8443` with the
     route `Host`; https or no `Host` fails by design.
   - **Explicit per-host firewall, generated from the inventory
     (deployed 2026-10-26/27).** Replaces the blanket 22/80/443 allows
     above with rules computed from `fleet.nix` + `containers/lib.nix`.
     ssh: `firewallHighTrustIps` (trust = "high" overlay IPs) only, on
     `tailscale0`, guarded by `sshGuardAssertion` (fails eval if the list
     is empty or excludes lio's overlay IP, so a typo can't lock out
     lio). 80/443: `100.64.0.0/10` accept, minus an explicit drop per
     `tailnetExcludedOverlayIps` (o002 + low-trust hosts) ahead of it so
     the drop can't be shadowed, on every host with `cfg.nginx.enable`
     (conservative: no inventory service uses a legacy `nginx` string
     anymore, but hand-kept vhosts outside the inventory can't be
     enumerated). LAN: `fleet.global.lanSubnet` accept on 80/443 where
     the host has a `lanIp` and a lan/public `routes` exposure (or the
     legacy `nginx.acl.lan`). `guest-egress`: ve-* containers whose
     packet already cleared fleet-net's egress filter get re-admitted
     into nixos-fw by the same `inet fleet-net egress` set (guest .
     daddr . proto . port), not a blanket `ve-*` allow. h005
     (`hosts/h005/firewall.nix`) and lio (`hosts/lio/configuration.nix`)
     compute the same high-trust ssh list themselves (excluding
     o002/self) since h005 doesn't trust tailscale0 as an interface and
     both need their own local rules; h005 additionally scopes its own
     80/443 (fleet-edge dashboard, oauth2-proxy sso-proxy) to the
     tailnet-minus-excluded set the same way. oauth2-proxy's 4180 client
     list is generated from `inputs.containers.inventory.containerHosts`
     instead of hand-kept. o002 is unchanged: global `:22` stays as a
     deliberate break-glass exception.
     Rolled out 2026-10-26/27 host by host (10-min `systemd-run`
     auto-revert, full `/tmp/fw-live/probe.sh` matrix before disarming):
     h001 (gen `...275n04s`), h003 (`...k3iskvx`), h004 (`...hcavyl7`),
     h005 (`...h296snyg`), i001 (`...1qvpvyk`), joe (`...nqba7i4`); lio
     (gen `20261025.1f607aa`, deployed via root@lio, verified from
     h001/h005). Incidental fix in the same window: lio's LAN IP had
     drifted to `10.12.14.118` with no dnsmasq reservation; `fleet.nix`
     now matches and h005 carries a static lease for it (no lio rebuild
     needed for that part).
3. Internal/edge listener split (§2.3, §2.3.1), o002 generated vhosts and
   a wildcard. This retires the hand-kept o002 list. **Done 2026-10-20**;
   the o002 wildcard has been deployed since 2026-10-21 (§8 step 4,
   Certificates bullet).
   `blockInternal` is on for h001 (generated vhosts only; see §2.3.1).
4. `flakes/fleet-edge` on h005: tailnet/LAN DNS records (retires
   `h001Subdomains` and the hand host records), bunny import (diff only,
   adopt existing CNAMEs) + `cnt dns`, DDNS folded in, then cert
   issuance (retires h001's bunny key), then router forwards + DDNS
   (minecraft back online). **Design and status (2026-10-20):**
   - **Records are build-time Nix, not runtime.** `containers/lib.nix`
     `dnsRecords { dir; hosts; }` gives `tailnet` (every non-local
     main-zone route → host overlay IP), `lan` (lan/public → host LAN IP,
     if it has one) and `public` (public → CNAME `o002`, or `home` for
     `via = router`). `hosts/h005/dns-records.nix` adds the few hand names
     (unconverted trilium/arr names, `secrets.h001.net`) and throws if a
     hand name is also generated. Both dnsmasq instances render them.
     h005 reads the repo's working tree by path, like other containers/ nix,
     so a route change takes effect on the next h005 rebuild. No runtime
     path: records only change when a service.nix changes, which is already
     a commit and a deploy. A runtime writer (hostsdir + inotify) would add
     a second source of truth and a failure mode for every lookup, and
     saves only one rebuild. Revisit with `cnt expose`/`move` (step 7/9),
     where a hostsdir fed by fleet-edge is the natural extension. **Done**:
     h005 switched; `h001Subdomains`/`lioSubdomains`/`localDnsRecords` are gone.
   - **Public (bunny): declarative reconcile from h005, plan first.**
     `dns-records.nix` `publicSpec` = generated CNAMEs + hand names
     (anchors `o002`/`headscale` A, o002 hand vhosts, `minecraft`), TTL
     300. `fleet-edge dns-plan` (read-only GET) compares it with the zone:
     create / update / keep / **conflict** (another type in the way, e.g.
     the old `docs` A record; never replaced automatically) / **external**
     (`home`, written by DDNS) / **unmanaged** (everything else: mail,
     DKIM, old names; never deleted). Ownership = the spec; anything not
     in it is someone else's. **Applied 2026-10-21** with
     `fleet-edge dns-plan --apply`: it executes only create/update rows and
     exact-match `retire` rows (name + type + value in `publicSpec.retire`),
     and refuses the whole run on any conflict or `retire-mismatch`. First
     apply: 19 TTL updates (3600→300) + 10 retires (docs A 100.64.0.13,
     l001, o001, element, etebase, kura, matrix, n8n, pim, pkm); re-plan
     0/0/0. The pre-apply plan (old values = rollback data) is in
     `/root/bunny-backup/` on h005. DDNS stays the `ddns-update` timer for
     now and folds in later as a spec entry with a dynamic value.
   - **Certificates: one wildcard issued on h005, pushed (not via sec).**
     sec can't carry it: only the `admin` role may write, only to existing
     paths, so a machine can't publish a renewal. `hosts/h005/wildcard-cert.nix`
     issues `joshuabell.xyz` + `*.joshuabell.xyz` (DNS-01, bunny key from
     sec-agent) and `wildcard-push` sends the pair over root SSH (nix2nix
     key, pinned host keys) to o002 and h001 after each issue/renew + daily.
     `hosts/_shared_assets/utilities/wildcard-cert-receiver.nix` validates (expiry, key matches cert),
     swaps the files under `/var/lib/fleet-cert/<domain>/` and reloads nginx.
     Vhosts opt in with `config.fleet.wildcardTls` (lib `edgeVirtualHosts`
     already takes `tls`). Not §9.2: no container grant involved. Then
     h001 drops its own ACME cert and bunny grant. **Deployed 2026-10-21**;
     h001 has no ACME or bunny key, old per-name ACME dirs removed
     2026-10-22.
   - **Router forwards: build-time too.** `lib.nix` `routerForwards` lists
     public `via = router` tcp/udp routes of services with a host → DNAT to
     the host's LAN IP (`networking.nat.forwardPorts`) plus one exact
     accept rule in h005's `router-isolation` chain
     (`hosts/h005/router-forwards.nix`). IPv4 only, no hairpin (LAN DNS
     answers the LAN IP). Inactive service (`host = null`) → no forward.
     minecraft is converted (`routes.game` tcp 25565 via router,
     `routes.web` = squaremap at `computerboyz` via edge). **Code done, off by
     decision.** **Before re-enabling** (minecraft stays off): a tcp/udp route has `fqdn = null`, so `dnsRecords` gives it
     no tailnet or LAN record; `minecraft` only exists as the public CNAME
     → `home`, and with no hairpin NAT a LAN player resolving it gets the
     WAN IP and fails. Give raw routes a DNS name first (tailnet/LAN →
     host IP, public → `home`).
   - **Order**: DNS (done) → bunny apply (done) →
     minecraft (restore on a LAN host, set `host`, deploy, rebuild h005
     for the forward, rebuild o002 for the generated `computerboyz`, drop
     its hand vhost and hand CNAME) → wildcard on h005 + distribution →
     drop h001's key. **Rollback**: h005 previous generation (DNS and
     forwards are in the system closure); bunny via the plan's old values.
   - **Stays hand-kept**: unconverted service names (trilium, arr) in
     `dns-records.nix`; apex/www/ellalala/headscale/o002 on o002; mail
     and DKIM records (unmanaged).
5. Private container networking, service by service, arr last.
   **Done for every nixos-kind inventory service** (all on `net.private`,
   arr last at index 16). Remaining on the host network by design: the
   two podman services (opengist on h001's podman0 bridge, localai on
   joe with GPU passthrough), the hello-nixos/hello-podman test pair, and
   minecraft (host = null, inactive; its `via = router` route needs host
   networking when re-enabled). **Design (2026-10-21); mechanism built, puzzles first:**
   - **Opt-in per service**: `net = { private = true; index = <1-254>; }`
     in service.nix. `index` is explicit and **fleet-wide unique**: the
     inventory eval throws on a duplicate. It's never derived from the name,
     so renames and hash collisions can't move an address. The guest is
     `10.233.<index>.2`, the same on every host, so a `move` changes nothing.
     The host side of every veth is the same `10.233.0.1` (point-to-point
     /32 routes, as nixos-containers sets up `hostAddress`/`localAddress`).
     Name ≤ 11 chars (`ve-<name>`). Without `net.private`, the host network
     stays as today.
   - **Guest** (`mkNixosContainer`): `privateNetwork = true`, those
     addresses, `useHostResolvConf = false`, nameserver `10.233.0.1`, and
     the guest firewall **on**, admitting only the service's route ports.
     container.nix binds `fleetNet.bindAddress` (specialArgs:
     `127.0.0.1` on the host network, `0.0.0.0` when private), so
     flipping the flag needs no other edit.
   - **Host side up before the guest boots**: nixos-containers only
     configures `ve-<name>` in `container@`'s postStart, which runs after
     READY, so guest units that need the network at boot (litellm's model
     fetch, ACME, DB connections) failed. The host module adds a udev rule
     (`SUBSYSTEM=net, KERNEL=ve-*, ACTION=add`) → `fleet-veth@ve-<name>`
     oneshot that reads `/etc/nixos-containers/<name>.conf` and sets
     `10.233.0.1/32` + the guest's /32 route the moment nspawn creates the
     veth (before the guest's init). It needs no networkd (h001 runs
     dhcpcd, which denies `ve-*`; NM hosts get `unmanaged = ve-*`).
     `mkNixosContainer` replaces the stock postStart with an idempotent
     `ip addr/route replace`, so hosts without the hook still work (late).
     Restarts, `cnt deploy` and host reboots all create a fresh veth, which
     fires the rule again. Evidence: the host `fleet-veth@` journal (done before the
     guest init starts). No in-guest boot probe: a oneshot ordered on READY
     would recreate the stall when egress is down.
   - **Host** (`ringofstorms.containers.privateNetwork.enable`, replaces
     the old trust-`ve-+` + NAT option, which no host used): tables
     `inet fleet-net` (filter) and `ip fleet-net-nat`:
     - `ve-*` is **not** trusted. Input from `ve-*` gets DNS on
       `10.233.0.1:53` (resolved `DNSStubListenerExtra`, so containers
       see the same split-horizon answers as the host) plus whatever the
       host already opens on every interface (22/80/443, ports files).
       Host loopback services (`127.0.0.1:*`, the old shared-loopback
       problem) are unreachable.
     - Forward: `ve` → `ve` new connections are dropped (no container
       reaches another directly); `→ ve` is admitted only for DNATed flows.
     - **Egress**: masquerade `10.233.0.0/16` out of any non-`ve`
       interface (internet, LAN, tailnet, as on the host network today).
       `internet = false` now also works for nixos-kind, but only with
       `net.private`: the ports file carries `noinet ve-<name>`, and the
       host drops new forwarded connections from that interface. DNS on
       the host stays allowed, and so do replies to inbound connections.
   - **HTTP**: `routes.go` proxies to `http://10.233.<index>.2:<port>`
     instead of `127.0.0.1`. ACLs, edge, auth and DNS are unchanged: the
     host nginx is still the only way in.
   - **tcp/udp routes** (forgejo ssh 3032, beszel 8090, immich pg 5432):
     the ports file line becomes `dnat <proto> <port> <guest ip>`.
     `fleet-containers-ports` flushes and refills the `fleet-net-nat @routes` map (v4
     only) from the files after every firewall reload. Prerouting/output
     DNATs `fib daddr type local` traffic on that port to the guest, and
     forward admits `ct status dnat`. That's the same reach as `tcpPorts`
     today (any interface). Per-route `allow` (immich pg → lio) is a
     source match (`allow = [ "lio" ]`) on the route's tailnet exposure.
     **Done**: immich is private (index 15); routes.pg/routes.ml DNAT to
     the guest with that allow list, not the host network. DNAT ports never touch `temp-ports`.
     `cnt port open` refuses private services (use a route; a temp DNAT
     is later work). `fleet-publish`/podman are unchanged: podman already
     has its own bridge, and its publish → bridge IP is a separate item.
   - **Audit**: a private service's route ports are owned by the guest.
     A host listener on one (loopback included) is `STALE` (the old
     host-network instance or a port leak). DNAT ports don't show up in
     `ss`, by design.
   - **Inter-container**: no direct path. Callers use the route name
     through the host nginx (sec, zitadel OIDC, litellm). Input 80/443
     from `ve-*` is open, but nginx ACLs see `10.233.x.2`: public routes
     work, tailnet/lan routes refuse it. Before migrating a caller of a
     tailnet route (open-webui → litellm), add `uses = [ "litellm.web" ]`,
     which adds the guest IPs to that route's ACL. Order matters: callees
     before callers, otherwise nothing changes. sec/zitadel are public
     routes, so they're fine.
   - **Data**: persist/binds/devices unchanged (idmapped binds don't care
     about the netns). Containers bound to a host-network service's
     socket would break, but there are none.
   - **Migration per service**: set `net`, make container.nix bind
     `fleetNet.bindAddress`, then `cnt deploy`. The container restarts on
     the veth, the vhost/ports file switch to the guest IP, and the old
     host port disappears with the old instance. Downtime = one container
     restart. **Rollback**: drop `net` (or `git revert`) and redeploy;
     the host part is inert without private services. Probe: route through
     the edge and tailnet, `ss` on the host, `cnt audit`, egress from the
     guest, and a blocked `curl 10.233.0.1:<loopback port>`/other-guest IP.
   - **CLI**: `deploy` (vhost upstream, `dnat`/`noinet` ports lines),
     `audit` (STALE), `port open` (refuse), the inventory check (unique
     index). `routes` shows `net` in a later pass.
   - **arr (done 2026-10-22, index 16)**: the guest owns the `wg` netns
     (VPN-Confinement runs inside it; `/run/netns` is no longer bound from
     the host, and the host `wg-br` is gone). A guest unit sets
     `ip_forward=1` before `wg.service`. sonarr/radarr keep `localhost:9091`
     through a guest socat into the netns. sonarr, radarr, prowlarr,
     bazarr, sabnzbd, transmission = `tailnet`/`none` http routes; the
     *arr apps use `auth.method = External` (no login, the route is the
     gate). sabnzbd's login comes from its host-managed secrets.ini (user
     decision). Jellyfin `:8096` direct = `jellyfin-direct` tailnet tcp
     route (DNAT on the overlay IP only). `firewall.nix` arr opens and the
     `:9091` vhost are gone; fleet-edge links use the route names. DLNA
     dropped.
   - **Tailnet DNAT guard (2026-10-22)**: `cli/fleet-net-nat.nft`. Prerouting
     consults `@routes_at`/`@routes_from` only for `iifname tailscale0`,
     `saddr 100.64.0.0/10`, not in `@edge` (nginx.edge.peers v4), or for a
     declared local caller (`@uses`, from the ports-file `allow` lines).
     Output (the host itself) is unchanged; public `@routes` (forgejo
     3032) stay any-interface. Before: o002 and LAN packets to the overlay
     IP reached beszel 8090 / jellyfin 8096.
   - **podman default bridge** (opengist): `podman0` jumps to the same
     guest-in/guest-fwd chains (internet + DNAT/published ports only).
     Its DNS stays 8.8.8.8 over the internet path.
6. Fleet oauth2-proxy on h005 + per-route `auth`, with cookie stripping
   from the first gated route. **Done 2026-10-21 (tailnet routes).**
   - **Where**: `hosts/h005/oauth2-proxy.nix`, a host service rather than
     a container. h005 is always on and already holds the wildcard. It
     listens on `100.64.0.3:4180`; nftables admits 4180 only from the
     container hosts (h001, h003, lio) on `tailscale0`, and those are the
     only `trustedProxyIP`s.
   - **How vhosts reach it**: **direct `auth_request` across the tailnet**,
     not h005 fronting the routes. The host vhost keeps serving the app
     (no extra hop, no h005 dependency for data), and `routes.go` renders,
     per gated route, `location = /oauth2/auth` → `http://100.64.0.3:4180/oauth2/auth?allowed_groups=<groups>`,
     `location /oauth2/` → the proxy (so `/oauth2/sign_out` etc. work on
     every name), `error_page 401 = @fleet_oauth2_signin` →
     `302 https://sso-proxy.joshuabell.xyz/oauth2/start?rd=https://$host$request_uri`,
     and `X-Auth-Request-{User,Email,Groups}` to the app. h005 down →
     auth_request fails → 500, so it fails closed.
   - **Sign-in host**: `sso-proxy.joshuabell.xyz` is now h005 (tailnet DNS,
     h005 nginx on its overlay IP, wildcard cert). It's the only redirect
     URI in zitadel, so a new gated route needs no zitadel change. Same
     client and sec key (`machines/high-trust/oauth2_proxy_key_file_2026-03-15`)
     as the old trilium instance.
   - **Cookie**: `_oauth2_proxy` on `.joshuabell.xyz`, Secure, HttpOnly,
     SameSite=Lax, 168h, refresh 12h. `whitelist-domain=.joshuabell.xyz`.
   - **Schema**: `auth = "oauth2-proxy"` plus optional `groups = [ "<zitadel role>" ]`
     (any of; via the `flatRolesClaim` claim) and `bypass = [ "/api/" ]`
     (unauthenticated `^~` prefix locations, for clients with their own
     tokens). `allow` stays the *source host* list (§5.1), not groups.
     lib.nix and `validateRoutes` refuse groups/bypass on other auth
     values, odd characters, and gated `zone = "private"` routes (h005's
     private-zone vhosts have no auth_request yet). **Gated `public`
     routes are allowed** (below): the sign-in host is public now.
   - **Cookie stripping**: every generated server, gated or not, rewrites
     `$http_cookie` minus every `_oauth2_proxy*` cookie into
     `$fleet_cookie` and sends that as `Cookie`. Identity headers are
     always overwritten (empty on ungated routes), so clients can't inject
     them.
   - **Edge vs tailnet**: the gate is rendered into the server block, so
     the internal and edge (`:8443`) servers of a route enforce it alike;
     o002 doesn't need to know. **Public gated routes are allowed**,
     done 2026-10-27: `sso-proxy.joshuabell.xyz` gets a public CNAME →
     o002 (`dns-records.nix` `publicSpec`), and an o002 vhost that proxies
     only `/oauth2/` to a dedicated edge listener on h005
     (`<overlayIp>:8443`, `hosts/h005/oauth2-proxy.nix`), admitted by
     h005's firewall from o002's overlay addresses only. o002 is excluded
     from h005's broad tailnet 80/443 accept (firewall.nix, §8 step 2), so
     it can't reach the tailnet sign-in vhost or 4180 directly; it also
     never satisfies a tailnet ACL itself. The edge listener trusts
     X-Forwarded-* only from o002 (`set_real_ip_from`), never the tailnet
     vhost. The refusal is lifted in `lib.nix`, `cli/expose.go`
     (`exposeCheck`), and `fleet-edge`'s `overrides.Check`.
   - **Legacy retired**: the trilium container no longer runs oauth2-proxy
     (no env bind). Its nginx string is replaced by `routes.web` (notes,
     tailnet, `groups = [ "notes" ]`), and `dns-records.nix` points
     `sso-proxy` at h005 and generates `notes`. The unused h001
     `oauth2_proxy_key_file` sec-agent entry has been removed
     (`hosts/h001/sec-agent.nix`).
   - **Deployed**: h005 switched (oauth2-proxy + DNS); `cnt deploy trilium`;
     `deploy --vhost-only` for every other h001 service (cookie strip).
     h003/lio generated vhosts get the strip on their next deploy.
7. `cnt expose` overrides with expiry. **Built 2026-10-22, host-local
   (tailnet/lan only).** Code: `cli/expose.go`, host module
   `fleet-containers-expose-boot` + `fleet-containers-expose-expire`
   (service + timer).
   - **CLI**: `cnt expose <svc>[.<route>] --exposure tailnet|lan --for DUR
     [--reason TEXT]` (max 24h; the route may be omitted when the service has
     one http route), `cnt expose --list [host...]`, `cnt expose --revoke
     <svc>`. One override per service. Only http routes that the host's nginx
     serves: not `local` (that's a decision, not a default), widening only
     (narrowing would cut current clients; change service.nix), not tcp/udp
     (their DNAT/allow shape depends on exposure and is a later batch), not
     `zone = "private"` (h005 serves those).
   - **What changes**: only the host vhost. The CLI renders the route with
     the new exposure (the same `routesVhost`, so the ACL include and edge
     server follow the usual rules) and installs it with the usual
     `nginx -t`/rollback. lib.nix's auth rules are re-checked
     (`validateRoutes`, and public + `auth = none` without
     `publicWithoutAuth` is refused before anything else).
   - **State** on the service's host: `/var/lib/fleet-containers/overrides/<svc>/`
     `override.json` (service, route, exposure, baseline, at, until, by,
     reason) and `baseline.conf` (the service.nix vhost). It's written
     **before** the wider site, so a failure partway still gets reverted.
   - **Expiry, enforced by the host, fail closed** (split 2026-10-25):
     - `fleet-containers-expose-boot` (`expose-expire --boot --all`,
       `Before=nginx`) reverts expired files only and **never reloads**;
       nginx starts with them, so an override that expired while the host
       was down never serves again.
     - `fleet-containers-expose-expire` (`expose-expire --all`) is the
       runtime sweep: **not ordered against nginx**, started every minute
       by its timer and by the transient `systemd-run --on-active` timer
       `fleet-expose-<svc>` 1 s after the deadline. `--revoke` runs the
       same path over ssh. It does a checked, blocking `nginx -t` +
       reload (no deadlock: nothing waits on it before nginx).
     - Revert = write `overrides/.reload-pending` (atomic), put
       `baseline.conf` back, `nginx -t`, delete the dir, then reload. The
       marker is cleared **only after a successful reload**; every sweep
       and revoke retries it first and fails while it's pending (`forever`
       overrides are untouched, but a pending reload is still retried).
       `/status.json` (`exposeReloadPending`) and `cnt expose --list` /
       `routes` / `audit` show "reload pending".
     - If the baseline no longer validates, the site is **removed** (kept
       as `.broken`), never left wide. An unreadable `override.json`
       counts as expired.
   - **service.nix wins**: `cnt deploy` (also `--vhost-only`), full
     `deploy` and `destroy` drop the service's override **last**, only
     after the new site has passed `nginx -t` and been reloaded (or, for
     `destroy`, after the site is gone). Dropping it earlier would leave a
     widened site behind with nothing left to expire it if the site step
     then failed; on failure the override and its timer stay, so expiry
     still narrows the restored site back down
     (`cli/expose.go` `dropOverrideScript`). Regression tests in
     `cli/expose_test.go` cover this: `TestVhostOnlyDeployFailureKeepsOverride`,
     `TestFullDeployFailureKeepsOverride`, `TestDestroyRemovesSiteBeforeOverride`,
     `TestVhostOnlyDeploySuccessDropsOverride`, and
     `TestReexposeFailureKeepsOldOverride` (a rejected re-expose must not
     delete the live override it was replacing).
   - **Visibility**: `cnt routes` shows `lan (OVERRIDDEN from tailnet, 2m
     left)`. `cnt audit` lists active overrides below the listener table
     (same ssh call). Every apply/revert is logged (`logger -t cnt-expose`).
   - **Not done: `public`.** It needs the public CNAME (bunny, via
     fleet-edge on h005) and an o002 vhost at runtime. Both are build-time
     today (§8 step 4), and `lib.nix edgeVirtualHosts` only knows declared
     public routes. So `--exposure public` is refused with a pointer here.
     To add it: a fleet-edge API that accepts an override (checked against
     the declared route, §5.2), adds the CNAME and tells o002 to include a
     runtime vhost, and h005 as the authority (§5.3). The host part
     (edge server on `:8443`) already falls out of `routesVhost`.
   - **LAN DNS**: also build-time (`dnsRecords`). A tailnet → lan
     override admits LAN sources at nginx, but LAN-only clients only resolve
     the name if it already has a LAN record (or they use the host's LAN IP
     with the name as SNI/Host). The CLI prints a note.
   - **Tested 2026-10-22 on h001** (gen 844): `trilium.web` tailnet → lan
     for 3m; from h003 over the LAN (`10.12.14.10`) 403 → 302 (oauth2 gate,
     so auth still applies) → 403 two seconds after expiry; tailnet unchanged;
     `cnt audit h001` clean.
   - **Not yet**: h005 as the authority, `cnt move` carrying overrides,
     `--reset` for several overrides (one per service today).
   - **Public expose design (approved 2026-10-24; deployed; live 5-minute
     trial (rollout step 5 below) not yet run).** `hosts/h005/fleet-edge.nix`
     has `overrides.enable = true` with `pushTarget`/`bunnyKeyFile`/
     `pushKeyFile` set to real credentials; o002 carries the receiver
     (`fleet-vhost-expire.timer` active) with an empty
     `/var/lib/fleet-edge-vhosts` (no override has been pushed yet).
     State read from the code at `509d4047` (the CLI lives in
     `flakes/fleet-agent/internal/containers/`).
     - **Before**: fleet-edge was a dashboard only (DynamicUser on
       `127.0.0.1:8099`, h005 nginx on the overlay IP, deny o002, allow
       `100.64.0.0/10`). `internal/auth` takes **shared** API keys, a Zitadel
       JWT or the session cookie. No write API, no bunny key; `dns-plan
       --apply` is a manual run. h005 reaches o002 only via the restricted
       `wildcardCertPushPubKey` (H2).
     1. **Authority and API.** Package `internal/overrides`, run as
        `fleet-edge overrides` in its **own unit** `fleet-edge-overrides`
        (own DynamicUser, `127.0.0.1:8098`, keys via `LoadCredential`), so
        the dashboard process never holds the bunny or push key.
        - **Separate state**: its own `StateDirectory=fleet-edge-overrides`
          (0700, UMask 0077) with its own SQLite DB (`overrides.db`) and
          audit log. fleet-edge's state is another DynamicUser's 0750 dir;
          shared write access would let a compromised dashboard edit
          override and expiry state. The dashboard and `dns-plan` see
          overrides only through the read-only `GET
          /internal/overrides.json` on the loopback port (nginx doesn't
          proxy `/internal`).
        - nginx on h005 proxies only `location /api/overrides` → 8098 (deny
          o002, allow overlay) and sets `X-Fleet-Peer $remote_addr`
          (trusted only from loopback).
        - **Auth: host machine identity.** The CLI (run as root) logs in to
          Zitadel exactly like sec-agent: `/machine-key.json` signs a
          JWT-bearer assertion, exchanged at `sso.<domain>` with the sec
          project audience scope. h005 verifies the token (JWKS signature,
          issuer, project audience, expiry) and allows it only if its `sub`
          is in `global.overrideWriters` (`hosts/fleet.nix`, host → machine
          user id) **and** the peer is that host's `overlayIp`. Roles and
          trust level are never consulted (o002 is high trust and not a
          writer). Revoke = delete the entry, rebuild h005. Audit lines carry
          `host` and `sub`. Rejected: headscale whois (headscale is on o002),
          the shared `apiKeysFile`, per-device static tokens (replaced).
        - **Endpoints**: `POST /api/overrides/prepare`, `POST
          /api/overrides/commit`, `DELETE /api/overrides/<svc>`, `GET
          /api/overrides[?verify=1]` (`verify` adds live bunny and o002
          state for `cnt audit`).
        - **Validation** (`overrides.Check`, against h005's built-in
          inventory, same rules as `lib.nix` and `exposeCheck`): route
          exists, http, not `local`, not already public, via
          edge; the inventory host equals the host the CLI names (stale h005
          inventory refuses: fail closed); `auth = none` needs
          `publicWithoutAuth`; `auth = oauth2-proxy` is allowed (sso-proxy
          has been public via o002 since 2026-10-28; lib.nix agrees). The name must
          not be declared, external or retire-listed in `publicSpec`
          (`/etc/fleet-edge/public-spec.json`), and must have no bunny
          record we don't own.
        - **Limits are not caps.** No limit on the number of active
          overrides. `--for` defaults to **8h**; any duration is allowed, and
          `--for forever` means no expiry (`until = 0` on host, h005 and
          o002). The only throttle is a soft per-device rate limit (30 writes
          per 10 min, then 429 with `Retry-After`; reads never limited).
        - **Expiry is owned by h005**: a 30 s sweep (also at startup)
          removes expired rows (o002, then DNS), retries `removing` rows,
          drops `prepared` reservations after 5 min, and removes a committed
          row whose host stops reporting the override (deploy/revoke there)
          after a 2 min grace. Host and o002 also expire on their own.
        - **Audit log**: `/var/lib/fleet-edge-overrides/audit.log` (JSON
          lines) plus the journal: every request, refusals included, with
          device, peer, user, action, target, until, result.
     2. **DNS.** Commit creates `CNAME <name> → o002.joshuabell.xyz`, **TTL
        60**, and stores the bunny record id. Delete by id only, and only
        while name, type and value still match; otherwise the row is kept
        and flagged (`dns = mismatch`).
        - **dns-plan stays safe**: `bunny.PlanWith(spec, zone, owned)` marks
          zone records owned by an active override as `override`: never
          retired, updated or counted as conflicts, and `Ops` skips them.
          `dns-plan` reads the owned list from `--overrides-url` (default
          the loopback export) and refuses `--apply` if that fails
          (`--no-overrides` only for read-only plans). Both writers hold
          `flock` on `/run/fleet-edge-bunny/lock`.
        - If `publicSpec` later declares the name (made public in
          service.nix), removal **releases** ownership instead of deleting.
        - Bunny errors fail the request closed (rollback). Negative caching:
          a lookup before the create keeps NXDOMAIN for the SOA minimum.
     3. **o002.** Runtime include dir `/var/lib/fleet-edge-vhosts/*.conf`
        (`hosts/_shared_assets/utilities/edge-vhost-receiver.nix`, `appendHttpConfig`), not
        persisted: a reboot closes them (h005's sweep re-pushes live rows;
        audit shows gaps).
        - **Push from h005 over a second restricted key**
          (`fleet.global.edgeVhostPushPubKey`, root with
          `command="fleet-vhost-receive"`, no pty/forwarding; root because it
          writes nginx files and reloads, like the cert receiver). Not the
          cert key. Pull rejected: o002 would need a credential into h005.
        - `fleet-vhost-receive` reads **JSON, not nginx text**: `{op:
          add|remove|list, fqdn, host, until, maxBody, websockets,
          buffering, requestBuffering, timeouts}` and renders the server
          block itself like `edgeVirtualHosts`: `proxy_pass
          http://<overlayIp>:8443` (host → IP map built in), the pushed
          wildcard, `limit_req`. It refuses names outside the zone or not a
          single label, unknown hosts, bad values, and names o002 already
          serves (its declared vhosts).
        - add/remove: write, `nginx -t` (same `-c` trick as the cert
          receiver), reload; on failure restore the previous file (or none)
          and exit non-zero.
        - `until` is in the file header; `fleet-vhost-expire` (every
          minute, and at boot before nginx) deletes expired files. `until =
          0` never expires locally.
        - Stolen key blast radius: point a `joshuabell.xyz` name at a fleet
          host's `:8443`, which still returns 444 unless that host serves the
          route publicly.
     4. **The service host.** `exposeCheck` allows `public` (auth rules
        kept, via edge, oauth2 refused); `routesVhost` renders the `:8443`
        edge server, which is the real gate and closes on host-local expiry
        as before. `override.json` gains `"public"`; `until = 0` = forever:
        no transient timer, never swept (revoke or deploy only). fleet-agent's
        `/status.json` reports active overrides (`overrides`), which h005
        checks on commit and in its sweep. `cnt move` refuses while a public
        override exists.
     5. **Ordering** (`cmdExpose` → `exposePublic`, client in `edgeapi.go`):
        - **Add**: (a) `prepare` on h005 (validate + reserve 5 min, no
          external writes; h005 down → nothing touched); (b) the host vhost
          (`exposeScript`); (c) `commit`: h005 confirms the host's status
          reports the public override, creates the CNAME, pushes to o002. On
          a (c) failure h005 undoes its steps (o002, then DNS) and the CLI
          revokes the host and exits non-zero.
        - **Remove** (revoke/expiry): `DELETE` on h005 (o002, then DNS),
          then the host. At expiry each side closes independently; any one
          side closed is a closed state (444).
        - **Idempotent**: repeated prepare/commit on the same svc/route
          returns current state (and may change `until`); an identical o002
          add is a no-op; a missing record/file on delete = success.
        - **Down**: h005 → add refused, revoke still closes the host, h005
          and o002 leftovers expire on their own and audit flags them. o002
          → commit rolls back; on remove DNS is still deleted and the o002
          remove retried each sweep. Host → add fails before commit; expiry
          while down is the boot sweep.
     6. **Visibility.** `cnt routes`: `public (OVERRIDDEN from tailnet, 1h
        left; dns ok, edge ok)`. `cnt expose --list`: host rows merged with
        h005 (`H005`, `DNS`, `EDGE` columns, `MISMATCH`). Dashboard
        `/services`: an "Expose overrides" section from the export. `cnt
        audit`: leftovers (host public override missing on h005, h005 row
        missing on its host, o002 file without a row, row whose DNS/edge
        isn't live).
     7. **Tests and rollout**: unit tests, no live services: fleet-edge
        `internal/overrides` (auth by token + peer, route validation,
        ordering, partial-failure rollback, sweep incl. `until = 0`,
        rate limit, audit), `internal/bunny` (owned records never retired,
        delete-by-id only if unchanged), `internal/edgevhost` (render,
        `nginx -t` rollback, expiry), `internal/server` (`/services`
        "Expose overrides" section, export down, `forever` shown);
        fleet-agent `expose_test.go` (public check, `--for forever`,
        host-local expiry), agent status export.
        - **Rollout**:
          1. h005: overrides unit with no push key / bunny credential
             configured → writes return 503; override-aware `dns-plan`;
             re-plan shows no diff.
          2. o002: receiver + empty include dir + key line, under the
             5-minute `systemd-run` auto-revert.
          3. Push/bump fleet-agent + containers on the hosts (status reports
             overrides).
          4. Create the sec items, set the key paths and one device on h005.
          5. 5-minute trial on one native-auth tailnet route from off the
             tailnet: DNS → 200 → expiry → host 444, file gone, record gone,
             `cnt audit` clean. Then `--for forever` + `--revoke`.
        - Rollback: `overrides.enable = false` on h005, drop o002's key line;
          host-local expiry still closes the host side.
8. **Done.** Read-only dashboard in `fleet-edge` on h005 (`hosts/h005/fleet-edge.nix`,
   `flakes/fleet-edge`); `homepage-dashboard` retired (h001 and joe), no
   redirects left behind.
9. **Built (2026-10-22), not yet run for real.** `cnt move` goes through
   restic (§9.1): final backup on the source, restore on the target, deploy
   and route health, restore check, first backup on the target, then the
   source becomes `.moved-<date>`. Any earlier failure rolls the target
   back: the rollback confirms the target is down (`LoadState` not-found,
   no unit file in `/etc/systemd-mutable/system`, no `machinectl` machine /
   no podman container, podman exit 1 required) before uninstalling, then
   restarts the source only after a successful rollback. A failed rollback
   does not restart the source (it stays stopped, `.was-running` kept); the
   target may still be running and must be stopped by hand following the
   printed steps. A real move is now possible between h001 and lio, the only two
   hosts with `ringofstorms.containers.backup`.

## 9. Carried over from the migration plan

The migration plan was deleted once every service was floating (sec and
zitadel last, 2026-10-17; history in git). These items are still open.

The pre-migration data copies (`/var/lib/zitadel`, `/var/lib/secrets_manager`
on h001) were archived to `/root/retired-2026-10-22-zitadel-sec.tar.zst` on
h001 and deleted on 2026-10-22; see `hosts/h001/readme.md` and
`containers/sec/README.md`.

### 9.1 Backup continuity across moves (required before any off-host `move`)

**Done (2026-10-22): per-host job in the host module.**
`ringofstorms.containers.backup.{enable, environmentFile, repository,
passwordFile, schedule, exclude, pruneOpts}` (host-module.nix) adds
`fleet-backup.service` + a nightly timer. For each `/srv/containers/<svc>`
whose unit is installed on that host (`cnt deploy` unit in
`/etc/systemd-mutable/system`; `*.moved-*` leftovers and uninstalled data
are skipped) it runs the service's `backupHook` if the unit is active, makes
SQLite `.backup` copies (live db/-wal/-shm excluded), then takes **one
snapshot per service** tagged `fleet` + `svc:<name>`, hostname = the host.
Parent selection and `forget` group by **tags only**, so after `cnt move`
the target continues the same `svc:<name>` series (retention included);
the hostname field shows where each snapshot was taken. Live PG clusters and
caches are excluded (hooks' dumps are restored instead). One failing service
does not stop the others, but the unit fails. Root helper `fleet-restic` wraps
restic with the host's credentials: `fleet-restic snapshots --tag svc:puzzles`.

h001 uses the existing repo (sec `restic_h001_env_2026-10-01`, via
configChanges, same 03:00 schedule). `hosts/h001/mods/restic-backup.nix` now
backs up only the host data (wd10 immich/paperless media, ~luser/backups)
under tag `h001`; its `forget` is restricted to `--tag h001`. Pre-2026-10-22
`h001` snapshots still contain `/srv/containers` and age out per policy.
Verified on h001: manual run, `restic snapshots --tag svc:puzzles`, restore of
puzzles to /tmp diffed clean against the live dir.

Other hosts: all hosts share **one repository** so `svc:` history follows
moves. The repo env secret `machines/high-trust/restic_h001_env_2026-10-01`
already has a `device_high_trust` role grant, so any high-trust host can
fetch it with no registry change and no sec deploy (the name is historical:
it is the fleet repo). To enable a high-trust host, add it to the host's
`sec-agent.nix` `extraSecrets` with
`configChanges.ringofstorms.containers.backup.environmentFile =
"$SECRET_PATH"` and set `ringofstorms.containers.backup.enable = true`.
lio has `ringofstorms.containers.backup` enabled (2026-10-22), using the
same repo as h001 (repo id `7f023d4a`) via the existing high-trust grant of
`machines/high-trust/restic_h001_env_2026-10-01`; no registry change. It
needs the `containers` input at ≥ 6b242c5e, so run `nix flake update
containers` in hosts/lio after the push. Verified: snapshots `771250b9`
(`svc:hello-nixos`) and `2b4175bc` (`svc:hello-podman`), taken on host lio,
are visible from h001. h003 also has `backup.enable = true` (2026-10-23,
`hosts/h003/containers.nix`, secret wired in `hosts/h003/sec-agent.nix`),
so it is a valid move target even while it runs no services.
joe is low-trust: giving it the key (vs. `device_low_trust`) is a user
decision; running `localai` there would also need to exclude
`/srv/containers/localai/{models,backends}`.

**Done (2026-10-22): `move` through restic, restore check, backup age.**

- `fleet-backup`/`fleet-backup-svc@<svc>.service` (not on PATH: both are
  `writeShellScript`, run only by units). Manual one-service run:
  `systemctl start fleet-backup-svc@<svc>.service`; manual full run:
  `systemctl start fleet-backup.service`. `fleet-restic` is the only
  helper on PATH. `fleet-backup-svc@<svc>`: one service, even
  if stopped, no prune; per-service flock. Every success writes
  `/var/lib/fleet-containers/backup-last/<svc>`
  (`time=… snapshot=<id> host=…`). SQLite copies keep the live file's
  owner/mode. `/etc/fleet-containers/backup` marks hosts with backups.
- `cnt move` (cli/move.go): 1 preflight (target and source have fleet-backup,
  target has the capabilities and is free) → 2 final backup on the source
  (hook, stop, `fleet-backup-svc@`, fresh stamp required) → 3 restore of
  that snapshot on the target (SQLite copies in place; live PG cluster dirs,
  which restic excludes, copied from the stopped source and checked by
  manifest) → 4 deploy and route health (`cnt health`) → 5 restore check
  (`cnt restore-check`: scratch restore, SQLite `PRAGMA integrity_check`,
  PG dumps non-empty, valid gzip, complete, `PGDMP` for custom format) → 6
  first backup on the target → 7 switch: confirmed stop of the source, then
  uninstall and rename to `.moved-<date>`. A failure in 2-6 rolls the target
  back (`set -euo pipefail`). It stops the unit and confirms it is down: not
  active/activating/deactivating per `systemctl is-active`, and no
  `machinectl` machine for nixos-kind. It waits a bounded time and
  `systemctl kill`s the unit if needed. If the stop itself fails, that's
  taken as proof the service was never installed (`LoadState` not-found, no
  unit file in `/etc/systemd-mutable/system`, no `machinectl` machine / no
  podman container, podman exit 1 required), and the uninstall step is
  skipped. A failed uninstall fails the rollback. Only then is the data
  moved aside as `.failed-move-<time>`, and the `move-<svc>` marker goes
  last. The source restarts only after a successful rollback, if it was
  running. If the rollback fails, the source is not restarted (stays
  stopped, `.was-running` kept); the target may still be running (that's
  why the rollback failed) and must be stopped by hand following the
  printed manual steps (no split brain). Preflight leftover cleanup uses
  the same confirmed path. Re-runs are safe (`move-<svc>` marker on the
  target, `.was-running` on the source). `--dry-run` prints the whole
  plan. Any host with `ringofstorms.containers.backup` is a valid target:
  h001, lio and h003.
- Status endpoint: `lastBackup` per service, read from the stamp (no restic).
  fleet-edge `/services` has a backup column (age, **stale** after 36h, `never`)
  and a stale count. h005 is deployed with `--override-input fleet-edge`
  from the working tree, so after the push run `nix flake update fleet-edge`
  in hosts/h005.
- Verified 2026-10-22 on h001: the full run stamped all 17 services, and
  `/status.json` and fleet-edge show their ages. `restore-check` passed for
  puzzles (2 SQLite) and forgejo (3 PG dumps).
- Step 5 needs `sqlite3` and `gzip` on the TARGET host. The host module now
  ships both under `backup.enable` (it used to rely on h001's ad-hoc
  `sqlite` in `hosts/h001/flake.nix`, so the first real move died at step 5
  with "restore check needs sqlite3 on this host" and rolled back).
- Done 2026-10-29: real move of `hello-nixos` from lio to h001 along with
  the `service.nix` host flip. Steps 1-7 passed, the target took a fresh
  `svc:hello-nixos` snapshot (`host=h001`), and the name moved with it
  (tailnet DNS is generated from `service.nix`).

Still open:

- `joe` is the only remaining backup-less container host; enable
  `ringofstorms.containers.backup` there (repo secret via sec-agent) if it
  should be a move target.
- Stale backups are only flagged on the dashboard. Nothing sends an alert
  yet (left for the monitoring work).

### 9.2 Secret grants in service.nix

Containers bind `/var/lib/secrets_manager_hydrated/<name>` read-only;
h001's `sec-agent.nix` grants them by hand (`cnt restart <svc>` after
rotation). Declare them in `service.nix` so `deploy`/`move` can refuse
early when the target host lacks a grant.

### 9.3 Identity core: break-glass and a cold-restore test — **done 2026-10-22**

Kept outside the fleet, in the password manager. These are **keys only**:

- restic env (repo, password, backend credentials);
- sec's encryption key (`/srv/containers/sec/data/db.key`);
- zitadel master key (`/srv/containers/zitadel/keys/masterkey`, 32 raw bytes,
  stored base64);
- emergency ssh key `root_fleet_backup`. Its public half is authorized for
  root on every host via common `hardening.nix`.

The keys decrypt data but don't contain it. `sec.db` and zitadel's
PostgreSQL state exist only on h001 and in the one restic repo, so a
damaged repo with h001 lost means **key recovery only, no restore**, unless
the independent copy below exists.

Both steps below are done (confirmed by the user 2026-10-22):

1. **Independent data copy**: a second backup of `/srv/containers/sec/data`
   and `/srv/containers/zitadel/{pgdumps,keys}` that doesn't share the restic
   repo or its credentials (e.g. a second restic repo on h004, or a periodic
   encrypted export).
2. **Cold-restore test** on a spare host, twice: once from a restic
   snapshot, once from the independent copy plus the password-manager keys
   alone. Pass = zitadel login works and a sec-agent fetches its secrets.
