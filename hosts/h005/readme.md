# h005

Router for my home network (replaces h003 as router). Once h005 has taken over, h003 is re-imaged onto
the fleet's encrypted bcachefs + impermanence layout (Phase 6).

> This plan was originally written as `h004`. That name now belongs to the h002 NAS rebuild
> (`hosts/h004/`), so the router is h005.

## Hardware

| Component | Spec |
|---|---|
| Model | MeLE Quieter DL (fanless) |
| CPU | Intel N150 (4C/4T, up to 3.6 GHz) |
| GPU | Intel Graphics (integrated) |
| RAM | 8 GB (soldered, not upgradeable) |
| Storage | 233 GB eMMC `mmc-Y1Y256_0xc15902ff` (`mmcblk0`; shipped with Windows, wiped) |
| Network | 2× 2.5GbE Intel i226-V (`igc`): `enp1s0` = **WAN** (`00:ce:39:d8:0c:17`), `enp2s0` = **TRUNK** (`00:ce:39:d8:0c:18`), labelled on the case |
| Disk layout | ESP 3G (`DA82-16A8`), swap 4G (random key per boot), encrypted bcachefs (`0d6e4079-…`, format 1.39) with impermanence; unlocked by the encrypted USB key stick |

## Bare-metal services

The one host meant to run services on bare metal (networking only).

| Service | Notes |
|---|---|
| dnsmasq (LAN DHCP/DNS), dnsmasq-tailnet | `mods/networking.nix` |
| AdGuard Home | `mods/adguardhome.nix` |
| DDNS (`ddns-update` timer) | `mods/ddns.nix`; `home.joshuabell.xyz` |
| NUT (upsd, upsmon) | `mods/ups.nix` |
| ISP speedtest (timer) | `mods/speedtest.nix` |
| Per-host agents | sec-agent, fail2ban, tailscaled |

Planned (`containers/ROUTING-PLAN.md`): `fleet-edge` (DNS records, ACME,
router forwards, dashboard) and the fleet oauth2-proxy.
## Migration plan: h003 → h005

Goal: move all router duties off h003 so h003 can become an agent worker. Keep h003 intact as a rollback until h005 has run cleanly for about a week.

**Config prepared, not activated:** `_constants.nix` has `network.routerEnable = false`.
The bench configuration runs plain DHCP clients and imports no router modules. The
gate also excludes router-only secrets and state mounts. With it enabled, `mods/`
provides VLAN gateways, DHCP, split DNS, AdGuard, NAT/firewall, DDNS, NUT and
`h005-isp-speedtest`. Keep it **false** until preparing the coordinated cutover.

**Checked 2026-10-15:** bench and router-enabled system closures build. A throwaway
user/network-namespace smoke loaded the generated nftables rules and ran the real
dnsmasq/AdGuard binaries: IPv4/IPv6 WAN round trips and masquerading, cross-VLAN and
unsolicited WAN/tailnet isolation, LAN-vs-tailnet DNS answers, and h004's DHCP
reservation/gateway/DNS options. Removing the early isolation chain reproduced the
ICMPv6 bypass. DNS used the existing `ellawork` client policy because the isolated
network cannot reach AdGuard's external safe-browsing service. No live deploy,
modem/physical VLAN test, USB UPS test, DDNS update or HA publication was performed.

The follow-up IPv6 smoke used real dhcpcd clients with empty lease state and no
manually assigned IPv6 addresses on either VLAN. Before the fix they received RAs
but no DHCPv6 leases or RDNSS DNS. After opening UDP 547 and setting explicit
DHCPv6/RDNSS DNS addresses with matching AdGuard listeners, both acquired addresses,
RA default routes and their VLAN's DNS address; an IPv6 DNS query exercised an
existing AdGuard block rule successfully. Both system closures were rebuilt.
External upstream/filter-service access remains outside this isolated check.

Before the next h005 reboot, seed `/persist/var/lib/dhcpcd` with its existing
`/var/lib/dhcpcd` state (preserve ownership) so adding persistence does not replace
the bench DHCP identity with a newly generated one. Do not seed it from h003.

### What moves (from `hosts/h003`)

| Item | Source | Notes |
|---|---|---|
| WAN DHCP, NAT, nftables firewall, VLAN 10/20 trunk | `mods/networking.nix` | Router-on-a-stick: WAN port + one 802.1Q trunk to SG3210X `Tw1/0/8` |
| dnsmasq (LAN DHCP/DNS) + `dnsmasq-tailnet` | `mods/networking.nix` | Static leases in `_constants.nix` |
| AdGuard Home | `mods/adguardhome.nix` | Same declarative config/login as h003; optional history lives under `/var/lib/private/AdGuardHome/data` |
| DDNS (bunny) | `mods/ddns.nix` | Secret `machines/high-trust/bunny_rw_dns_2026-03-15` |
| NUT, 2× APC Back-UPS XS 1500M over USB | `mods/ups.nix` | Both connected to h005 and reporting mains power (`OL`), verified 2026-10-15; description escaping and `pollinterval` fixes deployed |
| ISP speedtest → Home Assistant | `mods/speedtest.nix` | h005 secret `machines/by-host/h005/hass_isp_speedtest_token` (Zitadel machine user `395294573078773763`); value updated by the user 2026-10-15, hydrated in router mode |
| `omada` serial alias, picocom | h003 `flake.nix` | Optional, not ported; needs USB to the switch console (all 3 USB-A ports are used by the key stick and UPSes) |
| nginx squaremap proxy on the overlay IP | `containers.nix` | **Not moving.** Minecraft is inactive since 2026-10-15 (backup on h001, `containers/minecraft/README.md`), so no squaremap proxy. |
| Minecraft port forward (TCP 25565) | `containers.nix` → firewall | **Not moving** (Minecraft inactive). Add a DNAT on h005 if it is ever brought back. |

### Things that reference h003 elsewhere

- `hosts/fleet.nix`: h005 already exists (`overlayIp 100.64.0.3`, bench `lanIp 10.12.14.183`). At cutover move `lanIp 10.12.14.1` from h003 to h005; keep h003's overlay identity.
- `hosts/_shared_assets/utilities/sec-agent.nix`: per-host secret mapping.
- `containers/sec/registry.nix` (was `hosts/h001/mods/sec.nix`) and `hosts/h001/mods/homepage-dashboard.nix`: references to h003 (dashboard links, Beszel, etc.).
- `hosts/oracle/o002/headscale.nix` and `hosts/oracle/o002/nginx.nix`: tailnet DNS/routes and the l001 proxy pointing at h003's overlay IP.
- Search again before cutover: `grep -rn 'h003\|100.64.0.14' hosts flakes`.

### Phase 1: prepare config (before hardware arrives)

1. ~~Create `hosts/h005/` and port the router modules~~ (done 2026-10-15). No Minecraft, squaremap or podman import. `network.routerEnable = false` gates the complete router stack.
2. ~~Keep the gateway addresses identical~~: `10.12.16.1`, `10.12.14.1`, `fd12:14:1::1`, `fd12:14:0::1`.
3. ~~Record real interfaces~~: WAN `enp1s0`, trunk `enp2s0` (Hardware above).
4. ~~Declare router secrets~~: shared bunny token and h005's HA token, both hydrated only in router mode. h005's HA token value was updated by the user 2026-10-15; live publication is checked after cutover.
5. ~~Register h005 in `hosts/fleet.nix`~~. Keep h003 intact for rollback.
6. ~~Restrict forwarding~~: only VLAN 10/20 may initiate forwarded traffic to WAN. A separate `inet router-isolation` chain runs before the NixOS forward chain, blocking cross-VLAN traffic and other new forwarding, including ICMPv6 (NixOS accepts ICMPv6 before `extraForwardRules`). Established/related WAN replies still pass. No blanket management-interface accept; no tailnet subnet routing or exit-node forwarding enabled.

### Phase 2: bench setup (h005 not yet in the network path)

1. ~~Boot the NixOS installer~~ (done). BIOS: Auto Power On after AC loss **on**, latest BIOS (ADN62D4 V16.1 at install).
2. ~~Record the NIC names and MACs~~ (done, see Hardware; set in `_constants.nix`).
3. ~~Install~~ (done 2026-10-15): disko on the eMMC (`disko_format /dev/disk/by-id/mmc-Y1Y256_0xc15902ff 4G --encrypted`), encrypted USB key stick at format 1.39 (`usb_key.md`), `encrypted = true; usbKey = true; usbKeyPassword` set. First boot unlocked from the stick with no prompt. The stick stays plugged in permanently. `impermanence.nix` now persists dhcpcd identity/leases in both modes; router mode adds dnsmasq leases, `/var/lib/private/AdGuardHome`, Ookla state and root SSH trust. NUT runtime/password files are regenerated, not persisted.
4. ~~Build on lio and deploy~~ (done): `NIX_SSHOPTS="-i /var/lib/secrets_manager_hydrated/nix2nix_2026-03-15" nixos-rebuild switch --flake ./hosts/h005#h005 --target-host root@h005`.
5. ~~Join the tailnet~~ (done): overlay IP `100.64.0.3`, in `fleet.nix` and `_constants.nix`. Beszel agent connected.
6. ~~Hydrate secrets~~ (done): sec-agent logged in as `device_high_trust`; atuin, headscale, nix2nix, git keys present.
7. Leave `network.routerEnable = false` on the bench: no DHCP server, router advertisements, DDNS, UPS shutdown monitor or speedtest timer starts. Do not enable it just to test VLAN tagging on the live trunk.

### Phase 3: cutover (maintenance window, ~30 min)

1. HA token value is set. Before starting, preserve h005's existing DHCP-client state as described above and note the ISP modem/ONT's lease behaviour. If it binds to the WAN MAC, power-cycle it after the swap or deliberately clone h003's WAN MAC. Do not copy h003's SSH/machine/Tailscale identity to h005.
2. Set `network.routerEnable = true` in `_constants.nix`. Build and install for the **next boot only**, while h005 still has bench connectivity. On h005, from the repo root: `nh os boot ./hosts/h005 -H h005`. From lio's repo root instead: `nh os boot ./hosts/h005 -H h005 --target-host root@h005`. Do **not** use `switch`, and do not reboot until h003 is disconnected. Keep console access available.
3. Stop h003's dnsmasq and AdGuard before taking the final state copy. Put the fresh leases in h005 `/persist/var/lib/dnsmasq/`; optionally copy AdGuard's `data/` into `/persist/var/lib/private/AdGuardHome/`. Settings are regenerated from Nix. Then power h003 off so its DDNS/speedtest/NUT and gateway addresses cannot overlap h005's.
4. Move modem → h005 WAN, SG3210X `Tw1/0/8` trunk → h005 trunk, and both UPS USB cables. Leave the encrypted key stick attached. Power-cycle the modem if needed, then reboot h005 into the prepared router generation.
5. **During cutover, not a week later:** change Headscale split DNS from `100.64.0.14` to `100.64.0.3` in `hosts/oracle/o002/headscale.nix` and deploy o002; update the fleet LAN address. Review o002 nginx's h003 targets individually—do not blindly redirect old worker/service proxies to the router. No subnet routes are advertised by this port.

### Phase 4: verify

```sh
ip -br addr                                  # WAN lease, vlan10/vlan20 addresses
nft list ruleset | less                      # NAT + forward rules present
systemctl status dnsmasq dnsmasq-tailnet adguardhome tailscaled
upsc apc1@localhost; upsc apc2@localhost       # both UPSes reporting
journalctl -u ddns-update -n 20              # DDNS updated with the WAN IP
systemctl start h005-isp-speedtest.service
journalctl -u h005-isp-speedtest -n 20
```

UPS monitoring repaired and deployed 2026-10-15: NixOS quoted descriptions without
escaping NUT's `#` syntax, and the inherited `pollinterv` directive was invalid.
`mods/ups.nix` now escapes backslashes, quotes and `#` in descriptions and uses
`pollinterval = 15`. Both drivers started, matched their configured USB serials,
and `upsmon` logged communications established. `apc1` reported 100% charge / 5%
load; `apc2` reported 100% / 9%; both `OL`. Driver parsing was checked in an
isolated namespace before the final deploy. No battery self-test, power-loss,
shutdown or reboot test was performed; those are separate maintenance actions.

- From fresh clients on **both VLANs**: DHCPv4/DHCPv6 address, RA default route, and DNS. IPv6 DNS from DHCPv6 option 23 and RA RDNSS must be `fd12:14::1` on VLAN 20 and `fd12:14:1::1` on VLAN 10; both are AdGuard listeners on port 53. Verify internet and local `*.joshuabell.xyz` records. Static IPv6 assignments alone do not check acquisition or DNS advertisements.
- From a VLAN 10 host: reach the switch at `10.12.16.2`.
- VLAN 20 → VLAN 10 is blocked; VLAN 10 → VLAN 20 is blocked (IPv4 **and** IPv6).
- Tailscale: from a remote device, `dig @100.64.0.3 media.joshuabell.xyz` returns `100.64.0.13`; verify Headscale split DNS uses h005. No tailnet-to-LAN forwarding is provided.
- Port forwards: none needed today (Minecraft inactive).
- Speedtest result arrives in Home Assistant.
- Throughput: a speed test from a LAN client close to the ISP plan (~1.5 Gbps). Check h005 CPU in `htop` during the test.
- Fanless temps under load: `sensors` (the case runs 55–70 °C by design).

### Rollback

Power h005 off before moving WAN, trunk and UPS cables back to h003; power-cycle the modem if needed. Restore Headscale split DNS to `100.64.0.14` and the fleet LAN address to h003. h003's router config stays untouched until Phase 5. Reset h005's gate to false and install a bench generation before reconnecting it alongside h003.

### Phase 5: after about a week of stable running

1. Finish non-critical references (h001 dashboard, old o002 nginx service proxies, descriptions). Fleet gateway metadata and Headscale split DNS must already have moved at cutover.
2. Convert h003 to a worker: remove the router mods, plain DHCP client on one port (or a static IP on the future agent VLAN). Minecraft and squaremap stay off.
3. Update `hosts/h003/readme.md` description ("WAN Local networking computer" → worker).
4. Update the diagrams in `hosts/h005/switch_readme.md` (moved from h003) to name h005 as the router.

### Phase 6: re-image h003 onto encrypted bcachefs + USB key

Today h003 is LUKS + btrfs with a keyfile copied into the initrd (`hosts/h003/hardware-configuration.nix`: `boot.initrd.secrets` → `cryptroot.keyFile`). It unlocks itself, and the key sits on the unencrypted `/boot`, so the encryption protects nothing if the machine is stolen. It also has no impermanence. Once it is a worker, rebuild it like joe/i001.

1. **Only after Phase 5**, with h005 routing on its own for at least a week and h003 no longer in the network path.
2. ~~Inventory h003 state~~ (done 2026-10-15). Running: adguardhome, dnsmasq, dnsmasq-tailnet, dhcpcd, beszel-agent, fail2ban, NUT, timers ddns-update / h003-isp-speedtest / podman-prune. Everything else is rebuilt from config. What has real state:

   | Path on h003 | What | Needed where |
   |---|---|---|
   | `/srv/containers/minecraft` (5.4G) | Minecraft (inactive since 2026-10-15) | archive only |
   | `/var/lib/dnsmasq/dnsmasq.leases` (25 leases) | dynamic DHCP leases | h005 at cutover (copy fresh) |
   | `/var/lib/private/AdGuardHome` (3.1G) | settings are declarative (`mutableSettings = false`); state is `data/stats.db`, `sessions.db`, `querylog.json*` (3.1G, 90d) | h005 at cutover: `stats.db` + `sessions.db`; query log optional |
   | `/etc/ssh/ssh_host_*`, `/machine-key.json`, `/etc/machine-id`, `/var/lib/tailscale`, `/var/lib/private/beszel-agent/fingerprint` | h003 identity | the re-imaged h003, if it keeps its identity |
   | `/home/luser` (5.9G) | shell history, opencode config/sessions (`auth.json` holds credentials), `~/.config/nixos-config.bak` (3 local commits never pushed, 2025), old Minecraft archives `mc-pre-migration-2026-10-09.tar.gz` + `minecraft-survival-2026-04-17.tar.gz`, `~/stuff/AdGuardHome.yaml` (2025 config) | archive only |

   Not worth keeping: podman (no containers or volumes), `/var/lib/fail2ban`, `/var/lib/nut` (pid only), `/var/lib/secrets_manager_hydrated` (re-fetched), `/root/.cache`.
3. ~~Floating containers~~: only Minecraft, now inactive (`containers/minecraft/README.md`).
4. ~~Back up~~ (done 2026-10-15) to h001 `/home/luser/backups/` (mode 0600). Both passed zstd integrity checks. Minecraft had 6860 archive/source entries; the state archive had 6169 entries, including 6103 home entries matching the source count. Key identity/world paths were listed; this was **not** a byte-for-byte comparison or test restore. Test-restore selected files before re-imaging.
   - `minecraft-h003-2026-10-15T2001.tar.zst` (4.0G, `containers backup`, 6860 entries).
   - `h003-state-2026-10-15.tar.zst` (5.3G): all the paths in the table except the Minecraft container, plus `/root/.zsh_history` and `/root/.ssh`; excludes `~/.cache`, `~/.npm`, opencode `node_modules`. Restore one path with `zstd -dc … | tar -xpf - --numeric-owner -C <dir> <path>`.
   The router state (leases, AdGuard) changes daily: copy it again straight from h003 to h005 in the cutover window.
5. Identity files are in the state backup (step 4). Restoring them on the re-imaged h003 keeps the fleet, nix2nix SSH and the tailnet node unchanged; skip them for a completely fresh identity (then delete the old `h003` node in headscale and re-add it in Beszel).
6. Prepare the config: add `impermanence_mod` and `boot_systemd` to `hosts/h003/flake.nix`; drop the LUKS/btrfs entries and `boot.initrd.secrets` from `hardware-configuration.nix`; add `hosts/h003/impermanence.nix` (shared sets + `/var/lib/secrets_manager_hydrated` + the worker state from step 2). Check that it builds (`nixos-rebuild build --flake hosts/h003#h003`).
7. Make a USB key stick for h003 (`usb_key.md`). It stays plugged in if h003 must reboot unattended.
8. Boot the installer and run disko (`encrypted = true`, target `/dev/disk/by-id/nvme-…`). Record the UUIDs in `ringofstorms.impermanence.disk` with `usbKey = true`. Copy the step 5 files into `/mnt/persist` (SSH keys in `/mnt/persist/etc/ssh/`), then `nixos-install --flake`.
9. Verify: unlocks from the USB key with no prompt; `/` is wiped on reboot while `/persist` keeps its contents; tailnet node and SSH host key unchanged; restore the step 2 state and start the workloads again.
10. Update `hosts/h003/readme.md` (disk layout table like `hosts/i001/readme.md`) and the host roles in `containers/ROUTING-PLAN.md`.
