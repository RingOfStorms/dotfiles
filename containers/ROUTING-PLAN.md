# Routing, exposure and auth for floating containers

Design for MIGRATION-PLAN §4.3. Goal: every service says **in one place**
who can reach it, how, and through what auth. The tooling makes the network
match that statement, lets it change at runtime (move, temporarily public),
and shows it on one tailnet-only page.

Status: **proposal**, nothing implemented. §7 lists the decisions still open.

## 1. Today (audit 2026-10-14, h001)

How a request gets in now:

```
public client ─▶ o002 nginx (per-name ACME, hand-written list in o002/nginx.nix)
                   └─ http://100.64.0.13:80 (hard-coded upstreamHost) ─▶ h001 nginx ─▶ 127.0.0.1:<port>
tailnet client ─▶ h003 dnsmasq-tailnet (fleet.nix h001Subdomains, hand list) ─▶ 100.64.0.13 ─▶ h001 nginx
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
| `local` | Same container/host loopback only | Nothing. The app binds 127.0.0.1 (or the container IP, §3). No vhost, no DNS, no firewall. |
| `tailnet` | Tailnet devices (optionally only those in `allow`) | Host vhost with `allow 100.64.0.0/10; deny all;` (or the listed nodes' IPs), DNS record in dnsmasq-tailnet only. Raw TCP: a firewall rule on `tailscale0` for exactly that port (and source IPs). |
| `lan` | Tailnet + home LAN | As `tailnet`, plus the LAN subnet in `allow` and a LAN DNS record (AdGuard/dnsmasq on h003). |
| `public` | Internet | As `lan`, plus a generated o002 vhost (HTTP) or stream (TCP) pointing at the service's *current* host. Refused unless `auth != "none"` or `publicWithoutAuth = true` is set explicitly. |

Rules that make this trustworthy:

- **Default is `local`.** A route without `exposure` is not reachable at all.
  Adding a service never opens anything by accident.
- **Policy is enforced at nginx and the firewall, not only by DNS**: tailnet
  vhosts carry `allow`/`deny`, LAN-only vhosts reject requests that came
  through o002 (o002's overlay IP is not in their `allow` list).
- **No raw app ports on the network.** Apps listen on loopback / the
  container IP. Only nginx (80/443), sshd and the declared `proto = "tcp"`
  routes are reachable. `tailscale0` stops being a trusted interface on
  service hosts (§5.1).

### 2.2 Names

- One name per route, `<name>.joshuabell.xyz`, the same everywhere
  (split-horizon): tailnet DNS answers with the host's overlay IP, public DNS
  (if public) with o002. Clients never need `:port`.
- Single label only, so the existing `*.joshuabell.xyz` wildcard covers it.
  For private names that shouldn't be guessable from public DNS, there's an
  optional second namespace, `*.ts.joshuabell.xyz`, with its own wildcard
  (DNS-01). It never gets a public A record.
- The app must know its external URL (immich `IMMICH_SERVER_URL`, forgejo
  `ROOT_URL`, paperless `PAPERLESS_URL`, open-webui `WEBUI_URL`,
  vaultwarden `DOMAIN`, ...). `mkNixosContainer` passes
  `routes.<r>.url` into the guest via `specialArgs`, so container.nix reads
  it instead of hard-coding it. Rename the route and the app follows. No
  sub-path hosting (`/app/`): every app gets a subdomain, which avoids
  rewrite rules almost entirely.

## 3. Isolation: private container networking

Host networking is the root of the shared-loopback and port-collision
problems. Target for nixos-kind services:

- `privateNetwork = true`: each container gets a veth with a stable
  `10.233.<n>.2` (allocated from the service name, recorded on the host).
  Apps keep their **native** ports (no global port registry, no collisions
  on move).
- Host nginx proxies `http://10.233.<n>.2:<port>`. The container's own
  firewall admits only the host side of the veth on route ports.
- Container → container traffic (open-webui → litellm/searx) goes through
  declared `uses = [ "litellm.web" ]` dependencies, which add exactly that
  allow rule, or simply via the tailnet name like any other client.
- Exceptions stay on host networking, explicitly (`network = "host"` with a
  reason): arr (VPN netns + QSV), anything needing broadcast/mDNS.
- Podman-kind already gets a bridge. It gets the same treatment
  (publish to the bridge IP, not 0.0.0.0).

This is the biggest change, but it can be done per service as each one is
redeployed, using the existing deploy → verify loop.

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

- Service hosts: drop `tailscale0` from `trustedInterfaces`. Open 80/443 on
  `tailscale0` and the LAN, and on `tailscale0` only the declared
  `proto = "tcp"` routes (narrowed to `allow` sources).
- Runtime: the host module already has a runtime port set filled by
  `cnt deploy`. Extend the per-service file from "port" to
  "port, proto, interface, sources".
- Roll out carefully: sshd, beszel agents (45876?), sec-agent, nix-serve
  (lio), DNS on h003 and headscale DERP all rely on the trust today. Inventory
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
| Tailnet DNS | `fleet.nix` lists | `cnt deploy`/`move` | h003 `dnsmasq hostsdir=/var/lib/fleet-dns` (dnsmasq re-reads it via inotify, no restart) |
| LAN DNS | AdGuard rewrites | same | same, LAN instance |
| Public edge | `o002/nginx.nix` | `cnt deploy`/`move`/`expose` | o002 runtime include dir (o002 gets the host module with `nginx.enable`) |
| Public cert | per-name http-01 | — | wildcard on o002 via DNS-01, so new public names need no ACME round-trip |

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
- `cnt move` carries the overrides and re-points DNS + edge to the new host.
  The edge proxies to the new overlay IP only after the backend passes its
  health check there.
- Upgrades to `public` print the auth mode and ask for confirmation. `none` +
  `public` needs `--no-auth-i-am-sure`.

### 5.4 Dashboard: `cnt serve`

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
3. **Forwarded headers**: apps behind two proxies need the client IP and
   scheme. h001 should trust `X-Forwarded-*` only from o002's overlay IP
   (`set_real_ip_from 100.64.0.2`). Otherwise rate limits and fail2ban see
   o002 for everyone, or anyone can spoof the client IP.
4. **Edge hardening on o002**: per-route `rateLimit`, `maxBody`, optional
   geo/allow lists, and fail2ban/crowdsec on auth endpoints of `public` +
   `native` routes (vaultwarden, immich, jellyfin logins).
5. **HSTS**: don't send `includeSubDomains` on the apex while some names are
   plain http on the tailnet.
6. **The bunny DNS key** can rewrite the zone. Keep DNS-01 issuance on as
   few hosts as possible (h001 + o002) and distribute certs via sec instead
   of giving every host the key. Watch Let's Encrypt rate limits (h001 and
   o002 both issuing).
7. **Split-horizon drift**: if tailnet DNS and the edge disagree after a
   move, tailnet users and public users hit different hosts. `cnt move`
   updates both, and `audit` checks them.
8. **Non-HTTP**: forgejo SSH 3032, minecraft 25565, the arr WireGuard
   51820/udp and immich pg are `proto = "tcp"`/`"udp"` routes. Public ones
   become o002 `stream` entries (no TLS termination, no auth, so they're
   listed loudly on the dashboard).
9. **Health checks**: per route `health = "/api/health"`. They drive the
   dashboard, gate `move`, and could feed an alert (ntfy) when a public
   route goes down.
10. **Secrets in URLs/headers**: never put API keys in generated nginx
    files. Those files are readable on the host and shown by `cnt status`.
11. **IPv6**: every rule needs a v6 twin (nginx `listen [::]`, nft ip6). The
    audit covers both.

## 7. Open decisions

1. Private container networking (§3): adopt as the default for new and
   redeployed nixos services? It's the bigger change, but it's what makes
   `local` mean something.
2. Second private namespace `*.ts.joshuabell.xyz`, or keep one flat
   `*.joshuabell.xyz` namespace with policy enforced in nginx?
3. Remove `tailscale0` trust on service hosts (§5.1), and add headscale tags
   and device groups?
4. Shared per-host oauth2-proxy with one SSO cookie, vs per-app?
5. Dashboard: read-only first, or straight to actions?

## 8. Suggested order

1. `routes` schema in service.nix + CLI generation of the host vhost and
   firewall from it, keeping the `nginx` string as an escape hatch; convert
   the services one at a time. `cnt routes` and `cnt audit`.
2. Close the tailnet-wide raw ports: apps to loopback, `tailscale0` trust
   removed on h001 (inventory first).
3. Generated tailnet DNS (`hostsdir` on h003), then the o002 runtime include
   + wildcard cert, which retires `h001Subdomains` and the hand o002 list.
4. Shared oauth2-proxy + per-route `auth`.
5. `cnt expose` overrides with expiry.
6. `cnt serve` read-only dashboard; homepage-dashboard retired.
7. Private container networking, service by service.
8. Then `cnt move` for real.
