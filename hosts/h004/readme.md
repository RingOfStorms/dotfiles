# h004

NAS for my home network. Rebuild of **h002** on new internals (same Fractal case,
same 4× 12 TB IronWolf bcachefs pool). Built and onboarded as a separate host on
the bench first, then the data drives move over and h002 retires. Original
planning notes: `hosts/h002/upgrade.md`.

## Hardware

| Component | Spec |
|---|---|
| CPU | Intel Core Ultra 5 250K+ (6P+12E, iGPU + Quick Sync) |
| Board | Gigabyte B860 DS3H WiFi6E (4× SATA, 2× M.2) |
| RAM | 32 GB DDR5-6000 (G.Skill Ripjaws S5) |
| Boot | Inland TN320 256 GB NVMe |
| SATA card | Vantec UGT-ST655 5-port PCIe x4 |
| PSU | Corsair RM1000x |
| Data | 4× Seagate IronWolf Pro ST12000NT001 12 TB (bcachefs pool from h002), + WD Red Plus 12 TB (to add) |

IronWolf serials (label the cables): `ZRT2KQXT`, `ZRT2LRT8`, `ZRT2FJ7X`, `ZRT2GA17`.

## Config layout

| File | Role |
|---|---|
| `flake.nix` | Host modules. Root on the NVMe via `ringofstorms.impermanence` (bcachefs, **unencrypted**: headless and must reboot unattended; the data pool is unencrypted anyway) |
| `impermanence.nix` | What survives a reboot (shared sets + secrets, `/var/lib/nfs`, smartd state). SSH host keys are persisted by the module itself (`/persist/etc/ssh`) |
| `data-pool.nix` | `/data` mount + smartd. `/data` is only declared when `dataPool.enable = true` in `_constants.nix` |
| `nfs-data.nix`, `nfs-data-users-nixarr.nix` | Copied from h002; only imported when `dataPool.enable = true` |

`dataPool.enable` defaults to **false**. That keeps the bench box from serving an empty export,
and it keeps the first boot with the IronWolfs attached from mounting the pool read-write
automatically (which could upgrade its on-disk format before you have checked it).

**bcachefs version:** h002 runs kernel 6.18.44 with the bcachefs module 1.38.8; h004's
config builds the same kernel and module (`6.18.44-1.38.8`), and the pool is at on-disk
format 1.38. Recheck before cutover if either flake.lock moves:
```sh
nix eval --raw ./hosts/h004#nixosConfigurations.h004.config.boot.kernelPackages.bcachefs.version
ssh h002 'modinfo bcachefs | grep ^version'
```

## Phase A: bench (h002 stays live)

Only the NVMe (and optionally the new WD) connected. No IronWolfs.

1. BIOS: latest firmware; UEFI only, CSM off; restore on AC loss → Power On; ASPM + deepest
   C-states; VT-x on; disable RGB/Wi-Fi/Bluetooth if wired. Confirm the NVMe's M.2 slot doesn't
   disable a SATA port (manual).
2. Boot the installer ISO (`utilities/nixos-install-disko/readme.md`), SSH in.
3. Disko single-drive, **unencrypted**, target the NVMe by id:
   `/dev/disk/by-id/nvme-…` (check `ls -l /dev/disk/by-id/ | grep nvme`).
4. `nixos-generate-config --no-filesystems --root /mnt`; copy the generated
   `hardware-configuration.nix` over the placeholder here.
5. `lsblk -o name,uuid` → fill `boot`/`primary`/`swap` in `flake.nix` (replace the `TODO-*`).
6. Commit, then `nixos-install --flake <repo>/hosts/h004#h004`.
7. **Do not** copy h002's identity yet. h004 enrolls as its own node:
   create its machine identity in Zitadel / sec-agent like any new host (install readme, step 7),
   join the tailnet, then set `host.overlayIp` in `_constants.nix` and the `h004` entry in
   `hosts/fleet.nix`, and give it its own Beszel token.
8. Verify: reboot twice (root wipes, `/persist` keeps); `ssh h004`; secrets hydrate;
   `systemctl status smartd`.
9. WD Red Plus on the Vantec card: `lsblk`, confirm the card's chip (`lspci | grep -i sata`,
   expect JMB585 or ASM1166), then burn in: `smartctl -t long /dev/disk/by-id/ata-WDC_…`
   (~1 day; check with `smartctl -a`).
10. Measure idle power with only the NVMe + WD.

## Phase B: cutover

1. SMART check the IronWolfs on h002 (`nix shell nixpkgs#smartmontools`), all PASSED, no
   growing reallocated/pending counts.
2. Stop the media stack while NFS is healthy: `containers stop arr --host h001`; confirm
   `container@arr` is stopped. This hold persists across reboots, so the h002 guard can't
   restart arr mid-migration.
3. On h002, confirm `/data/.h002-online` exists (it lives in the pool, so it moves with it),
   then `sudo poweroff`.
4. Move the IronWolfs to h004's **onboard** SATA ports (not the Vantec card), using only the
   RM1000x's own SATA power cables.
5. Boot h004 (still `dataPool.enable = false`, so nothing mounts). Check the pool with **read-only,
   no upgrade**:
   ```sh
   lsblk -o NAME,SIZE,MODEL,SERIAL
   sudo mkdir -p /mnt/pooltest
   sudo mount -t bcachefs -o ro,version_upgrade=none UUID=53a26b95-941b-4f41-b049-c166905ed8c2 /mnt/pooltest
   ls /mnt/pooltest; bcachefs fs usage -h /mnt/pooltest   # 4 devices, undegraded 2x
   sudo dmesg | grep -i bcachefs | tail -30
   sudo umount /mnt/pooltest
   ```
6. Set `dataPool.enable = true`, deploy, then `findmnt /data`, `systemctl status nfs-server`.
7. **Point h001 at h004** (h001's autofs uses `10.12.14.183`). Either:
   - give h004 the old address: change the `H002` static lease in `hosts/h003/_constants.nix` to
     h004's MAC (`ip link`), deploy h003, renew h004's lease; or
   - change `hosts/h001/autofs.nix` + the `nfs-h002` guard to h004's address.
   Then update `lanIp` for h004 in `hosts/fleet.nix`.
8. `containers start arr --host h001`; check the guard brings it up and Jellyfin plays.
9. Other h002 users: l001/o001 `ros-backup` (`flakes/common/nix_modules/backup.nix`, default
   target `100.64.0.3` = h002's overlay IP) and h003 `remoteShutdownHosts`. Point them at h004
   (and add their keys), or move h002's tailnet identity to h004. Run `ros-backup` once by hand.
10. Add the WD to the pool:
    `sudo bcachefs device add /data /dev/disk/by-id/ata-WDC_…` → `bcachefs fs usage -h /data`
    (5 devices).

## Rollback

Until step 6, the pool is untouched: power down h004, move the IronWolfs back, boot h002,
`containers start arr --host h001`. After h004 has mounted the pool read-write, the format may
have been upgraded; same kernel + module (1.38.8) means it shouldn't be, but check `show-super`
before relying on h002 again.

## After a few stable weeks

- Remove `h002` from `hosts/fleet.nix`, `hosts/sec-agent.nix`, `containers/flake.nix`
  `containerHosts`, h003 DHCP; delete its headscale node; archive `hosts/h002/`.
- Rename the `nfs-h002` capability/guard on h001 if you want the names to match.
- Retire the Kingston SSD and the old board/CPU/RAM/GPU.
