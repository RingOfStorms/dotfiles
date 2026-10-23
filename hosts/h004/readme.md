| NFS server | Exports `/data/nixarr` only (C2; not backups);# h004
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);NAS for my home network. Rebuild of **h002** on new internals (same Fractal case,
| NFS server | Exports `/data/nixarr` only (C2; not backups);same 4× 12 TB IronWolf bcachefs pool). Built and onboarded as a separate host on
| NFS server | Exports `/data/nixarr` only (C2; not backups);the bench first, then the data drives moved over and h002 was retired.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);h004 was spawned out of **h002**, whose last config is at
| NFS server | Exports `/data/nixarr` only (C2; not backups);[`c1b72f9e` hosts/h002](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002)
| NFS server | Exports `/data/nixarr` only (C2; not backups);(including its planning notes,
| NFS server | Exports `/data/nixarr` only (C2; not backups);[`upgrade.md`](https://git.joshuabell.xyz/ringofstorms/dotfiles/src/commit/c1b72f9e1ae319ba2b65e4d63e1041bcf7e2a0ab/hosts/h002/upgrade.md)).
| NFS server | Exports `/data/nixarr` only (C2; not backups);Restore it locally with `git show c1b72f9e:hosts/h002/<file>` or
| NFS server | Exports `/data/nixarr` only (C2; not backups);`git restore --source=c1b72f9e hosts/h002`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);On h001 the capability is `nfs-h004`, the guard `fleet-guard-h004` and the sentinel
| NFS server | Exports `/data/nixarr` only (C2; not backups);`/data/nixarr/.h004-online` (created by nfs-server). Only the mount path `/nfs/h002` (`hosts/h001/autofs.nix` →
| NFS server | Exports `/data/nixarr` only (C2; not backups);`10.12.14.184`) keeps the old name: sonarr/radarr/bazarr/jellyfin/sabnzbd/transmission store
| NFS server | Exports `/data/nixarr` only (C2; not backups);absolute paths under it in their databases and configs.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Hardware
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Component | Spec |
| NFS server | Exports `/data/nixarr` only (C2; not backups);|---|---|
| NFS server | Exports `/data/nixarr` only (C2; not backups);| CPU | Intel Core Ultra 5 250K+ (6P+12E, iGPU + Quick Sync) |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Board | Gigabyte B860 DS3H WiFi6E (4× SATA, 2× M.2) |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| RAM | 32 GB DDR5-6000 (G.Skill Ripjaws S5) |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Boot | Inland TN320 256 GB NVMe |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| SATA card | Vantec UGT-ST655 5-port PCIe x4 |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| PSU | Corsair RM1000x |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Data | 4× Seagate IronWolf Pro ST12000NT001 12 TB (bcachefs pool from h002) + WD Red Plus 12 TB `WD-B01XWD2D` (burned in, added 2026-10-15; on the Vantec card), replicas=2, 50.2T raw |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Scratch | Seagate ST750LX003 750 GB hybrid (very old, ~84k hours): standalone unencrypted bcachefs at `/scratch`, throwaway data only |
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);IronWolf serials (label the cables): `ZRT2KQXT`, `ZRT2LRT8`, `ZRT2FJ7X`, `ZRT2GA17`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Bare-metal services
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Service | Notes |
| NFS server | Exports `/data/nixarr` only (C2; not backups);|---|---|
| NFS server | Exports `/data/nixarr` only (C2; not backups);| NFS server | Exports `/data`; consumed by h001 (`nfs-h004`). |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| Per-host agents | sec-agent, beszel-agent, fail2ban, tailscaled. |
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Config layout
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);| File | Role |
| NFS server | Exports `/data/nixarr` only (C2; not backups);|---|---|
| NFS server | Exports `/data/nixarr` only (C2; not backups);| `flake.nix` | Host modules. Root on the NVMe via `ringofstorms.impermanence` (bcachefs, **encrypted**, `usbKey = true`: a bcachefs USB stick with a `/key` file stays plugged in so it unlocks unattended; without the stick it waits for the passphrase on the console). The data pool itself is not encrypted |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| `impermanence.nix` | What survives a reboot (shared sets + secrets, `/var/lib/nfs`, smartd state). SSH host keys are persisted by the module itself (`/persist/etc/ssh`) |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| `data-pool.nix` | `/data` mount (gated by `dataPool.enable`, now **true**), `/scratch` mount, smartd |
| NFS server | Exports `/data/nixarr` only (C2; not backups);| `nfs-data.nix`, `nfs-data-users-nixarr.nix` | Copied from h002; only imported when `dataPool.enable = true` |
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);`dataPool.enable` was kept **false** through the bench and the first boot with the IronWolfs
| NFS server | Exports `/data/nixarr` only (C2; not backups);attached, so the pool was never mounted read-write (or upgraded) before it had been checked.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);**bcachefs version:** the pool came from h002 at on-disk format 1.38. h004's first read-write
| NFS server | Exports `/data/nixarr` only (C2; not backups);mount (bcachefs 1.39.6, kernel 6.18.56) upgraded it to **1.39** (about 3 minutes, mostly
| NFS server | Exports `/data/nixarr` only (C2; not backups);`check_allocations`), so an older bcachefs can no longer mount it. Check with:
| NFS server | Exports `/data/nixarr` only (C2; not backups);```sh
| NFS server | Exports `/data/nixarr` only (C2; not backups);ssh root@h004 'bcachefs show-super /dev/disk/by-id/ata-ST12000NT001-3LX101_ZRT2GA17 | grep -E "^Version|Oldest"'
| NFS server | Exports `/data/nixarr` only (C2; not backups);```
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Phase A: bench (done)
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);Only the NVMe (and optionally the new WD) connected. No IronWolfs.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);1. BIOS: latest firmware; UEFI only, CSM off; **Secure Boot off** (NixOS ISOs and systemd-boot aren't
| NFS server | Exports `/data/nixarr` only (C2; not backups);   signed); restore on AC loss → Power On; ASPM + deepest
| NFS server | Exports `/data/nixarr` only (C2; not backups);   C-states; VT-x on; disable RGB/Wi-Fi/Bluetooth if wired. Confirm the NVMe's M.2 slot doesn't
| NFS server | Exports `/data/nixarr` only (C2; not backups);   disable a SATA port (manual).
| NFS server | Exports `/data/nixarr` only (C2; not backups);2. Boot the installer ISO (`utilities/nixos-install-disko/readme.md`), SSH in.
| NFS server | Exports `/data/nixarr` only (C2; not backups);3. Disko single-drive, **encrypted** (choose a strong passphrase and store it in the password
| NFS server | Exports `/data/nixarr` only (C2; not backups);   manager), target the NVMe by id: `/dev/disk/by-id/nvme-…` (check `ls -l /dev/disk/by-id/ | grep nvme`).
| NFS server | Exports `/data/nixarr` only (C2; not backups);   Make the USB unlock stick now with the same passphrase (`utilities/nixos-install-disko/usb_key.md`),
| NFS server | Exports `/data/nixarr` only (C2; not backups);   label it "h004 key", and leave it in a rear USB port for good.
| NFS server | Exports `/data/nixarr` only (C2; not backups);4. `nixos-generate-config --no-filesystems --root /mnt`; copy the generated
| NFS server | Exports `/data/nixarr` only (C2; not backups);   `hardware-configuration.nix` over the placeholder here.
| NFS server | Exports `/data/nixarr` only (C2; not backups);5. `lsblk -o name,uuid` → fill `boot`/`primary`/`swap` in `flake.nix` (replace the `TODO-*`).
| NFS server | Exports `/data/nixarr` only (C2; not backups);6. Commit, then `nixos-install --flake <repo>/hosts/h004#h004`. First boot: confirm it unlocks
| NFS server | Exports `/data/nixarr` only (C2; not backups);   from the stick with no prompt; then pull the stick once and confirm the passphrase prompt works.
| NFS server | Exports `/data/nixarr` only (C2; not backups);7. **Do not** copy h002's identity yet. h004 enrolls as its own node:
| NFS server | Exports `/data/nixarr` only (C2; not backups);   create its machine identity in Zitadel / sec-agent like any new host (install readme, step 7),
| NFS server | Exports `/data/nixarr` only (C2; not backups);   join the tailnet, then set `host.overlayIp` in `_constants.nix` and the `h004` entry in
| NFS server | Exports `/data/nixarr` only (C2; not backups);   `hosts/fleet.nix`, and give it its own Beszel token.
| NFS server | Exports `/data/nixarr` only (C2; not backups);8. Verify: reboot twice (root wipes, `/persist` keeps); `ssh h004`; secrets hydrate;
| NFS server | Exports `/data/nixarr` only (C2; not backups);   `systemctl status smartd`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);9. WD Red Plus on the Vantec card: `lsblk`, confirm the card's chip (`lspci | grep -i sata`,
| NFS server | Exports `/data/nixarr` only (C2; not backups);   expect JMB585 or ASM1166), then burn in: `smartctl -t long /dev/disk/by-id/ata-WDC_…`
| NFS server | Exports `/data/nixarr` only (C2; not backups);   (~1 day; check with `smartctl -a`).
| NFS server | Exports `/data/nixarr` only (C2; not backups);10. Measure idle power with only the NVMe + WD.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Phase B: cutover (done, 2026-10-13)
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);1. SMART check the IronWolfs on h002 (`nix shell nixpkgs#smartmontools`), all PASSED, no
| NFS server | Exports `/data/nixarr` only (C2; not backups);   growing reallocated/pending counts.
| NFS server | Exports `/data/nixarr` only (C2; not backups);2. Stop the media stack while NFS is healthy: `containers stop arr --host h001`; confirm
| NFS server | Exports `/data/nixarr` only (C2; not backups);   `container@arr` is stopped. This hold persists across reboots, so the h002 guard can't
| NFS server | Exports `/data/nixarr` only (C2; not backups);   restart arr mid-migration.
| NFS server | Exports `/data/nixarr` only (C2; not backups);3. On h002, confirm `/data/.h002-online` exists (it lives in the pool, so it moves with it),
| NFS server | Exports `/data/nixarr` only (C2; not backups);   then `sudo poweroff`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);4. Move the IronWolfs to h004's **onboard** SATA ports (not the Vantec card), using only the
| NFS server | Exports `/data/nixarr` only (C2; not backups);   RM1000x's own SATA power cables.
| NFS server | Exports `/data/nixarr` only (C2; not backups);5. Boot h004 (still `dataPool.enable = false`, so nothing mounts). Check the pool with **no writes at
| NFS server | Exports `/data/nixarr` only (C2; not backups);   all**: `ro` alone still allows journal replay, `nochanges` blocks every write, and
| NFS server | Exports `/data/nixarr` only (C2; not backups);   `version_upgrade=none` blocks format upgrades:
| NFS server | Exports `/data/nixarr` only (C2; not backups);   ```sh
| NFS server | Exports `/data/nixarr` only (C2; not backups);   lsblk -o NAME,SIZE,MODEL,SERIAL
| NFS server | Exports `/data/nixarr` only (C2; not backups);   sudo mkdir -p /mnt/pooltest
| NFS server | Exports `/data/nixarr` only (C2; not backups);   sudo mount -t bcachefs -o ro,nochanges,version_upgrade=none UUID=53a26b95-941b-4f41-b049-c166905ed8c2 /mnt/pooltest
| NFS server | Exports `/data/nixarr` only (C2; not backups);   ls /mnt/pooltest; bcachefs fs usage -h /mnt/pooltest   # 4 devices, undegraded 2x
| NFS server | Exports `/data/nixarr` only (C2; not backups);   sudo dmesg | grep -i bcachefs | tail -30
| NFS server | Exports `/data/nixarr` only (C2; not backups);   sudo umount /mnt/pooltest
| NFS server | Exports `/data/nixarr` only (C2; not backups);   ```
| NFS server | Exports `/data/nixarr` only (C2; not backups);6. Set `dataPool.enable = true`, deploy, then `findmnt /data`, `systemctl status nfs-server`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);7. **Point h001 at h004** (h001's autofs uses `10.12.14.183`). Either:
| NFS server | Exports `/data/nixarr` only (C2; not backups);   - give h004 the old address: change the `H002` static lease in `hosts/h003/_constants.nix` to
| NFS server | Exports `/data/nixarr` only (C2; not backups);     h004's MAC (`ip link`), deploy h003, renew h004's lease; or
| NFS server | Exports `/data/nixarr` only (C2; not backups);   - change `hosts/h001/autofs.nix` + the `nfs-h002` guard to h004's address.
| NFS server | Exports `/data/nixarr` only (C2; not backups);   Then update `lanIp` for h004 in `hosts/fleet.nix`.
| NFS server | Exports `/data/nixarr` only (C2; not backups);8. `containers start arr --host h001`; check the guard brings it up and Jellyfin plays.
| NFS server | Exports `/data/nixarr` only (C2; not backups);9. Other h002 users: l001/o001 `ros-backup` (`flakes/common/nix_modules/backup.nix`, default
| NFS server | Exports `/data/nixarr` only (C2; not backups);   target `100.64.0.3` = h002's overlay IP) and h003 `remoteShutdownHosts`. Point them at h004
| NFS server | Exports `/data/nixarr` only (C2; not backups);   (and add their keys), or move h002's tailnet identity to h004. Run `ros-backup` once by hand.
| NFS server | Exports `/data/nixarr` only (C2; not backups);10. Add the WD to the pool:
| NFS server | Exports `/data/nixarr` only (C2; not backups);    `sudo bcachefs device add /data /dev/disk/by-id/ata-WDC_…` → `bcachefs fs usage -h /data`
| NFS server | Exports `/data/nixarr` only (C2; not backups);    (5 devices).
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Rollback
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);No longer possible: h002's hardware is gone (h004 lives in its case) and the pool is at format
| NFS server | Exports `/data/nixarr` only (C2; not backups);1.39. To bring the old config back, restore it from `c1b72f9e` (see top) and bump its
| NFS server | Exports `/data/nixarr` only (C2; not backups);flake.lock to a bcachefs ≥ 1.39 first.
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);## Retirement of h002 (done)
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);Removed from `hosts/fleet.nix`, `hosts/sec-agent.nix`, `containers/flake.nix` `containerHosts`,
| NFS server | Exports `/data/nixarr` only (C2; not backups);h003 DHCP + `remoteShutdownHosts`; `hosts/h002/` deleted (last at `c1b72f9e`). The backup
| NFS server | Exports `/data/nixarr` only (C2; not backups);module's default target is h004 (`100.64.0.17`).
| NFS server | Exports `/data/nixarr` only (C2; not backups);
| NFS server | Exports `/data/nixarr` only (C2; not backups);Still to do by hand:
| NFS server | Exports `/data/nixarr` only (C2; not backups);- Delete h002's node in headscale (`headscale nodes list`, then `headscale nodes delete -i <id>`).
| NFS server | Exports `/data/nixarr` only (C2; not backups);- Retire the Kingston SSD and the old board/CPU/RAM/GPU.
