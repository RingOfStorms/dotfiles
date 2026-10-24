# pikvm — PiKVM V4 Mini

Surveyed 2026-10-24 over `ssh -i ~/.ssh/temppi root@pikvm`.

## Base

- OS: PiKVM OS (Arch Linux ARM, armv7l), kernel `6.12.56-8-rpi`, `kvmd 4.168-1`
- Platform package: `kvmd-platform-v4mini-hdmi-rpi4`
- Hostname: `pikvm` (default, same on the tailnet)
- Root filesystem is **read-only**. Run `rw` before changes and `ro` after.
- Update with `pikvm-update`. Do not use plain `pacman -Syu`.
- Timezone was left at the image default, `Europe/Moscow`.
- Network: stock `eth0` DHCP (`/etc/systemd/network/eth0.network`, `ClientIdentifier=mac`). No Wi-Fi is configured.
- `/boot/config.txt` is stock for the V4 Mini.
- Fan (`/etc/kvmd/fan.ini`) is stock (`kvmd-fan`, idle/low = 27).

## Tailscale (from the PiKVM guide, connected to headscale)

- Package: `tailscale-pikvm 0.7-1`. `tailscaled.service` is enabled.
- **Control server: `https://headscale.joshuabell.xyz`**, not tailscale.com.
  - Tailnet user is `josh`. The IP is `100.64.0.16`. No tags, routes, exit node or Tailscale SSH.
  - Accepts DNS from the tailnet (`CorpDNS: true`).
  - Join command: `tailscale up --login-server https://headscale.joshuabell.xyz`
- Stock PiKVM drop-in `/etc/systemd/system/tailscaled.service.d/pikvm-logs-dir.conf` sends logs to tmpfs.
- `/etc/default/tailscaled` sets `--no-logs-no-support`, which turns off telemetry.

## Custom setup: USB identity spoofing and feature toggles

These are the changes that do not come from the standard guides. They were made around 2026-05-28/29 by an external script named `apply-identity.sh`. That script is **not on the device and not in this repo**. Find it or recreate it from the details below.

1. **USB OTG identity**: `/etc/kvmd/override.d/0100-identity.yaml`. The PiKVM shows up as an ordinary USB HID device instead of "PiKVM". The real values are kept only on the device. The repo copy is a template.
2. **HDMI EDID**: `/etc/kvmd/tc358743-edid.hex` has been replaced with the EDID of a real retail monitor (with audio), so the target sees a normal monitor. The file is read-only (0444). `switch-edid.hex` is a symlink to it. The real file is **not** kept in the repo.
3. **`/usr/local/bin/kvmctl`**: a helper script that toggles features through override files, then validates with `kvmd -M` and restarts kvmd. It switches to rw/ro by itself.
   - `kvmctl status`
   - `kvmctl enable|disable msd`: msd is off when `0200-feature-msd.yaml` exists (`kvmd.msd.type: disabled`). **It is currently DISABLED.**
   - `kvmctl enable|disable audio`: writes `0200-feature-audio.yaml` (`otg.devices.audio.enabled: true`). It is currently off.

`/etc/kvmd/override.yaml` has only the stock comments. All customization is in `override.d/`.

## Other state

- MSD partition (`/var/lib/kvmd/msd`) still holds images: an ASUS P8Z68-V GEN3 BIOS ROM (`3402`), a CachyOS ISO and a NixOS 25.11 minimal ISO. To use them, run `kvmctl enable msd`.
- Auth:
  - Web user `admin` (`/etc/kvmd/htpasswd`).
  - IPMI user `admin`.
  - VNC passwd file is stock (VNC is not enabled).
  - 2FA/TOTP is **not** enabled (`totp.secret` is empty).
- SSH:
  - `PermitRootLogin yes`. Password auth is still at the default (on).
  - `/root/.ssh/authorized_keys` holds a single ed25519 key (`temppi`), added 2026-10-24.
- Web UI: `web.css` and `meta.yaml` are stock. The nginx SSL cert is the self-signed default.
- Enabled services are stock: kvmd, kvmd-nginx, kvmd-janus, kvmd-media, kvmd-oled*, kvmd-otg, kvmd-pst, kvmd-tc358743, kvmd-watchdog, kvmd-webterm, tailscaled, sshd, watchdog, rngd.
- No cron. No other packages beyond the PiKVM image.

## Maintenance checklist

- `pikvm-update` from time to time, then reboot.
- After updates, check the following:
  - `kvmctl status` still works.
  - `override.d/0100-identity.yaml` still applies: on the target, `lsusb` should show the spoofed VID:PID.
  - `kvmd-edidconf` still reports the spoofed monitor. Updates could replace the `.hex` file.
- Check that headscale still lists `pikvm` as online (`tailscale status`).
- Optional hardening:
  - Turn on TOTP (`kvmd-totp init`).
  - Turn off SSH password auth.
  - Change the web/IPMI `admin` passwords from the defaults if that has not been done (`kvmd-htpasswd set admin`).
  - Set the timezone (`timedatectl set-timezone`).

## Repo copies

The custom files were copied from the device into `hosts/pikvm/pikvm_v4mini/` on 2026-10-24:

- `override.d/0100-identity.yaml` (template, placeholders only) and `override.d/0200-feature-msd.yaml` go in `/etc/kvmd/override.d/`
- `kvmctl` goes in `/usr/local/bin/kvmctl`
- `tailscaled` goes in `/etc/default/tailscaled`

If `kvmctl`, `0200-feature-msd.yaml` or `tailscaled` change on the device, copy them back here. **Never** copy the live `0100-identity.yaml` or `tc358743-edid.hex` back into the repo. They contain the private identity values. The repo `0100-identity.yaml` must stay a placeholder template.

### kvmctl caveat (audio)

`kvmctl` is kept as an exact copy of the script on the device. It has one known problem: `enable|disable audio` writes or removes `otg.devices.audio` and then restarts only `kvmd`. The USB gadget is built by `kvmd-otg` at boot, and the [PiKVM audio docs](https://docs.pikvm.org/audio/) say a **reboot** is needed for this setting to take effect. So after toggling audio, run `reboot`.

`kvmctl status` only checks whether the override file exists. It does not show whether the USB microphone is actually active. To check the real state, look on the target (`lsusb -v -d <vid>:<pid>`, or the sound devices in the target's OS) or run `kvmd-otgconf` on the PiKVM. It lists each OTG function with `+` (active) or `-` (inactive). A function can exist in configfs and still be inactive, so the `/sys/kernel/config/...` directory alone does not prove anything. The msd toggle does not have this problem, because kvmd itself handles msd.

## Filling in identity values (new install)

The real USB and monitor identity values are deliberately **not** in this repo. Keep them only on the device or in a private store such as a password manager. For a new install:

1. **USB identity**: copy `override.d/0100-identity.yaml` to the device, then edit it **on the device** (`rw` first). The values should belong to a common real HID device such as a wireless keyboard/mouse receiver.
   - `vendor_id`/`product_id`: take them from a device you own (`lsusb` shows `VID:PID`) or from the [USB ID database](http://www.linux-usb.org/usb.ids).
   - `manufacturer`/`product`: the strings that device reports (`lsusb -v -d VID:PID`, `iManufacturer`/`iProduct`).
   - `serial`: something believable and different on each PiKVM.
   - Run `kvmd -M >/dev/null` to validate.
   - The existing values can be read from the mini: `ssh root@pikvm cat /etc/kvmd/override.d/0100-identity.yaml`.
2. **EDID**: get a real monitor's EDID in one of two ways.
   - Dump it yourself. On a Linux machine with that monitor attached, run `cat /sys/class/drm/card*-*/edid > mon.bin`, convert it to hex with `xxd -p mon.bin`, and write the result to `/etc/kvmd/tc358743-edid.hex`.
   - Or copy the mini's file directly: `scp root@pikvm:/etc/kvmd/tc358743-edid.hex root@<newkvm>:/etc/kvmd/`.

   Then run `kvmd-edidconf --apply` (or reboot) and check the result with `kvmd-edidconf`. If needed, `kvmd-edidconf --set-monitor-serial=...` can give each PiKVM its own monitor serial.

## Headscale trust tier: move to `tag:lowtrust`

The mini currently joins as an untagged `josh` node (ID 16), so it is high trust. The plan is to move it to `tag:lowtrust`, like i001. The ACL in `hosts/oracle/o002/headscale.nix` already allows `josh@` to reach `tag:lowtrust:*` and gives `tag:lowtrust` no outbound rule. After the switch, you can still reach the KVM, but the KVM cannot reach any other node.

**Option A: retag in place** (keeps IP `100.64.0.16`):
```sh
ssh o002 'sudo headscale nodes tag -i 16 -t tag:lowtrust'
ssh o002 'sudo headscale nodes list'   # should show user tagged-devices, tag:lowtrust
```

**Option B: re-onboard with a tagged key** (same way as i001/joe):
```sh
ssh o002 'sudo headscale preauthkeys create -u 1 --tags tag:lowtrust -e 1h'
# on the pikvm:
rw
tailscale logout
tailscale up --login-server https://headscale.joshuabell.xyz --auth-key <key> --accept-dns=false --force-reauth
ro
ssh o002 'sudo headscale nodes list'   # delete any leftover untagged "pikvm" node
```
You can also reuse the existing low-trust key from sec, `machines/low-trust/headscale_auth_lowtrust_2026-03-15`.

With either option:
- Following the low-trust convention, set `tailscale set --accept-dns=false`. Low-trust nodes don't use tailnet DNS. The mini currently has `CorpDNS: true`.
- Keep a LAN path or the high-trust SSH session open while switching. If this goes wrong, you would otherwise lose remote access to the KVM.
- Afterwards, check from lio that `ssh root@pikvm` and the web UI still work.
- Isolation check: do **not** use `tailscale ping`. It uses DISCO path probing, which ACLs don't filter, so it can succeed even when tagging is correct. Instead, test a real TCP port on a high-trust node by its numeric IP, for example h001 SSH:
  - From lio, this should succeed (control): `timeout 5 bash -c '</dev/tcp/100.64.0.13/22' && echo open`
  - From the pikvm, the same command should time out and print nothing.
