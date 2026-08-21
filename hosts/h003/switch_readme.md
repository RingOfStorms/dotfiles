# Switch Configuration & Recovery Guide

This document describes the network switches behind **h003** (the router), how to
connect to each, how they are currently configured, and how to re-apply that
configuration from scratch if a switch is factory-reset or replaced.

## TL;DR topology

```
                 Internet
                    │
              enp1s0 (WAN, DHCP from ISP)
                    │
              ┌───────────┐
              │   h003    │  router / DHCP / DNS (dnsmasq)
              │  (NixOS)  │  10.12.16.1 (vlan10)  10.12.14.1 (vlan20)
              └───────────┘
                    │ enp2s0  (802.1Q trunk: VLAN 10 + 20 tagged)
                    │
              Tw1/0/8 (TAGGED 10,20)
              ┌────────────────────────────┐
              │   SG3210X-M2  (Omada L2/L3) │  mgmt 10.12.16.2 (vlan10)
              │   8x 2.5G (Tw) + 2x 10G (Te)│
              └────────────────────────────┘
                Tw1/0/7        Te1/0/10
                (untag 10)     (untag 20)  ── SFP+ ──┐
                laptop/mgmt                          │
                Tw1/0/1-6                            │
                (untag 20, devices)                  │
                                            ┌──────────────────┐
                                            │   SG1428PE       │ flat / VLAN20
                                            │  (Easy Smart PoE)│ (factory reset)
                                            └──────────────────┘
```

## VLAN plan (source of truth: `_constants.nix`)

| VLAN | ID | Purpose          | Subnet          | h003 gateway/DHCP |
|------|----|------------------|-----------------|-------------------|
| management | 10 | infra / switch mgmt | 10.12.16.0/24 | 10.12.16.1 |
| lan        | 20 | normal devices      | 10.12.14.0/24 | 10.12.14.1 |

h003 is router-on-a-stick: `enp2s0` carries VLAN 10 and 20 **tagged**. dnsmasq
serves DHCP/DNS on the tagged `vlan10`/`vlan20` sub-interfaces only. There is **no
DHCP on untagged/native VLAN 1** — a device that ends up on VLAN 1 gets no lease.

Static reservations live in `hosts/h003/_constants.nix` → `network.staticLeases`.

---

## Switch 1 — Omada SG3210X-M2 (core managed switch)

- **Model:** TP-Link Omada SG3210X-M2 (8× 2.5GbE copper `Tw1/0/1-8`, 2× 10G SFP+ `Te1/0/9-10`)
- **Management MAC:** `a8:29:48:e9:b2:ec`
- **Management IP:** `10.12.16.2` (static, on VLAN 10) — reachable from h003 and from any VLAN 10 host
- **Web login:** `admin` / (your password; factory default `admin`)
- **Role:** pure L2 switch. Do **NOT** enable L3 routing or a DHCP server on it — h003 does that.

### How to connect

**Option A — SSH/Web over VLAN 10 (normal, once configured):**
From h003 or any VLAN 10 host, browse `http://10.12.16.2`.
Quick reachability test from h003:
```
ping -I vlan10 10.12.16.2
```

**Option B — Serial console (recovery / when locked out):**
The switch has a **mini-USB console port**. Plug it into h003 (or any Linux box).
It enumerates as a `cdc_acm` device:
```
ls -l /dev/ttyACM0          # "USB-Serial (TP-LINK)"
```

On **h003** the easiest way is the built-in alias (defined in `hosts/h003/flake.nix`):
```
omada
```
This runs `sudo picocom -b 38400 --omap delbs /dev/ttyACM0`. (`picocom` is installed
on h003 by default, so you can also SSH into h003 over Tailscale and run `omada` to
diagnose/recover the switch remotely.)

Equivalent manual command on any box (picocom not pre-installed):
```
sudo $(nix build --no-link --print-out-paths nixpkgs#picocom)/bin/picocom \
     -b 38400 --omap delbs /dev/ttyACM0
```

Serial console notes:
- Baud **38400 8N1** (try `-b 115200` if you see garbage).
- **Backspace fix:** `--omap delbs` translates the DEL (0x7f) your keyboard sends
  into BS (0x08), which the switch expects — otherwise Backspace does nothing.
  Without the flag, use **Ctrl-H** as backspace.
- **Exit picocom:** press **Ctrl-A**, then **Ctrl-X**. (Optionally `exit`/`logout`
  at the switch prompt first to end the switch CLI session cleanly.)

### Current configuration

| Port        | Role                      | VLAN membership     | PVID |
|-------------|---------------------------|---------------------|------|
| `Tw1/0/1-7` | device access ports       | VLAN 20 untagged    | 20   |
| `Tw1/0/8`   | **LAN trunk to h003 (enp2s0)** | VLAN 10 + 20 **tagged** | 1 |
| `Te1/0/9`   | disabled (safety)         | none, `shutdown`    | 1    |
| `Te1/0/10`  | uplink to SG1428PE (SFP+, forced `speed 1000`) | VLAN 20 untagged | 20 |

> **SFP+ link to SG1428PE:** `Te1/0/10` is a **10G SFP+** port but the SG1428PE's
> SFP slots are **1G only**. The link uses a **passive 10G SFP+ DAC** (H!Fiber blue
> twinax) forced to **1 Gbps on the SG3210X side** (`speed 1000`). Without forcing
> the speed the SFP+ port stays at 10G, never links, and there's **no LED/light on
> the SG1428PE SFP port**. If you ever swap the cable/optics, keep `speed 1000` on
> `Te1/0/10` (or use a copper `Tw` port to the SG1428PE, which just works at 1G).

> **Note:** `Tw1/0/8` is the LAN **trunk** to h003 (`enp2s0`), NOT the WAN.
> h003's WAN is a separate physical NIC (`enp1s0`) to the modem.
>
> There is intentionally **no dedicated VLAN 10 (management) access port** — the
> switch is administered via the serial console or via h003 (which reaches
> `10.12.16.2` over tagged `vlan10`). To temporarily get a laptop onto the
> management VLAN, set any access port to `switchport general allowed vlan 10
> untagged` + `switchport pvid 10`, then revert it afterward.

Management interface: `interface vlan 10` → `10.12.16.2/24`, default route `10.12.16.1`.

### Change the admin password

**Web UI:** `System → User Management` → select `admin` → set new password → Apply → save config.

**Console / SSH:**
```
enable
configure
user name admin privilege admin secret 0 <NewStrongPassword>
end
copy running-config startup-config
```
`0` = plaintext entry (stored hashed). If the syntax errors, run `user ?` at the
`(config)#` prompt — some firmware uses `... privilege admin password <pw>`.

### Re-apply from factory reset (serial console CLI)

> ⚠️ **Order matters.** Never remove your live management path (VLAN 1) before the
> new one (VLAN 10) is verified. Doing it on the **console** avoids lockout entirely
> because the console is independent of the switched ports.

```
enable
configure

# 1. Create VLANs
vlan 10
 name management
 exit
vlan 20
 name lan
 exit

# 2. Uplink to h003: tagged trunk for both VLANs
interface two-gigabitEthernet 1/0/8
 switchport general allowed vlan 10 tagged
 switchport general allowed vlan 20 tagged
 exit

# 3. Device access ports (all copper except the trunk): untagged VLAN 20
interface range two-gigabitEthernet 1/0/1-7
 switchport general allowed vlan 20 untagged
 switchport pvid 20
 exit

# 5. SFP+ uplink to SG1428PE: untagged VLAN 20.
#    MUST force speed 1000 — the SG1428PE SFP is 1G, and a 10G SFP+ port
#    won't link to it at 10G (no light on the SG1428PE side otherwise).
interface ten-gigabitEthernet 1/0/10
 switchport general allowed vlan 20 untagged
 switchport pvid 20
 speed 1000
 no shutdown
 exit

# 6. Spare SFP+: off + shut down (safety)
interface ten-gigabitEthernet 1/0/9
 no switchport general allowed vlan 20
 shutdown
 exit

# 7. Management IP on VLAN 10
interface vlan 10
 ip address 10.12.16.2 255.255.255.0
 exit
ip route 0.0.0.0 0.0.0.0 10.12.16.1

end
```

**Verify, then persist:**
```
show vlan 10                 # Tw1/0/8 tagged (trunk only; no untagged mgmt port)
show vlan 20                 # Tw1/0/1-7 + Te1/0/10 untagged, Tw1/0/8 tagged
show interface switchport    # confirm PVIDs (1-7/10 -> 20, trunk 8 -> 1)
show interface status ten-gigabitEthernet 1/0/10   # expect LinkUp / 1000M to SG1428PE
copy running-config startup-config    # <-- REQUIRED or it reverts on reboot
```
From h003: `ping -I vlan10 10.12.16.2` should reply.

**CLI notes**
- Keyword for the 2.5G ports may be `two-gigabitEthernet` / `tw`; SFP+ is
  `ten-gigabitEthernet` / `te`. Use Tab-completion or `interface ?` if a keyword errors.
- `show interface switchport` shows type/PVID only — it does **NOT** show
  tagged/untagged. Use `show vlan <id>` to see `TG` (tagged) vs `UT` (untagged) members.
- Abbreviations work: `conf`, `int tw 1/0/8`, `switchport gen allowed vlan 10 tag`.

---

## Switch 2 — TP-Link SG1428PE (Easy Smart PoE)

- **Model:** TP-Link SG1428PE (Easy Smart, PoE)
- **Management MAC:** `a8:29:48:94:23:dd`
- **Role:** dumb VLAN-20 extender. Factory-reset = 802.1Q VLAN **disabled**, all
  ports one flat untagged domain; it passes every frame untagged.
- **Uplink:** connects to SG3210X `Te1/0/10` (untagged VLAN 20). Everything plugged
  into this switch therefore lands in **VLAN 20** and gets DHCP from h003.

### How to connect

Easy Smart switches have **no serial console**. Management is web-only via the
**Easy Smart Configuration Utility** or the web UI. Default management is
`192.168.0.1` (factory reset may default to DHCP-off/static `192.168.0.1`).

- If DHCP is **enabled** on the switch, it will get a lease on VLAN 20. It's pinned
  to `10.12.14.4` via `staticLeases` (MAC `a8:29:48:94:23:dd`) → browse `http://10.12.14.4`.
- If DHCP is **disabled** (default), reach it at `192.168.0.1`: put a device on a
  VLAN-20 port with a temporary static IP, e.g.
  ```
  sudo ip addr add 192.168.0.50/24 dev <iface>
  ```
  then browse `http://192.168.0.1`, and (recommended) set it to DHCP so the
  `10.12.14.4` reservation takes effect.

### Configuration

No VLAN config needed — leave it factory/flat. It only ever carries VLAN 20.

**Change the admin password:** log in at `192.168.0.1` (or `10.12.14.4` if DHCP is
enabled) → `System → User Account` → set a new password → Apply/Save.

**Cautions**
- Provides **no** VLAN separation of its own; everything on it is VLAN 20.
- **No STP by default** — do NOT run a second cable between the two switches (loop).
- Default web login is `admin`/`admin`. Physical access is required to reach its
  admin panel (it's on the internal LAN only, not exposed to WAN), so the practical
  risk of leaving defaults is limited to someone already on your LAN / with physical
  access. Still worth changing the password when convenient.

---

## Lessons learned (why this doc exists)

1. **Factory switch = flat untagged VLAN 1.** h003 only serves DHCP on tagged
   vlan10/vlan20, so a fresh switch gives no leases until its trunk is configured.
   Bootstrap by giving a laptop a static `192.168.0.x` and browsing the switch's
   default `192.168.0.1`.
2. **Never delete your live management VLAN before the replacement is verified** —
   that's how you get locked out of the web UI (management IP orphaned on a VLAN
   with no member ports). Recover via the **serial console**.
3. The **serial console is lockout-proof** for the SG3210X-M2 — always available
   regardless of VLAN mistakes. The SG1428PE has no console, so recover it via
   `192.168.0.1`.
```
