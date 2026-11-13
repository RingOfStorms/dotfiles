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
`/srv/containers/zitadel/keys/masterkey`. The break-glass runbook is in
[`containers/sec/README.md`](../../containers/sec/README.md#break-glass-kit-and-cold-restore);
the current offline credential export and data-copy availability need their
own confirmation. The pre-cutover data
(`/var/lib/zitadel`, `/var/lib/secrets_manager`) was archived to
`/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001 and deleted on
2026-10-22.

| Service | Notes |
|---|---|
| nginx | No ACME or bunny key here. TLS is the `*.joshuabell.xyz` + apex wildcard issued on h005 and pushed to `/var/lib/fleet-cert/joshuabell.xyz/current` (`hosts/_shared_assets/utilities/wildcard-cert-receiver.nix`); floating sites in `/var/lib/fleet-containers/nginx`. |
| fleet-backup client | Nightly 03:00 per-subject snapshots to h004's private append-only `svc-<subject>` repositories. `floating-containers.nix` enables container backups and `h001-archives` (`/home/luser/backups`); Immich/Paperless include declared `/srv/bulk` media/consume paths. h001 has no new B2 pusher key and never prunes. On 2026-11-13 h001 was switched: legacy `restic-backups-h001` timer/service are absent and inactive, while `fleet-backup.timer` is active. The old secret's active registry fields/grants and h001/h003 hydrated copies are removed; lio still needs privileged cleanup and juni/oren/gp3 were unreachable. External B2 revocation remains a user-account P6 step. |
| homepage-dashboard | Replaced by fleet-edge on h005; no redirect is left behind. |
| autofs NFS client, storage guard `fleet-guard-h004` | Host plumbing for `arr`. |
| Per-host agents | sec-agent, fail2ban, tailscaled. |

## Backup coverage and recovery

The enduring [backup runbook](../../containers/README.md#nightly-restic-fleet-backup)
describes subject credentials, policy, retention and restore commands. h004
performs local retention and copies offsite-enabled subjects to B2. A declared
offsite flag alone is not proof of a completed copy: consult the target's
per-subject completion record at its `checkedAt` time. All 15 previously
enabled replacement B2 subjects, including Immich, had successful checks on
2026-11-13; later snapshots require later checks. Minecraft is newly enabled
offsite, with its first completed copy not yet confirmed.

`h001-archives` is deliberately h004-only (accepted 2026-11-12): originals
remain on h001 and the backup is on h004. Its older B2 history still exists in
the legacy repository. P6 stops future legacy writes and retires the shared
credential; **P6b** deletes legacy history, and is deferred until B2-only
recovery and the requested h001 → h003 restore/move proof. The seven-day
waiting gate was waived on 2026-11-13, not the recovery or deletion gates.
Losing both h001 and h004 after that deletion loses these local-only archives.

`litellm`, `llm-router`, `searx`, `hello-nixos` and `hello-podman` have
`backup.enable = false` by the user's disposable-data decision on 2026-11-13.
Existing local and legacy snapshots are not deleted by that setting. These
services are not candidates for the backup-driven `cnt move` path; redeploy
them deliberately rather than assuming their state will be restored.

`/srv/bulk` is not backed up wholesale: personal/historical folders outside
the declared media paths and `/home/luser/backups` remain outside this policy.
Likewise the NFS media tree `/nfs/h002/nixarr` belongs to h004 and is not part
of `svc-arr`. The dated [data inventory](../../containers/INVENTORY.md) records
the distinct archives and paths without authorizing their deletion. In
particular `/root/retired-2026-10-22-zitadel-sec.tar.zst` is outside current
subjects; it is historical rollback data, not a verified duplicate of today's
sec/Zitadel backups.
