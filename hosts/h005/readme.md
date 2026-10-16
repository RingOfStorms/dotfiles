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

## Migration plan: h003 → h005

Goal: move all router duties off h003 so h003 can become an agent worker. Keep h003 intact as a rollback until h005 has run cleanly for about a week.

### What moves (from `hosts/h003`)

| Item | Source | Notes |
|---|---|---|
| WAN DHCP, NAT, nftables firewall, VLAN 10/20 trunk | `mods/networking.nix` | Router-on-a-stick: WAN port + one 802.1Q trunk to SG3210X `Tw1/0/8` |
| dnsmasq (LAN DHCP/DNS) + `dnsmasq-tailnet` | `mods/networking.nix` | Static leases in `_constants.nix` |
| AdGuard Home | `mods/adguardhome.nix` | Copy `/var/lib/AdGuardHome` state if wanted (query logs and stats are optional) |
| DDNS (bunny) | `mods/ddns.nix` | Secret `machines/high-trust/bunny_rw_dns_2026-03-15` |
| NUT, 2× APC Back-UPS XS 1500M over USB | `mods/ups.nix` | The Quieter DL has 3 USB-A ports; both UPS cables move over |
| ISP speedtest → Home Assistant | `mods/speedtest.nix` | Secret path is `machines/by-host/h003/...`; needs an h005 copy |
| `omada` serial alias, picocom | `flake.nix` | Optional: needs USB to the switch console |
| nginx squaremap proxy on the overlay IP | `containers.nix` | **Decide:** it fronts Minecraft, which runs on h003. Leave both on h003 (worker) or move both elsewhere. Don't run game servers on the router. |
| Minecraft port forward (TCP 25565) | `containers.nix` → firewall | If Minecraft stays on h003, h005 needs a DNAT to h003's new LAN IP |

### Things that reference h003 elsewhere

- `hosts/fleet.nix`: `h003` entry (`overlayIp 100.64.0.14`, `lanIp 10.12.14.1`). Add `h005`; the router LAN IP `10.12.14.1` moves to h005.
- `hosts/sec-agent.nix`: per-host secret mapping.
- `hosts/h001/mods/sec.nix` and `hosts/h001/mods/homepage-dashboard.nix`: references to h003 (dashboard links, Beszel, etc.).
- `hosts/oracle/o002/headscale.nix` and `hosts/oracle/o002/nginx.nix`: tailnet DNS/routes and the l001 proxy pointing at h003's overlay IP.
- Search again before cutover: `grep -rn 'h003\|100.64.0.14' hosts flakes`.

### Phase 1: prepare config (before hardware arrives)

1. Create `hosts/h005/` from h003: `flake.nix`, `_constants.nix`, `mods/` (networking, adguardhome, ddns, ups, speedtest), `sec-agent.nix`.
   - Do **not** copy `containers.nix` (Minecraft) or the podman module unless you decide to keep the proxy here.
   - `host.name = "h005"`, new `stateVersion`, new hashed password, new Beszel token.
2. Keep the gateway addresses identical (`10.12.16.1`, `10.12.14.1`, `fd12:14:1::1`, `fd12:14:0::1`) so clients and the switch need no changes.
3. Leave `wanInterface` / `trunkInterface` as placeholders until the real names are known (Phase 2).
4. Add secrets for h005 in the secrets manager (bunny DNS token, HA speedtest token) and the `secretsRole`.
5. Add the `h005` entry to `hosts/fleet.nix`. Don't remove h003 yet.
6. **Firewall fix (do it now, not later):** in `mods/networking.nix`, replace the blanket `oifname "${mng.name}" accept` with explicit allows. As written, any new interface (for example a future agent VLAN 30, or tailscale0) can reach management.

### Phase 2: bench setup (h005 not yet in the network path)

1. ~~Boot the NixOS installer~~ (done). BIOS: Auto Power On after AC loss **on**, latest BIOS (ADN62D4 V16.1 at install).
2. ~~Record the NIC names and MACs~~ (done, see Hardware; set in `_constants.nix`).
3. ~~Install~~ (done 2026-10-15): disko on the eMMC (`disko_format /dev/disk/by-id/mmc-Y1Y256_0xc15902ff 4G --encrypted`), encrypted USB key stick at format 1.39 (`usb_key.md`), `encrypted = true; usbKey = true; usbKeyPassword` set. First boot unlocked from the stick with no prompt. The stick stays plugged in permanently. Router state (`/var/lib/AdGuardHome`, dnsmasq leases, `/var/lib/nut` if used) still has to be added to `impermanence.nix` with the router mods.
4. ~~Build on lio and deploy~~ (done): `NIX_SSHOPTS="-i /var/lib/secrets_manager_hydrated/nix2nix_2026-03-15" nixos-rebuild switch --flake ./hosts/h005#h005 --target-host root@h005`.
5. ~~Join the tailnet~~ (done): overlay IP `100.64.0.3`, in `fleet.nix` and `_constants.nix`. Beszel agent connected.
6. ~~Hydrate secrets~~ (done): sec-agent logged in as `device_high_trust`; atuin, headscale, nix2nix, git keys present.
7. Optional: on a spare switch port, give the trunk port a temporary IP to test tagged VLANs without serving DHCP. Keep dnsmasq **stopped** on the bench so there are never two DHCP servers.

### Phase 3: cutover (maintenance window, ~30 min)

1. Before starting: note the ISP modem/ONT's current lease behaviour. If the ISP binds to the WAN MAC, either power-cycle the modem after the swap or set `networking.interfaces.<wan>.macAddress` to h003's WAN MAC.
2. Shut down h003 routing services (or power h003 off).
3. Move cables: modem → h005 WAN; SG3210X `Tw1/0/8` trunk → h005 trunk port.
4. Move both UPS USB cables to h005.
5. Power-cycle the modem if needed. Start h005.

### Phase 4: verify

```sh
ip -br addr                                  # WAN lease, vlan10/vlan20 addresses
nft list ruleset | less                      # NAT + forward rules present
systemctl status dnsmasq dnsmasq-tailnet adguardhome tailscaled
upsc <ups1>@localhost; upsc <ups2>@localhost # both UPSes reporting
journalctl -u ddns-update -n 20              # DDNS updated with the WAN IP
```

- From a VLAN 20 client: DHCP lease, DNS (including `*.joshuabell.xyz` local records), internet, IPv6 if enabled.
- From a VLAN 10 host: reach the switch at `10.12.16.2`. Check that `omada` works if the console cable moved.
- VLAN 20 → VLAN 10 is blocked; VLAN 10 → VLAN 20 is blocked (IPv4 **and** IPv6).
- Tailscale: tailnet DNS and subnet routes work from a remote device.
- Port forwards (Minecraft, if kept) reachable from outside.
- Speedtest result arrives in Home Assistant.
- Throughput: a speed test from a LAN client close to the ISP plan (~1.5 Gbps). Check h005 CPU in `htop` during the test.
- Fanless temps under load: `sensors` (the case runs 55–70 °C by design).

### Rollback

Move the WAN, trunk and UPS cables back to h003 and power-cycle the modem. h003's config stays untouched until Phase 5.

### Phase 5: after about a week of stable running

1. Update the other references (`fleet.nix` router IP, o002 headscale/nginx, h001 dashboard, `sec-agent.nix`).
2. Convert h003 to a worker: remove the router mods, plain DHCP client on one port (or a static IP on the future agent VLAN), and decide about Minecraft and squaremap.
3. Update `hosts/h003/readme.md` description ("WAN Local networking computer" → worker).
4. Update `hosts/h003/switch_readme.md` diagrams to name h005 as the router.

### Phase 6: re-image h003 onto encrypted bcachefs + USB key

Today h003 is LUKS + btrfs with a keyfile copied into the initrd (`hosts/h003/hardware-configuration.nix`: `boot.initrd.secrets` → `cryptroot.keyFile`). It unlocks itself, and the key sits on the unencrypted `/boot`, so the encryption protects nothing if the machine is stolen. It also has no impermanence. Once it is a worker, rebuild it like joe/i001.

1. **Only after Phase 5**, with h005 routing on its own for at least a week and h003 no longer in the network path.
2. Inventory h003 state to keep: Minecraft world + squaremap data, floating containers under `/srv/containers`, podman volumes, anything in `/var/lib` not rebuilt from config. Compare against `hosts/h003/*.nix`.
3. Move floating containers off first (`containers move <svc> --to <host>`), or back them up with the rest.
4. Copy the remaining state to the NAS (`/data/backups/h003/`), then **test-restore a few files**.
5. Save the identity: `/etc/ssh/ssh_host_*`, `/machine-key.json` (if present), `/etc/machine-id`, `/var/lib/tailscale`. These keep the fleet, nix2nix SSH and the tailnet node unchanged.
6. Prepare the config: add `impermanence_mod` and `boot_systemd` to `hosts/h003/flake.nix`; drop the LUKS/btrfs entries and `boot.initrd.secrets` from `hardware-configuration.nix`; add `hosts/h003/impermanence.nix` (shared sets + `/var/lib/secrets_manager_hydrated` + the worker state from step 2). Check that it builds (`nixos-rebuild build --flake hosts/h003#h003`).
7. Make a USB key stick for h003 (`usb_key.md`). It stays plugged in if h003 must reboot unattended.
8. Boot the installer and run disko (`encrypted = true`, target `/dev/disk/by-id/nvme-…`). Record the UUIDs in `ringofstorms.impermanence.disk` with `usbKey = true`. Copy the step 5 files into `/mnt/persist` (SSH keys in `/mnt/persist/etc/ssh/`), then `nixos-install --flake`.
9. Verify: unlocks from the USB key with no prompt; `/` is wiped on reboot while `/persist` keeps its contents; tailnet node and SSH host key unchanged; restore the step 2 state and start the workloads again.
10. Update `hosts/h003/readme.md` (disk layout table like `hosts/i001/readme.md`) and the host table in `containers/MIGRATION-PLAN.md`.
