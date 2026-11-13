# h004

NAS for my home network. It is a rebuild of **h002** on new internals, in the same Fractal case and with the same
IronWolf bcachefs pool. h002's last config is at
[`c1b72f9e` hosts/h002](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002)
(including its planning notes,
[`upgrade.md`](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002/upgrade.md)).
Restore it locally with `git show c1b72f9e:hosts/h002/<file>` or `git restore --source=c1b72f9e hosts/h002`.

h004 runs no untrusted workloads: no containers module and no guest services, only the bare-metal services below.
It is the fleet's backup target and B2 pusher; its root can read the repositories it holds for retention and recovery.
Append-only client access is not a boundary against a compromised h004 root.

On h001 the capability is `nfs-h004`, the guard `fleet-guard-h004` and the sentinel
`/data/nixarr/.h004-online` (touched by `nfs-server` before it starts). Only the mount path keeps the old name:
`hosts/h001/autofs.nix` mounts `10.12.14.184:/` at `/nfs/h002/nixarr`, because
sonarr/radarr/bazarr/jellyfin/sabnzbd/transmission store absolute paths under it in their databases and configs.

## Hardware

| Component | Spec |
|---|---|
| CPU | Intel Core Ultra 5 250K+ (6P+12E, iGPU + Quick Sync) |
| Board | Gigabyte B860 DS3H WiFi6E (4× SATA, 2× M.2) |
| RAM | 32 GB DDR5-6000 (G.Skill Ripjaws S5) |
| Boot | Inland TN320 256 GB NVMe |
| SATA card | Vantec UGT-ST655 5-port PCIe x4 |
| PSU | Corsair RM1000x |
| Data | 4× Seagate IronWolf Pro ST12000NT001 12 TB (onboard SATA, from h002) + WD Red Plus 12 TB `WD-B01XWD2D` (Vantec card), replicas=2, 50.2T raw |
| Scratch | Seagate ST750LX003 750 GB hybrid (very old, ~84k hours): standalone unencrypted bcachefs at `/scratch`, throwaway data only |

IronWolf serials (label the cables): `ZRT2KQXT`, `ZRT2LRT8`, `ZRT2FJ7X`, `ZRT2GA17`.

## Storage

- **Root** is the NVMe, impermanent via `ringofstorms.impermanence` (bcachefs, **encrypted**, `usbKey = true`).
  A bcachefs USB stick with a `/key` file stays plugged in, so the host unlocks unattended. Without the stick it waits
  for the passphrase on the console.
- **`/data`** is the bcachefs pool: **unencrypted**, `replicas=2` (survives one drive loss), mounted with `nofail` so a
  pool that cannot mount does not block boot. `nfs-server` and `ensure-backups-subvolume` require `data.mount`, so a
  missing pool means no export rather than an export of the empty mountpoint.
- **`/data/backups`** is its own bcachefs subvolume, mode `0700`, owned by `restic:restic` while the backup target is enabled. `ensure-backups-subvolume` re-asserts the subvolume and ownership on every boot and activation, refuses to migrate a plain directory by itself, and refuses unexpected entries instead of chowning old data. The repositories are `svc-<subject>/`; this tree is never an NFS export.
- **`/data/rsync-archive`** holds the retired `l001` and `o001` rsync trees moved out of `/data/backups` during target setup. Their June 24–25, 2026 snapshots and `latest` pointers are historical archives, not current automated backups. No independent copy is confirmed; do not delete them as target scaffolding.
- **`/scratch`** is a standalone throwaway disk, also `nofail`.

The pool is at on-disk format **1.39**, so an older bcachefs can no longer mount it. Check with:

```sh
ssh root@h004 'bcachefs show-super /dev/disk/by-id/ata-ST12000NT001-3LX101_ZRT2GA17 | grep -E "^Version|Oldest"'
```

## Bare-metal services

| Service | Notes |
|---|---|
| NFS server | Exports `/data/nixarr` only (not `/data/backups` or the rest of `/data`), `subtree_check,root_squash`, to h001's LAN and overlay IPs. The NFS ports are admitted from those addresses only. |
| rest-server backup target | `restic-rest-server.service`, private append-only repositories at `/data/backups/svc-<subject>`, REST port 8000 admitted only from configured overlay clients. Subject logins and held repository passwords come from h005 fleet-edge. |
| Backup maintenance and B2 pusher | `fleet-backup-target-prune` owns local retention; `fleet-backup-pusher-copy` copies offsite-enabled subjects, applies B2 retention and writes completion records. Only this pusher holds its `svc-`-scoped B2 key; clients never prune or receive that key. |
| smartd | Short test weekly, long test monthly, warns on attribute changes. |
| Per-host agents | sec-agent, fail2ban, tailscaled. |

## Firewall

h004 does not trust `tailscale0` and opens no global ports. ssh is allowed from high-trust overlay IPs (v4 and v6) and
from the home LAN as a fallback, with low-trust LAN devices rejected. The backup target separately admits port 8000 from its generated high-trust overlay allow-list (IPv4 and IPv6); LAN backup access stays closed. Low-trust clients require explicit `ringofstorms.backup.target.lowTrustClients` admission, per-subject authorization **and** a narrow Headscale ACL: current low-trust outbound rules block Joe. Review Joe-source access to h004:8000 and required h005/auth endpoints; do not broadly allow low-trust access to trusted hosts. Joe is not enabled and no network change is made here. See [`hosts/README.md`](../README.md#firewall).

## Config layout

| File | Role |
|---|---|
| `flake.nix` | Host modules, including the encrypted impermanent root |
| `impermanence.nix` | What survives a reboot (shared sets + secrets, `/var/lib/nfs`, smartd state). SSH host keys are persisted by the module itself (`/persist/etc/ssh`) |
| `data-pool.nix` | `/data` mount (gated by `dataPool.enable`), `/scratch` mount, smartd |
| `nfs-data.nix` | The `/data/nixarr` export, NFS firewall rules and `ensure-backups-subvolume` |
| `flake.nix` backup tiers | Pool-gated `ringofstorms.backup.target` and `pusher`; modules live in `flakes/fleet-agent/backup/{target,pusher}.nix` |
| `nfs-data-users-nixarr.nix` | Media uids/gids and directory modes matching the arr container on h001 |
| `firewall.nix` | ssh rules and the ssh guard assertion |

`dataPool.enable` gates every `/data` consumer, so a reinstall on the bench, or a first boot with unchecked drives,
never mounts (or format-upgrades) the pool. To check a pool with no writes at all, mount it with
`ro,nochanges,version_upgrade=none` before setting `dataPool.enable = true`.

## Backup target and offsite pusher

The [fleet backup runbook](../../containers/README.md#nightly-restic-fleet-backup)
is the enduring reference for subject declarations, policy, retention and
restore commands. Clients write one encrypted repository per subject through
`rest:http://100.64.0.17:8000/svc-<subject>/`. rest-server isolates logins by
repository path and refuses snapshot deletion through the client endpoint.
Local prune, stats, clear and offsite-copy jobs run as `restic`, not root, so
they do not leave root-owned repository files. Target jobs require `/data`
to be mounted: a missing pool must not accept backups onto the NVMe's empty
mountpoint.

| Unit | Normal schedule / role |
|---|---|
| `fleet-backup-target-heartbeat` | 2 minutes after boot, then every 5 minutes (+ up to 30 seconds): register target/stats, refresh policy, REST logins and held repo keys, acknowledge queued actions |
| `fleet-backup-target-prune` | Daily 06:00 (+ up to 30 minutes), persistent: local per-repo retention |
| `fleet-backup-target-stats` | 10 minutes after boot, then hourly: local raw-data size and newest snapshot |
| `fleet-backup-pusher-copy` | Daily 07:30, persistent: copy the B2 keep-set, prune B2, measure and verify each offsite subject |

Run operations without opening secret files:

```sh
# On h004, as an administrator; these are real maintenance runs, not dry runs.
sudo systemctl start fleet-backup-target-heartbeat
sudo systemctl start fleet-backup-target-stats
sudo systemctl start fleet-backup-pusher-copy
sudo journalctl -u fleet-backup-pusher-copy -n 100 --no-pager
sudo jq 'to_entries[] | {subject: .key, complete: .value.complete, missing: .value.missing, checkedAt: .value.checkedAt}' /var/lib/fleet-backup-target/offsite-b2.json
```

State under `/var/lib/fleet-backup-target/` includes `policy.json`,
`stats.json`, `b2-stats.json`, `offsite-b2.json` and clear/lock bookkeeping.
`/var/lib/fleet-backup-target-keys/` holds root-only applied revisions, REST
logins and `repo-keys/svc-<subject>` password files: do not print or copy those
into logs. The restic cache under `/var/cache/fleet-backup-target/` is not
another backup. h005 is the credential authority; export its generated
subject passwords to the password manager separately from h004's B2 key.

Local retention uses cached policy if h005 is down, falling back to `long`
when no usable per-subject preset is known. The pusher refuses copy/clear
when its policy reply is missing or over 30 minutes old. An offsite-enabled
policy row is therefore not proof of a completed B2 copy. The completion
record matches the **local repo's** B2 retention set by original snapshot
identity and metadata, plus a sampled `restic check`; read it with each
subject's `checkedAt`. Sizes, process reads and a running upload are not
completeness evidence.

On 2026-11-13 all 15 previously enabled B2 subjects, including Immich, had
successful checks. Minecraft is newly enabled offsite but its first complete
copy is not yet confirmed. `h001-archives` deliberately remains local-only:
h001 originals plus h004 backup. Joe/LocalAI is not enrolled and has no
reported target repository. The disposable litellm, llm-router, searx and
hello-* subjects have backups disabled; existing repositories/history are
not implicitly deleted. See the dated [inventory](../../containers/INVENTORY.md)
for source paths and historical archives, not as a live status view.

**Recovery:** ordinary subject restore and application checks are in the
fleet runbook. If h004 is lost, recover from B2 using the off-fleet subject
password export and the pusher's bucket key; do not depend on h005's API or
`fleet-restic` for that disaster path. Filesystem replicas do not cover
logical deletion, a compromised target or loss of the site. Preserve
`/data/rsync-archive` and accepted local-only data when reinstalling or
changing the pool; they have no verified replacement offsite copy.

**Legacy separation:** P6 removes future writes and the old shared
credential; it does not delete old B2 history. On 2026-11-13 h001 was switched:
the legacy timer/service are absent/inactive and `fleet-backup.timer` is
active. Sec's old-secret active registry fields/grants and h001/h003 hydrated
copies were removed. No copy was found on h004/h005/o002; lio still needs
privileged cleanup and juni/oren/gp3 were unreachable. External B2 key
revocation through the user's account remains pending, so P6 is not fully
closed. P6b
legacy deletion remains deferred until credential retirement, B2-only
recovery and the requested h001 → h003 restore/move proof. The seven-day
waiting gate was waived on 2026-11-13; the recovery/deletion gates were not.
The label `7f023d4a` is not a verified B2 prefix: safely identify the actual
legacy repository URL before any deletion. The new pusher's `svc-` key does
not cover it.

## Reinstalling

1. BIOS: UEFI only, CSM off, **Secure Boot off**, restore on AC loss → Power On, ASPM + deepest C-states, VT-x on.
2. Install from the ISO (`utilities/nixos-install-disko/readme.md`): disko single-drive, **encrypted**, on the NVMe by
   id. Make the USB unlock stick with the same passphrase (`utilities/nixos-install-disko/usb_key.md`) and leave it in
   a rear USB port.
3. Fill `boot`/`primary`/`swap` in `flake.nix` from `lsblk -o name,uuid` and copy `hardware-configuration.nix` over.
4. `nixos-install --flake <repo>/hosts/h004#h004`. Confirm it unlocks from the stick, and that the passphrase prompt
   works without it.
5. h004 enrolls as its own node: machine identity in Zitadel / sec-agent, tailnet, `host.overlayIp` in
   `_constants.nix`, the `h004` entry in `hosts/fleet.nix`, its own Beszel token.

## h002 leftovers

h002's headscale node (`headscale nodes delete -i <id>`) and its old hardware (Kingston SSD, board/CPU/RAM/GPU) still
need retiring by hand.
