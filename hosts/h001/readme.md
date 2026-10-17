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

Everything else runs as floating containers (`cnt ls`).

| Service | Notes |
|---|---|
| sec (secrets_manager server) | `mods/sec.nix`, `127.0.0.1:8300`. Planned to float (`containers/MIGRATION-PLAN.md`). |
| zitadel | nspawn container defined in the host config (`containers/zitadel.nix`), not managed by `cnt`. Planned to float. |
| nginx + ACME | Wildcard `*.joshuabell.xyz` (bunny DNS-01); floating sites in `/var/lib/fleet-containers/nginx`. ACME moves to h005 (`containers/ROUTING-PLAN.md`). |
| restic backup | `mods/restic-backup.nix`, nightly. |
| homepage-dashboard | To be replaced by the fleet dashboard. |
| autofs NFS client, storage guard `fleet-guard-h004` | Host plumbing for `arr`. |
| Per-host agents | sec-agent, beszel-agent, fail2ban, tailscaled. |
