# i001

Mini PC (Intel N95). **Living-room TV media box** (took over that role from
gp3). Low trust: user `luser`, `machines-lowtrust` secrets, `tag:lowtrust` on
headscale.

## Hardware

| Component | Spec |
|---|---|
| CPU | Intel N95 (4C/4T, up to 3.4 GHz) |
| GPU | Intel UHD Graphics (integrated) |
| RAM | 16 GB |
| Storage | 512 GB SATA SSD (HUGWORLD), `/dev/sda` |

## Disk layout

Single SATA SSD, encrypted bcachefs with impermanence (`hosts/i001/flake.nix`
`ringofstorms.impermanence.disk`):

| Partition | Size | FS | UUID | Use |
|---|---|---|---|---|
| `sda1` | 1.9 GB | vfat | `635D-F0DA` | `/boot` (ESP) |
| `sda2` | 467.6 GB | bcachefs (encrypted) | `82cb11a7-097a-4e95-b9f0-47dad95de9df` | subvols `@root` `@nix` `@persist` `@snapshots` |
| `sda3` | 7.5 GB | swap | `29c89516-e6ed-4f91-adf7-646451a8e26f` | swap |

- `/` is wiped each boot. What survives is listed in `impermanence.nix` (shared
  set + `/var/lib/secrets_manager_hydrated`, Spotify login). Old roots land in
  `/.snapshots/old_roots`.
- **Unlock:** `usbKey = true`. A USB stick holding the bcachefs `/key` stays
  plugged in, so the TV boots unattended (see
  `utilities/nixos-install-disko/usb_key.md`). Without the stick, boot asks
  for the disk passphrase.
- If you re-image, update all three UUIDs in `flake.nix` (the bcachefs one
  may stay the same; see the install readme gotchas).

## TV role

- **Session:** SDDM autologins `luser` into **Plasma Bigscreen** (Wayland).
  Normal Plasma stays selectable in SDDM. Bigscreen needs Plasma >= 6.7, so
  this host tracks nixos-unstable.
- **Apps:** Jellyfin desktop, Spotify, Firefox, Chrome, and a Jellyseerr app
  window (`https://media.joshuabell.xyz`). Homescreen favorites and the
  hidden-app list are seeded by home-manager on each activation; in-session
  tweaks last only until reboot (home is wiped).
- **Steam:** Remote Play *client* for joe only, not for local games. Controller
  udev rules are on and `luser` is in `input` for `/dev/uinput`.
- **Bluetooth:** on at boot for controllers and headphones; pairings persist
  in `/var/lib/bluetooth`.
- **Hardware decode:** Intel VA-API; check with `vainfo`.

## Deploy

From lio (low trust, so it never builds anything itself):

```sh
NIX_SSHOPTS="-i /var/lib/secrets_manager_hydrated/nix2nix_2026-03-15" \
  nixos-rebuild --flake './hosts/i001#i001' --target-host root@10.12.14.119 \
  --use-substitutes --no-reexec switch
```
