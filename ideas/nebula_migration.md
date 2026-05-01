# Nebula Migration (research notes)

Captured 2026-05-01 after investigating tailscaled hammering
`controlplane.tailscale.com` / `login.tailscale.com` from h001 + h003
(visible in AdGuard on h003, which is the LAN router/DNS, so the
queries from every other client funnel through it).

This file is **not a plan to migrate now** — it's a record of what
Nebula would buy us, what it would cost, and what concretely has to be
designed/built before we pull the trigger. The current production fix
is the `ts_omit_captiveportal` overlay on `pkgs.tailscale` (see
`flakes/common/nix_modules/tailnet/default.nix`) which compiles out
the captive-portal probe entirely.

The migration is most attractive as a way to **collapse our two cloud
VMs (l001 + o001) down to one** — see §0.

## Status / TL;DR

- **Decision (2026-05-01):** Stay on Tailscale + the build-tag overlay.
  The captive-portal leak is fixed in our binary today.
- **Standing trigger to revisit:** when we want to drop the linode VM
  and run everything we care about in the cloud on o001 alone, **or**
  if upstream Tailscale removes the `ts_omit_captiveportal` build tag.
- **Hard things to design before migrating** (not blockers, just real
  work):
  1. Replacement for Headscale `extra_records` — currently 17 service
     A records under `joshuabell.xyz` distributed via MagicDNS.
  2. Cert-signing workflow — Nebula has no preauth keys; CA signs.
  3. CA rotation ritual (default 1y) and how it interacts with
     impermanence.
  4. Service-by-service swap of `tailscaled.service` deps + overlay-IP
     bindings on h001 (nginx, litellm, portkey, bifrost,
     monitoring_hub, beszel, etc.) and on joe / oracle / lio.

## 0. The actual motivator: collapse l001 → o001

Headscale's docs say the headscale server should not also be a
tailnet device — it works but is unsupported. Today that constraint
forces the split:

- `l001` (linode) — runs headscale, NOT in the overlay
- `o001` (oracle) — in the overlay, runs other cloud-side services

Nebula has no equivalent constraint. **Lighthouses are normal nodes**
that happen to set `am_lighthouse: true`; they have a Nebula IP, talk
to peers, and are firewalled like everyone else. So with Nebula:

- `o001` runs the lighthouse AND is a normal mesh member.
- `l001` goes away (or stays as a second lighthouse for redundancy if
  we still want it; cost ≈ $5/mo and it's already paid for).

**Lighthouse SPOF analysis** is materially better than headscale-SPOF:

- Headscale down → no new key exchange, no node enrolment, no derp,
  full overlay degraded over minutes-to-hours as keys/derpmap expire.
- Single lighthouse down → existing tunnels keep working (peers cache
  each other). New handshakes fail; roaming hosts can't update. So
  it's a **soft** SPOF, not a hard one. A second lighthouse on h001
  (LAN-only is fine for LAN peers) makes even that mostly cosmetic.

This is the strongest single argument for migration.

## 1. Background: what we have today

See `flakes/common/nix_modules/tailnet/default.nix` and
`hosts/linode/l001/headscale.nix`.

- ~12 hosts joined to self-hosted Headscale at
  `headscale.joshuabell.xyz`
- Embedded DERP only (region 999), no upstream Tailscale derpmap
- ACL: full mesh among untagged `josh@` nodes; `tag:lowtrust`
  reachable inbound from trusted, cannot initiate outbound
- MagicDNS on, base_domain `net.joshuabell.xyz`
- `extra_records`: 17 A records for h001 services
  (jellyfin, media, notes, chat, sso-proxy, n8n, sec, sso, gist, git,
   blog, etebase, photos, location, matrix, element, docs)
  → `100.64.0.13`
- Auth: openbao preauth keys (hightrust vs lowtrust), rotated yearly
- Persisted state: `/var/lib/tailscale` via impermanence
  (`flakes/impermanence/shared_persistence/tailscale.nix`)
- Many host services bind/firewall on `tailscale0`:
  - h001: `nginx.nix:35`, `litellm.nix:31`, `litellm-public.nix:34`,
    `portkey.nix:126`, `bifrost.nix:101`, `monitoring_hub.nix:24`
  - joe: `nginx.nix:14`
  - oracle/o001: `nginx.nix:42`
  - lio: `ttyd.nix:41`
  - `flakes/beszel/flake.nix:74-75` (requires/after `tailscaled.service`)
- Currently mitigated: `pkgs.tailscale` overlay with build tag
  `ts_omit_captiveportal` (default-on for every host that imports the
  `tailnet` module), plus `services.tailscale.disableUpstreamLogging
  = true` replacing the old `--no-logs-no-support` flag.

## 2. Why we'd consider leaving Tailscale at all

Two things motivate the question:

1. **The captive-portal hardcoding** — tailscaled hard-codes
   `controlplane.tailscale.com` and `login.tailscale.com` into its
   captive-portal probe list (`net/captivedetection/endpoints.go:124-125`
   in upstream tailscale), fires every ~5 min regardless of
   `--login-server`. The documented escape hatch
   (`disable-captive-portal-detection` node attribute) is broken in
   tailscale (open issue #15047) AND headscale can't deliver
   nodeAttrs anyway (open issue #2319). Only real fix in our binary
   is the `ts_omit_captiveportal` build tag, which we now apply.
   This is mostly defused but remains philosophically annoying — we
   are one upstream change away from the escape hatch disappearing.

2. **The l001 SPOF** — see §0. This one is a real architectural win,
   not a philosophical preference.

## 3. What Nebula actually is

- Slack's open-source mesh VPN (`github.com/slackhq/nebula`).
- **Verified zero hardcoded phone-home URLs** in the Go source
  (clone+grep, all `https?://` matches were comment links to
  kernel/Go/wireguard-go docs). Only `net/http` use is the opt-in
  Prometheus/Graphite stats server. No update checks. No telemetry.
  Nothing analogous to tailscaled's captive-portal probes.
- Cipher: Noise IK + ChaPoly default (or AES-GCM, must match across
  the whole network).
- Components:
  - **Lighthouse**: stateless rendezvous; answers "where is peer X?".
    Recommend ≥2 for redundancy. Tiny footprint.
  - **Relay**: a normal node with `am_relay: true` that forwards
    traffic when hole-punching fails. **Must be listed explicitly in
    each peer's config** — there is no automatic "nearest relay"
    selection like Tailscale's DERP.
  - **Regular nodes**: hole-punch directly when possible (`punchy`),
    fall back to listed relays.
- Auth model: **CA + per-host certs**. CA private key lives offline
  (workstation, openbao). `nebula-cert sign -in-pub host.pub
  -name foo -networks 100.64.0.X/24 -groups hightrust` mints a cert
  against a public key the node generated locally. Private key never
  leaves the node.
- Firewall: per-node `firewall.inbound`/`firewall.outbound` rules in
  config, referencing cert `groups`. Asymmetric inbound rules give us
  the same hightrust/lowtrust semantics we have today.
- NixOS module: `services.nebula.networks.<name>` (in nixpkgs,
  maintained by `numinit` and `siriobalmelli`). Multi-network
  capable, hardened systemd unit, **SIGHUP reload preserves tunnels**
  (set via `enableReload = true` — already the default).

## 4. Feature parity vs current Headscale setup

| Capability | Headscale today | Nebula equivalent | Cost |
|---|---|---|---|
| NAT traversal | DERP-assisted | `punchy: { punch=true; respond=true }` | none |
| Relay fallback | DERP, automatic | Explicit `relay.relays:` per node, designate o001/h001 | low (config) |
| MagicDNS hostnames | automatic | Lighthouse `serve_dns: true` — bare cert-name only, no domain suffix | medium (see §5) |
| `extra_records` (17 service names) | `dns.extra_records` | None native | medium-high (see §5) |
| ACLs (hightrust mesh + lowtrust inbound-only) | headscale policy | Cert `groups` + per-node `firewall.inbound` | low (1:1 map) |
| Preauth keys | `headscale preauthkeys create` | Offline `nebula-cert sign` ceremony | medium (see §6) |
| Cert / identity rotation | TS auto via control | Manual annual CA rotation, or 10y CA | medium (see §7) |
| Web UI | headplane / headscale-ui | None OSS worth using | n/a (we don't really use one) |
| iOS/Android | Tailscale apps (great) | Mobile Nebula (functional, clunkier) | n/a (no mobile in fleet) |
| Linux/Mac/Win | TS GUI + CLI | CLI + systemd | n/a |
| OIDC/SSO | Headscale OIDC | None — pure cert | n/a (unused) |

## 5. The MagicDNS / `extra_records` problem (the actual hard part)

We have 17 A records under `joshuabell.xyz` pointing at h001's
overlay IP, distributed automatically to every overlay client. Plus
`<host>.net.joshuabell.xyz` for every node. Nebula's built-in DNS
(verified by reading `dns_server.go` upstream) only serves bare cert
names — no domain suffix, no extra_records, no wildcards.

Replacement options, ranked for our setup:

### (a) Distribute via `networking.hosts` from Nix — RECOMMENDED

We already have `flakes/common/nix_modules/tailnet/h001_dns.nix` and
the `h001DnsHosts` option that drops it into `networking.hosts`. For
the migration, just make this default-on for every host that imports
the (renamed) `nebula` module. Zero new daemons, works identically on
LAN and cloud nodes, in git, no privacy leak.

**Cost:** to add/rename a service, `nixos-rebuild` the fleet. For 17
mostly-stable records that change maybe twice a year, this is a
non-issue.

### (b) CoreDNS on the lighthouse(s)

Run `services.coredns` on o001 (and h001 as second lighthouse) bound
to the Nebula IP, with a templated `hosts` plugin block:

```nix
services.coredns.config = ''
  joshuabell.xyz {
    hosts {
      ${lib.concatMapStringsSep "\n      "
        (n: "100.64.0.13 ${n}.joshuabell.xyz") fleet.h001Subdomains}
      fallthrough
    }
    forward . 1.1.1.1
  }
'';
```

Every node forwards `joshuabell.xyz` to that resolver via
systemd-resolved or the local AdGuard. Closer to MagicDNS UX, more
moving parts, hard dependency on Nebula being up for `*.joshuabell.xyz`
resolution to work.

**When to graduate from (a) → (b):** if record-churn becomes weekly,
or if we want non-NixOS clients to participate.

### (c) Public DNS

Just put the records in the real `joshuabell.xyz` zone. Easiest;
leaks an internal service inventory (jellyfin, gist, sso, matrix...)
to anyone scanning the zone. Not recommended.

### (d) Nebula's built-in lighthouse DNS — bonus only

Set `lighthouse.serve_dns: true` on o001. Gives us `dig @o001 h001`
→ `100.64.0.13` for free. Useful for `ssh h001` ergonomics; covers
exactly **none** of the 17 service records. Treat as a freebie, not
a solution.

## 6. Cert-signing workflow (the openbao-shaped question)

Nebula has no preauth-key concept. The equivalent is `nebula-cert
sign` performed by whoever holds the CA key. **Vault/openbao's PKI
engine emits X.509 only — Nebula uses its own non-X.509 cert format
(`BEGIN NEBULA CERTIFICATE`), so they are not interchangeable.**
There is no Nebula PKI engine for openbao.

This means openbao's role becomes **storage**, not signing:

- `kv/nebula/ca/<rotation-date>/{ca.crt,ca.key}` — encrypted CA
  material, only checked out for signing ceremonies.
- `kv/nebula/hosts/<host>/{host.crt,host.key}` — per-host material,
  delivered to nodes by the existing `secrets-bao` machinery via
  vault-agent (same pattern as today's headscale preauth keys).

**Workflow for a new node** (clean version, private key never moves):

```bash
# On the new node
nebula-cert keygen -out-key host.key -out-pub host.pub
# stash host.pub somewhere we can grab it from the workstation

# On the signing workstation (offline, CA pulled from openbao)
bao kv get -field=ca.crt kv/nebula/ca/2026-05-01 > ca.crt
bao kv get -field=ca.key kv/nebula/ca/2026-05-01 > ca.key  # encrypted
nebula-cert sign \
  -ca-crt ca.crt -ca-key ca.key \
  -name <hostname> -networks 100.64.0.X/24 \
  -groups hightrust \
  -in-pub host.pub -out-crt host.crt
# Push host.crt back to openbao at kv/nebula/hosts/<host>/host.crt
# vault-agent on the node renders it; nebula module reloads on change.
shred ca.key
```

Once written, this is a ~30-line shell script. CA key can be
`-encrypt`-protected at rest (`NEBULA_CA_PASSPHRASE`) and PKCS#11 is
supported as of v1.10 if we ever go HSM.

For 12 hosts × ~2 new nodes/year, an offline signing ceremony on the
workstation is fine — no need for a signing daemon.

## 7. CA / cert rotation

Default CA lifetime is 1y, host certs default to 1s before CA expiry.

**Annual rotation procedure** (per upstream docs at
<https://nebula.defined.net/docs/guides/rotating-certificate-authority/>):

1. `nebula-cert ca -name "joshuabell-2027" -networks 100.64.0.0/24
   -duration 8760h -encrypt`
2. Push **concatenated** `old_ca.crt + new_ca.crt` to every node's
   `pki.ca`. SIGHUP. (NixOS module's `enableReload` handles this
   without restart.)
3. Re-sign each host cert against the new CA. Push each new
   `host.crt`. SIGHUP. Verify with `nebula-cert print`.
4. Once every node is on a new cert, drop the old CA from the trust
   bundle. SIGHUP.

**Skip the ritual with a long-lived CA?** `-duration 87600h` (10y)
works. Risk: blast radius of CA-key compromise is 10 years instead
of 1. Given the CA only lives offline and openbao-encrypted, this is
defensible. Recommendation: **start with 2y CA + scripted rotation**;
revisit at first rotation.

**Impermanence interaction:** `/var/lib/nebula/{host.crt,host.key,
ca.crt}` need to persist. Add a `flakes/impermanence/shared_persistence/
nebula.nix` analogous to the existing `tailscale.nix`. Three small
files per host.

## 8. Concrete shape of the NixOS module

A new `flakes/common/nix_modules/nebula/default.nix` that mirrors the
current `tailnet` module's shape so host imports stay one-line.
Sketch:

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.ringofstorms.nebula;
  fleet = import ./fleet_nebula.nix;  # IPs, groups, lighthouses
in {
  options.ringofstorms.nebula = {
    role = lib.mkOption {
      type = lib.types.enum [ "node" "lighthouse" "relay" "lighthouse-relay" ];
      default = "node";
    };
    group = lib.mkOption {
      type = lib.types.enum [ "hightrust" "lowtrust" ];
      default = "hightrust";
    };
    serviceHostsFile = lib.mkOption {
      type = lib.types.bool;
      default = true;  # drop h001's 17 records into /etc/hosts
    };
  };

  config = {
    services.nebula.networks.mesh = {
      enable = true;
      ca   = "/var/lib/nebula/ca.crt";
      cert = "/var/lib/nebula/host.crt";
      key  = config.sops.secrets."nebula/host.key".path or
             "/var/lib/openbao-secrets/nebula_host_key";
      staticHostMap = fleet.lighthouseMap;   # IP -> [ "pub.ip:4242" ]
      lighthouses   = fleet.lighthouseIps;
      relays        = fleet.relayIps;
      isLighthouse  = lib.elem cfg.role [ "lighthouse" "lighthouse-relay" ];
      isRelay       = lib.elem cfg.role [ "relay" "lighthouse-relay" ];
      firewall.outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
      firewall.inbound  = [
        { port = "any"; proto = "icmp"; host = "any"; }
        { port = "any"; proto = "any";  groups = [ "hightrust" ]; }
      ] ++ lib.optional (cfg.group == "hightrust")
        # hightrust nodes also accept inbound from lowtrust:
        { port = "any"; proto = "any"; groups = [ "lowtrust" ]; };
      settings = {
        punchy.punch = true;
        punchy.respond = true;
        lighthouse.serve_dns = lib.mkIf
          (lib.elem cfg.role [ "lighthouse" "lighthouse-relay" ]) true;
      };
    };

    networking.hosts = lib.mkIf cfg.serviceHostsFile (
      let h001 = import ./h001_dns.nix; in {
        "${h001.ip}" = map (n: "${n}.${h001.baseDomain}") h001.subdomains;
      });

    networking.firewall.trustedInterfaces = [ "nebula.mesh" ];
  };
}
```

Plus `fleet_nebula.nix` (analogous to `hosts/fleet.nix`) holding the
authoritative IP/group/role assignments for every host.

## 9. IP plan (sketch — refine before migration)

Pick a /24 disjoint from `100.64.0.0/24` for transition (so both
overlays can coexist). E.g. `10.42.0.0/24`:

- `10.42.0.1` — o001 (lighthouse + relay)
- `10.42.0.2` — h001 (lighthouse-relay, LAN-side)
- `10.42.0.10..` — hightrust nodes
- `10.42.1.0/24` — lowtrust subnet (group=lowtrust)

Decision: keep the last octet from current `100.64.0.X` where
possible, to make grep-and-replace painless during the service
migration.

## 10. Phased rollout plan

Each phase is independent and reversible until phase 4.

### Phase 0 — design (2-4h)
- Finalize IP plan, group assignments, lighthouse/relay layout
- Write `fleet_nebula.nix`
- Decide CA duration (recommend 2y to start)
- Decide signing-script home (probably `utilities/nebula-sign/`)

### Phase 1 — stand up Nebula in parallel (4-6h)
- Generate CA on workstation, store in openbao
  (`kv/nebula/ca/2026-MM-DD/`)
- Sign certs for all current hosts; push to openbao
  (`kv/nebula/hosts/<host>/`)
- Add `secrets-bao` rendering for `nebula/host.key` and
  `nebula/host.crt`
- Write `flakes/common/nix_modules/nebula/default.nix`
- Add `flakes/impermanence/shared_persistence/nebula.nix`
- Open UDP/4242 on cloud VMs
- Roll the module out one host at a time. Tailscale stays running;
  Nebula runs on a different interface (`nebula.mesh`).
- Verify mesh: every node pings every other node on `10.42.0.X`.

### Phase 2 — service migration on h001 (4-8h)
- Swap each service's `tailscaled.service` dep → `nebula@mesh.service`
- Swap overlay-IP bindings/firewall rules from `100.64.0.13` →
  `10.42.0.13` (or whatever h001 lands on)
- Files to touch (verified via grep during initial investigation):
  - `hosts/h001/nginx.nix:35`
  - `hosts/h001/litellm.nix:31`
  - `hosts/h001/litellm-public.nix:34`
  - `hosts/h001/portkey.nix:126`
  - `hosts/h001/bifrost.nix:101`
  - `hosts/h001/monitoring_hub.nix:24`
  - `hosts/joe/nginx.nix:14`
  - `hosts/oracle/o001/nginx.nix:42`
  - `hosts/lio/ttyd.nix:41`
  - `flakes/beszel/flake.nix:74-75`
- Per-host: rebuild, smoke test (curl each service from a peer over
  Nebula IP), revert immediately if anything breaks.

### Phase 3 — DNS cutover (1-2h)
- Flip `serviceHostsFile = true` default-on
- Verify `*.joshuabell.xyz` → new overlay IP from every node
- (Optional) stand up CoreDNS on o001 + h001 if we want option (b)

### Phase 4 — decommission Tailscale (2-3h, irreversible-ish)
- Drop `inputs.common.nixosModules.tailnet` from every host flake
- Remove `services.tailscale` from impermanence persistence
- Remove headscale module from l001
- **Power off l001** (or repurpose). Cancel linode billing.
- Drop tailscale-related secrets from openbao
  (`headscale_auth_*_2026-03-15`)

### Phase 5 — cleanup (1h)
- Delete `flakes/common/nix_modules/tailnet/` from common flake
- Delete `hosts/linode/` if not repurposing
- Update `ideas/openbao_declarative.md` and any other docs referencing
  the old setup
- Move this file to `ideas/migrations/nebula.md` with a status header.

**Total estimate:** 15-25h focused work + ~2 weeks of "oh, that
broke" tail. Migrate during a quiet week.

## 11. What we'd lose, plainly

- **Mobile clients.** No iOS/Android in fleet today. If that changes,
  Mobile Nebula exists but is rougher than Tailscale.
- **MagicDNS auto-magic.** Adding a new service means editing
  `h001_dns.nix` and rebuilding (or graduating to CoreDNS).
- **Preauth-key UX.** Adding a new node means a workstation signing
  ceremony. ~5 min, scriptable, not bad — but no longer "paste a
  key into the install script."
- **Web UI** for visualizing the mesh. We don't really use one today.
- **Tailscale SSH.** Not used today (we use real OpenSSH).

## 12. Things to investigate before pulling the trigger

- [ ] Verify hole-punching reliability between current home NAT (h001
  on residential) and o001 (Oracle). Spin up nebula side-by-side on
  one host pair for a week before committing.
- [ ] Confirm `nebula-cert` PKCS#11 path works with our preferred HSM
  if we ever want one (currently moot — CA is openbao-encrypted).
- [ ] Check whether `services.nebula` module supports `enableReload`
  with our intended config shape, or if some setting forces full
  restart (would interrupt tunnels).
- [ ] Decide: drop l001 entirely, or keep as $5/mo second lighthouse
  for true zero-SPOF? Probably drop — h001 can be the second
  lighthouse for LAN peers, o001 covers cloud peers.
- [ ] Audit lowtrust group usage — anything currently depending on
  the asymmetric ACL needs explicit re-validation under Nebula's
  per-node firewall model.

## 13. Alternatives briefly considered (and why not)

- **NetBird self-hosted** — has hardcoded `pkgs.netbird.io`,
  `metrics.netbird.io`, `app.netbird.io`, `api.netbird.io`. Same
  category of grievance as Tailscale, smaller team, worse track
  record. No.
- **Innernet (tonarino)** — pure WireGuard, has `hostsfile` integration
  (would solve our DNS problem natively), CIDR-based ACLs. **No
  relay fallback** — if hole-punching fails between two nodes they're
  unreachable. Worth a separate eval if Nebula's relay setup proves
  annoying.
- **Plain WireGuard + Nix** — 12 hosts × 11 peers = 132 peer entries.
  No hole-punching helpers. No.
- **Stay on Tailscale forever** — current state. Works. Requires the
  build-tag overlay to stay sane. One upstream change away from
  forcing this discussion again.
