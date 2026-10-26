# fleetkvm — PiKVM V4 Plus (self-hosted rack)

A stock PiKVM with Tailscale (headscale). Unlike `pikvm` (see `pikvm_v4mini.md`), it has **no** USB or monitor identity emulation and no `kvmctl`. Status: flashing the latest firmware. Not yet set up.

## Setup steps

1. Flash the latest V4 Plus image and follow the official first-boot guide.
2. Change the passwords for the web UI, IPMI and root:
   ```sh
   rw
   kvmd-htpasswd set admin
   passwd root
   ```
   Optionally turn on 2FA with `kvmd-totp init`.
3. Hostname: `hostnamectl hostname fleetkvm` (still in `rw` from step 2).
4. SSH, still in `rw`: add a key to `/root/.ssh/authorized_keys`. Optionally set `PasswordAuthentication no` in `/etc/ssh/sshd_config` and run `systemctl restart sshd`. Then run `ro`.
5. Tailscale (PiKVM guide), joined to headscale as **low trust** (see "Headscale trust tier" below):
   ```sh
   rw
   pacman -S tailscale-pikvm
   systemctl enable --now tailscaled
   tailscale up --login-server https://headscale.joshuabell.xyz --auth-key <lowtrust-key> --hostname fleetkvm --accept-dns=false
   ro
   ```
   Then approve the node in headscale. Copy `hosts/pikvm/fleetkvm_v4plus/tailscaled` to `/etc/default/tailscaled` (between `rw` and `ro`) to get `--no-logs-no-support` like the mini, then run `systemctl restart tailscaled`.

## ConnectPRO KVM integration

### Cabling & ports (`fleetkvm` ↔ ConnectPRO)

1. **Serial RS-232 Control (Primary switching path)**
   - **PiKVM V4 Plus side:** Rear **USB 3.0 port 2** — the blue USB-A port **directly above the RJ45 ATX port** (or front USB 3.0 port 1). Appears as `/dev/ttyUSB0`.
   - **ConnectPRO side:** Rear **Serial/Control** RJ45 port (next to the 5V DC barrel jack).
   - **Cable:** USB-to-RJ45 RS-232 console cable (`FT232RL` Cisco-pinout cable) or `CRJ45-DB9F` + USB-to-RS232 adapter.
   - **Serial protocol (verified on hardware):** `115200` baud, `8N1`, no flow control. Port switching frames are `CH1\r\n` (`43 48 31 0d 0a`) through `CH4\r\n` (`43 48 34 0d 0a`).
   - To sniff serial frames from the ConnectPRO front panel at any time, run `connectpro-switch sniff 115200`.

2. **USB Keyboard / Mouse / Virtual Media (`fleetkvm` → ConnectPRO)**
   - **PiKVM V4 Plus side:** Rear **USB 2.0 OTG** port (USB-C, between the ATX port and HDMI input).
   - **ConnectPRO side:** Rear **USB 1** or **USB 2** shared USB 3.0 hub port (to the left of the dashed `DDM` section).
   - *Why the DDM ports rejected PiKVM earlier:* By default on a fresh install, PiKVM presents a composite USB device that includes **Virtual Mass Storage (`msd`) + 2 mice (`absolute` + `relative`) + keyboard**. ConnectPRO's DDM microcontroller strictly rejects any USB composite device with a Mass Storage interface or absolute tablet descriptor. Using the normal **USB 1 / USB 2** hub slot bypasses DDM completely, so keyboard, mouse (including absolute mouse), and virtual media work without stripping down PiKVM's USB gadget.
   - *Make sure the USB hub follows the active port:* By default on ConnectPRO, the shared USB 3.0 hub ports switch together with the selected KVM port (`H → 0 → P → 0`).

3. **Console Video (`ConnectPRO` → `fleetkvm`)**
   - **ConnectPRO side:** Rear **Console DisplayPort** output.
   - **PiKVM side:** Rear **HDMI video input** port.
   - **Adapter:** Requires an **Active** DisplayPort 1.4-to-HDMI 2.0 converter (ConnectPRO console DP ports do not support passive `DP++` cables). Power on `fleetkvm` first, attach the active converter + HDMI cable to the ConnectPRO console port, then cold-boot (or press the front `Reset` pinhole on) the ConnectPRO so it caches the PiKVM's EDID.

### Installing the top-bar UI buttons & active-port LEDs (`hosts/pikvm/fleetkvm_v4plus/`)

- `connectpro.py` (`/usr/lib/python3.*/site-packages/kvmd/plugins/ugpio/connectpro.py`): Native KVMD `ugpio` driver that keeps `/dev/ttyUSB0` open at `115200` 8N1, sends `CH1\r\n`..`CH4\r\n` when a button is clicked, and listens for `CH1\r\n`..`CH4\r\n` broadcasts if someone presses the physical buttons on the ConnectPRO front panel — lighting up the active machine's green LED indicator in the Web UI.
- `web.css` (`/etc/kvmd/web.css`, served as `/share/css/user.css`): Flattens the GPIO menu directly into the 50px top navigation bar so all 4 hosts (`1: h001`, `2: h005`, `3: h003`, `4: h004`) are 1-click buttons in the top bar without opening a dropdown.
- `override.d/0300-connectpro.yaml` (`/etc/kvmd/override.d/0300-connectpro.yaml`): Wires the 4 input LEDs and 4 output buttons for `1: h001`, `2: h005`, `3: h003`, `4: h004`.

From this repo on your workstation, copy the files to `fleetkvm` and activate them:

```sh
scp hosts/pikvm/fleetkvm_v4plus/connectpro.py \
    hosts/pikvm/fleetkvm_v4plus/web.css \
    hosts/pikvm/fleetkvm_v4plus/connectpro-switch \
    hosts/pikvm/fleetkvm_v4plus/connectpro.conf \
    hosts/pikvm/fleetkvm_v4plus/override.d/0300-connectpro.yaml \
    root@fleetkvm:/tmp/

ssh root@fleetkvm '
  set -euo pipefail
  rw
  trap ro EXIT
  mkdir -p /etc/kvmd/override.d /usr/local/bin
  PY_UGPIO_DIR="$(python3 -c "import os, kvmd.plugins.ugpio as u; print(os.path.dirname(u.__file__))")"
  install -m 0644 /tmp/connectpro.py "${PY_UGPIO_DIR}/connectpro.py"
  python3 -m py_compile "${PY_UGPIO_DIR}/connectpro.py"
  install -m 0644 /tmp/web.css /etc/kvmd/web.css
  install -m 0755 /tmp/connectpro-switch /usr/local/bin/connectpro-switch
  install -m 0644 /tmp/connectpro.conf /etc/kvmd/connectpro.conf
  install -m 0644 /tmp/0300-connectpro.yaml /etc/kvmd/override.d/0300-connectpro.yaml
  rm -f /tmp/connectpro.py /tmp/web.css /tmp/connectpro-switch /tmp/connectpro.conf /tmp/0300-connectpro.yaml
  kvmd -M >/dev/null
  systemctl restart kvmd
'
```

*(Note: After running `pikvm-update` in the future, if Python is upgraded to a new minor version, re-copy `connectpro.py` into `${PY_UGPIO_DIR}`.)*

## V4 Plus differences to remember

- Platform package `kvmd-platform-v4plus-hdmi-rpi4`. It has a CM4 and is aarch64-capable.
- Extra hardware (ATX, serial, USB hub, etc.) is not on the mini. Configure only what the rack needs through `override.d/`.

## Maintenance

Run `pikvm-update`, reboot, and check that `fleetkvm` is online in headscale (`tailscale status`).

## Headscale trust tier

fleetkvm joins as **`tag:lowtrust`** from the start. You can reach it from high-trust nodes, but it cannot reach any other node. Use this in place of the plain `tailscale up` in step 5:
```sh
ssh o002 'sudo headscale preauthkeys create -u 1 --tags tag:lowtrust -e 1h'
# on fleetkvm (rw):
tailscale up --login-server https://headscale.joshuabell.xyz --auth-key <key> --hostname fleetkvm --accept-dns=false
```
The existing sec key `machines/low-trust/headscale_auth_lowtrust_2026-03-15` also works. `headscale nodes list` should show `tagged-devices` and `tag:lowtrust`. For the isolation check (a TCP test, not `tailscale ping`), see the same section in `pikvm_v4mini.md` for background and checks.
