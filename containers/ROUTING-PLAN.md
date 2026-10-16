# Routing, exposure and auth for floating containers

Design for MIGRATION-PLAN §4.3. Goal: every service says **in one place**
who can reach it, how, and through what auth. The tooling makes the network
match that statement, lets it change at runtime (move, temporarily public),
and shows it on one tailnet-only page.

Status: **proposal**, nothing implemented. §7 records the decisions taken on
2026-10-16 and what's still open.

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

| Level | Who can reach it | What gets generated |
|---|---|---|
| `local` | The service itself | Nothing. No vhost, no DNS, no firewall. With private networking (§3) not even the host's other containers can reach it. |
| `tailnet` | Tailnet devices (optionally only those in `allow`) | Host vhost on the **internal listener** (§2.3), restricted to tailnet peers with **o002 excluded**. DNS in tailnet split-DNS only. Raw TCP/UDP: a firewall rule on `tailscale0` for that port (and `allow` sources). |
| `lan` | Tailnet + home LAN | As `tailnet`, plus the LAN subnets and a LAN DNS record (h005). |
| `public` | Internet | As `lan`, plus one or more **public paths** (§2.4). Refused unless `auth != "none"` or `publicWithoutAuth = true` is set explicitly. |

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
  (split-horizon): tailnet DNS answers with the host's overlay IP, public DNS
  (if public) with o002. Clients never need `:port`.
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

- Each service host runs **two nginx listeners**:
  - **internal** (`:80`/`:443`) carries every non-public route. The firewall
    admits it on `tailscale0` and the LAN and **drops o002's overlay IP**
    (any edge peer) before any allow. Each vhost also checks
    `$realip_remote_addr` (the real TCP peer, unaffected by `real_ip`)
    against its allow set, with an explicit `deny 100.64.0.2` first.
  - **edge** (`<overlayIp>:8443`) carries **only routes that are currently
    `public` via edge**. The firewall admits it only from o002. A downgrade
    or an expired override removes the route here, so even a stale o002
    vhost gets 444 from the host.
- `real_ip` (`set_real_ip_from 100.64.0.2`) is enabled **only on the edge
  listener**: correct client IPs for logs and rate limits there, and no
  spoofing on the internal one.
- Router-forwarded traffic (§2.4) keeps the internet client's source address
  through DNAT. It can't match a tailnet/LAN allow set, and the host's
  firewall admits WAN-sourced traffic only on ports currently forwarded for
  `public` routes. That set is driven by the same state, so it fails closed
  too.

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
| `edge` | client → o002 (TLS, rate limits) → tailnet → host edge listener | HTTP(S); hides the home IP | o002 vhost or `stream`, host edge-listener entry |
| `router` | client → home WAN IP (DDNS name) → h005 DNAT → host LAN IP:port | Games, UDP, WireGuard, large transfers that shouldn't hairpin via Oracle | h005 forward + DNAT entry, host WAN-source rule for that port, DDNS record |

- **The router path is runtime-managed on h005** by `fleet-edge` (§5.2). It
  owns an nft map of forwards (`proto . port → host:port`) and the DDNS
  names. `cnt deploy/move/expose` ask it to add or remove entries. The rest
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

**One shared oauth2-proxy per host** (not one per app as trilium has now),
using `auth_request` with per-route `allowed_groups` and a cookie on
`.joshuabell.xyz`, so one login covers every gated app. Trilium's private
instance folds into it.

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
  `cnt routes --host` and the dashboard. `ports_expose` stays as a thin
  wrapper around it.
- Roll out carefully: sshd, the beszel hub (agents connect out to it; h001 runs no agent listener), sec-agent, nix-serve
  (lio), DNS on h005 and headscale DERP all rely on the trust today. Inventory
  each host with `ss -ltnup` first, then add the needed rules to the host
  config **before** removing the trust.
- Headscale ACL: give servers a `tag:server` and restrict which device groups
  can reach which ports, so "tailnet" can mean "my laptops/phones",
  not "every node, including future ones".

### 5.2 Generated pieces and who writes them

| Piece | Source today | Generated by | Where |
|---|---|---|---|
| Host vhost | `nginx` string | `cnt deploy` from `routes` | `/var/lib/fleet-containers/nginx/<svc>.conf` (exists) |
| Firewall | `tcpPorts` + host files | `cnt deploy` | runtime port set (exists, extended) |
| Tailnet + LAN DNS | `fleet.nix` lists, AdGuard | `fleet-edge` on h005 | dnsmasq `hostsdir` (re-read via inotify, no restart) |
| Router forwards + DDNS | none (h005 has no forwards) | `fleet-edge` on h005 | nft map + bunny records |
| Public edge (o002) | `o002/nginx.nix` | `cnt deploy`/`move`/`expose` | o002 runtime include dir (o002 gets the host module with `nginx.enable`) |
| Certificates | h001 DNS-01, o002 per-name http-01 | `fleet-edge` on h005 | wildcards issued on h005, distributed via sec to the hosts that terminate TLS |

**`fleet-edge` on h005.** h005 is the always-on networking box, so it owns
everything that touches the bunny key or the WAN:

- It's the **only** holder of the bunny API key: DDNS, public records and
  DNS-01 for the wildcards. h001's `security.acme` and its copy of the key go
  away.
- It manages tailnet/LAN DNS records, router forwards and DDNS names for
  `via = "router"` routes.
- Its API is narrow and authenticated, on h005's overlay IP, from admin
  devices only: "set routes for service X on host H". State is a JSON file.
  It validates every request (forwards only to declared `public` routes,
  names only in the zone), so a stolen CLI credential can't repoint the
  zone. Every change is logged.
- It's a stdlib Go binary in the same module as the CLI.

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

- service.nix is the baseline. Overrides live in
  `/var/lib/fleet-containers/overrides/<svc>.json` on the service's host,
  carry `by`, `at`, `until` and a reason, and are shown everywhere (CLI,
  dashboard) as **overridden**.
- Expiry is enforced on the host (systemd timer re-applies the baseline),
  not by the CLI remembering.
- `cnt move` carries the overrides and re-points DNS, o002 and router
  forwards to the new host.
  The edge proxies to the new overlay IP only after the backend passes its
  health check there.
- `cnt expose` changes **ingress**. `cnt online` (already in the CLI) changes
  **egress** for `internet = false` services. They're independent, and
  the dashboard shows both.
- Upgrades to `public` print the auth mode and ask for confirmation. `none` +
  `public` needs `--no-auth-i-am-sure`.

### 5.4 Dashboard: `cnt serve` (read-only first, decided)

A small stdlib-Go web server in the existing CLI (`net/http`,
`html/template`, embedded assets; no JS framework needed):

- **Read-only first**: for every service it shows host, state, each route
  (name, exposure, auth, overridden?), health (HTTP check through the same
  path a client uses), backup age (restic + `cnt backup`), and requirements.
  Data comes from a per-host `state.json` the host module/CLI already has
  the material for, fetched over ssh, or (better) served by a tiny read-only
  endpoint on each host.
- Runs as a floating container on h001, route `exposure = "tailnet"`,
  `auth = "oauth2-proxy"` groups=admin.
- **Actions later** (start/stop/expose/move), behind a separate admin group.
  Every action is written to an audit log. The process that can make things
  public must not hold more power than it needs: start with "generate the
  command" buttons, and only later decide whether it holds deploy keys.
- Replaces homepage-dashboard's link list (the links are generated from
  `routes`, so they can't go stale).

## 6. Footguns and extras

1. **Audit command**: `cnt audit [host]` compares the declared routes against
   actual listeners (`ss -ltnup`), the nft ruleset, DNS answers and o002
   vhosts, and flags anything reachable that isn't declared. Run it in CI or
   nightly. Today it would flag the 0.0.0.0 list in §1.
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

## 7. Decisions

Taken 2026-10-16:

1. **Private container networking is the default**, arr included (§3).
2. **Namespace chosen per route** (`zone = "main" | "private"`, §2.2).
3. **No host trusts `tailscale0`**. Each gets an explicit per-service
   firewall, and ad-hoc ports use `cnt port open --for` (§5.1).
4. **Dashboard starts read-only** (§5.4).
5. **Public paths are `edge` (o002) or `router` (h005 DNAT + DDNS)**, both
   runtime-managed (§2.4).
6. **h005 runs `fleet-edge`** and is the only holder of the bunny key (§5.2).

Still open:

- One shared oauth2-proxy per host with one SSO cookie, or one per app?
  Proposal: shared.
- Headscale tags and device groups (what "tailnet" means per route).

## 8. Suggested order

1. `routes` schema in service.nix + CLI generation of the host vhost and
   firewall, keeping the `nginx` string as an escape hatch while services
   are converted. Add `cnt routes` and `cnt audit` (read-only, useful
   immediately).
2. Firewall: inventory each host's listeners, add explicit rules, then drop
   the `tailscale0` trust host by host (h001 first). Add `cnt port open`.
3. Internal/edge listener split (§2.3), o002 generated vhosts and a
   wildcard. This retires the hand-kept o002 list.
4. `fleet-edge` on h005: DNS records (retires `h001Subdomains`), then cert
   issuance (retires h001's bunny key), then router forwards + DDNS
   (minecraft back online).
5. Private container networking, service by service, arr last.
6. Shared oauth2-proxy + per-route `auth`.
7. `cnt expose` overrides with expiry.
8. `cnt serve` read-only dashboard; homepage-dashboard retired.
9. Then `cnt move` for real.
