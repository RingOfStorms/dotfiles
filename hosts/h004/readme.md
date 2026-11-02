# h004

NAS for my home network. It is a rebuild of **h002** on new internals, in the same Fractal case and with the same
IronWolf bcachefs pool. h002's last config is at
[`c1b72f9e` hosts/h002](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002)
(including its planning notes,
[`upgrade.md`](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002/upgrade.md)).
Restore it locally with `git show c1b72f9e:hosts/h002/<file>` or `git restore --source=c1b72f9e hosts/h002`.

h004 runs no untrusted workloads: no containers module and no guest services, only the bare-metal services below.
The local protection of `/data/backups` depends on that.

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
- **`/data/backups`** is its own bcachefs subvolume, mode `0700`. `ensure-backups-subvolume` re-asserts the subvolume
  and the mode on every boot and activation, and refuses to migrate a plain directory by itself.
- **`/scratch`** is a standalone throwaway disk, also `nofail`.

The pool is at on-disk format **1.39**, so an older bcachefs can no longer mount it. Check with:

```sh
ssh root@h004 'bcachefs show-super /dev/disk/by-id/ata-ST12000NT001-3LX101_ZRT2GA17 | grep -E "^Version|Oldest"'
```

## Bare-metal services

| Service | Notes |
|---|---|
| NFS server | Exports `/data/nixarr` only (not `/data/backups` or the rest of `/data`), `subtree_check,root_squash`, to h001's LAN and overlay IPs. The NFS ports are admitted from those addresses only. |
| smartd | Short test weekly, long test monthly, warns on attribute changes. |
| Per-host agents | sec-agent, fail2ban, tailscaled. |

## Firewall

h004 does not trust `tailscale0` and opens no global ports. ssh is allowed from high-trust overlay IPs (v4 and v6) and
from the home LAN as a fallback, with low-trust LAN devices rejected. See [`hosts/README.md`](../README.md#firewall).

## Config layout

| File | Role |
|---|---|
| `flake.nix` | Host modules, including the encrypted impermanent root |
| `impermanence.nix` | What survives a reboot (shared sets + secrets, `/var/lib/nfs`, smartd state). SSH host keys are persisted by the module itself (`/persist/etc/ssh`) |
| `data-pool.nix` | `/data` mount (gated by `dataPool.enable`), `/scratch` mount, smartd |
| `nfs-data.nix` | The `/data/nixarr` export, NFS firewall rules and `ensure-backups-subvolume` |
| `nfs-data-users-nixarr.nix` | Media uids/gids and directory modes matching the arr container on h001 |
| `firewall.nix` | ssh rules and the ssh guard assertion |

`dataPool.enable` gates every `/data` consumer, so a reinstall on the bench, or a first boot with unchecked drives,
never mounts (or format-upgrades) the pool. To check a pool with no writes at all, mount it with
`ro,nochanges,version_upgrade=none` before setting `dataPool.enable = true`.

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
