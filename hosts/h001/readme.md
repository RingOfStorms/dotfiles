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
(`containers/ROUTING-PLAN.md` §9.3). The pre-cutover data
(`/var/lib/zitadel`, `/var/lib/secrets_manager`) was archived to
`/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001 and deleted on
2026-10-22.

| Service | Notes |
|---|---|
| nginx | No ACME or bunny key here. TLS is the `*.joshuabell.xyz` + apex wildcard issued on h005 and pushed to `/var/lib/fleet-cert/joshuabell.xyz/current` (`hosts/_shared_assets/utilities/wildcard-cert-receiver.nix`); floating sites in `/var/lib/fleet-containers/nginx`. |
| restic backup | Containers: `fleet-backup` (`ringofstorms.containers.backup` in `floating-containers.nix`, one snapshot per `svc:<name>`). Host data (wd10 media, ~luser/backups): `mods/restic-backup.nix`. Both nightly at 03:00, same repo. |
| homepage-dashboard | Replaced by fleet-edge on h005; no redirect is left behind. |
| autofs NFS client, storage guard `fleet-guard-h004` | Host plumbing for `arr`. |
| Per-host agents | sec-agent, fail2ban, tailscaled. |
