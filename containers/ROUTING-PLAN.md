# Routing, exposure and auth for floating containers

Design for routing that follows a service across hosts. Goal: every service says **in one place**
who can reach it, how, and through what auth. The tooling makes the network
match that statement, lets it change at runtime (move, temporarily public),
and shows it on one tailnet-only page.

Status: **proposal**; §8 step 1 in progress (`routes` schema, generated host vhost + ports, `cnt routes`, `cnt audit`; sec and zitadel converted). Decisions are in §7; §6 lists
requirements every step must meet. §9 holds the open items carried over from
the finished migration plan (all services float since 2026-10-17).

Roles assumed: **h005 = router** (WAN, port forwards, DDNS, LAN + tailnet
DNS, always on), **h004 = NAS**, **o002 = public TLS edge**, h001/h003/lio/joe
= service hosts.

## 1. Today (audit 2026-10-14, h001)

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
- **Namespace chosen per route** (`zone = "main"` default, or `"private"`):
  - `main`: `<name>.joshuabell.xyz`, covered by the existing wildcard.
  - `private`: `<name>.ts.joshuabell.xyz`, with its own wildcard (DNS-01)
    and never a public record. Use it for names you'd rather not reveal even
    in public DNS. `public` routes can't use it.
  Either way the name is a single label under its wildcard, so no per-name
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
- **TLS on o002: unchanged, per-name http-01.** o002 has no bunny key (its
  sec grants are join/git tokens only), and §5.2 gives the key to h005
  alone. The wildcard for o002 comes in step 4 (issued on h005, distributed
  via sec). Names stay in CT logs, which is fine for public names. Per-name
  certs keep working for new routes because http-01 needs only the CNAME.
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
| trilium | oauth2-proxy (own instance) ✓ | `oauth2-proxy` groups=notes | trilium sync clients (?) |
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
| Certificates | h001 DNS-01, o002 per-name http-01 | `fleet-edge` on h005 | wildcards issued on h005, distributed via sec to the hosts that terminate TLS |

**`fleet-edge` on h005.** h005 is the always-on networking box, so it owns
everything that touches the bunny key or the WAN:

- It's the **only** holder of the bunny API key: DDNS, public records and
  DNS-01 for the wildcards. h001's `security.acme` and its copy of the key go
  away.
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

1. **(in progress)** `routes` schema in service.nix + CLI generation of the host vhost and
   firewall, keeping the `nginx` string as an escape hatch while services
   are converted. Add `cnt routes` and `cnt audit` (read-only, useful
   immediately).
2. Firewall: inventory each host's listeners, add explicit rules, then drop
   the `tailscale0` trust host by host (h001 first). Add `cnt port open`.
3. Internal/edge listener split (§2.3, §2.3.1), o002 generated vhosts and
   a wildcard. This retires the hand-kept o002 list. **Done 2026-10-20**,
   except: the o002 wildcard waits for step 4 (no bunny key on o002).
   `blockInternal` is on for h001 (generated vhosts only; see §2.3.1).
4. `flakes/fleet-edge` on h005: tailnet/LAN DNS records (retires
   `h001Subdomains` and the hand host records), bunny import (diff only,
   adopt existing CNAMEs) + `cnt dns`, DDNS folded in, then cert
   issuance (retires h001's bunny key), then router forwards + DDNS
   (minecraft back online).
5. Private container networking, service by service, arr last.
6. Fleet oauth2-proxy on h005 + per-route `auth`, with cookie stripping
   from the first gated route.
7. `cnt expose` overrides with expiry.
8. Read-only dashboard in fleet-edge; homepage-dashboard retired.
9. Then `cnt move` for real. Needs §9.1 first.

## 9. Carried over from the migration plan

The migration plan was deleted once every service was floating (sec and
zitadel last, 2026-10-17; history in git). These items are still open.

### 9.1 Backup continuity across moves (required before any off-host `move`)

`hosts/h001/mods/restic-backup.nix` runs only on h001. It runs the
`backupHook` of every service active there, then snapshots h001's
`/srv/containers`, excluding live PG clusters and caches; SQLite gets a
`.backup` copy first. After a move it would keep backing up the stale
source copy. Needed:

- a restic job on **every** container host, generated by the host module
  from the services deployed there (hooks + persist dirs), with per-host
  repos/tags;
- `move` removes the source copy (or marks it stale and excluded) once the
  target is verified;
- the first backup on the target runs as part of `move`, and a restore check
  (`restic restore` to a scratch dir, PG/SQLite integrity) runs before the
  source copy goes;
- backup age per service on the dashboard (§5.4), alert when stale.

### 9.2 Secret grants in service.nix

Containers bind `/var/lib/secrets_manager_hydrated/<name>` read-only;
h001's `sec-agent.nix` grants them by hand (`cnt restart <svc>` after
rotation). Declare them in `service.nix` so `deploy`/`move` can refuse
early when the target host lacks a grant.

### 9.3 Identity core: break-glass and a cold-restore test

Kept outside the fleet, in the password manager. These are **keys only**:

- restic env (repo, password, backend credentials);
- sec's encryption key (`/srv/containers/sec/data/db.key`);
- zitadel master key (`/srv/containers/zitadel/keys/masterkey`, 32 raw bytes,
  stored base64);
- emergency ssh key `root_fleet_backup`. Its public half is authorized for
  root on every host via common `hardening.nix`.

The keys decrypt data but don't contain it. `sec.db` and zitadel's
PostgreSQL state exist only on h001 and in the one restic repo, so a
damaged repo with h001 lost means **key recovery only, no restore**. To do:

1. **Independent data copy**: a second backup of `/srv/containers/sec/data`
   and `/srv/containers/zitadel/{pgdumps,keys}` that doesn't share the restic
   repo or its credentials (e.g. a second restic repo on h004, or a periodic
   encrypted export). Without it the path below can't work.
2. **Cold-restore test** on a spare host, twice: once from a restic
   snapshot, once from the independent copy plus the password-manager keys
   alone. Pass = zitadel login works and a sec-agent fetches its secrets.
