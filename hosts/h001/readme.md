# h001

Home server (OptiPlex 7090)

## Hardware

| Component | Spec |
|---|---|
| Model | Dell OptiPlex 7090 |
| CPU | Intel Core i5-11500 (6C/12T, up to 4.6 GHz) |
| GPU | Intel UHD Graphics 750 (integrated) |
| RAM | 64 GB |
| Storage | Not yet inventoried |

## Bare-metal services

Everything else runs as floating containers (`cnt ls`). That includes sec
(secrets.joshuabell.xyz, 127.0.0.1:8300) and zitadel (sso.joshuabell.xyz,
:8085), both moved from host config on 2026-10-17
(`containers/sec/README.md` has the runbook and rollback). Their irreplaceable
keys live in persist: `/srv/containers/sec/data/db.key` and
`/srv/containers/zitadel/keys/masterkey`. Break-glass copies are offline
(`containers/ROUTING-PLAN.md` §9.3). Until about 2026-10-24, the
pre-cutover data stays in `/var/lib/zitadel` and `/var/lib/secrets_manager`
for rollback.

| Service | Notes |
|---|---|
| nginx + ACME | Wildcard `*.joshuabell.xyz` (bunny DNS-01); floating sites in `/var/lib/fleet-containers/nginx`. ACME moves to h005 (`containers/ROUTING-PLAN.md`). |
| restic backup | `mods/restic-backup.nix`, nightly. |
| homepage-dashboard | To be replaced by the fleet dashboard. |
| autofs NFS client, storage guard `fleet-guard-h004` | Host plumbing for `arr`. |
| Per-host agents | sec-agent, beszel-agent, fail2ban, tailscaled. |
