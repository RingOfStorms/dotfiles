# h004

Router for my home network (replaces h003 as router)

## Hardware

| Component | Spec |
|---|---|
| Model | MeLE Quieter DL (fanless) |
| CPU | Intel N150 (4C/4T, up to 3.6 GHz) |
| GPU | Intel Graphics (integrated) |
| RAM | 8 GB (soldered, not upgradeable) |
| Storage | 256 GB M.2 2280 NVMe SSD (replaceable) |
| Network | 2× 2.5GbE Intel i226-V |

## Migration plan: h003 → h004

Goal: move all router duties off h003 so h003 can become an agent worker. Keep h003 intact as a rollback until h004 has run cleanly for about a week.

### What moves (from `hosts/h003`)

| Item | Source | Notes |
|---|---|---|
| WAN DHCP, NAT, nftables firewall, VLAN 10/20 trunk | `mods/networking.nix` | Router-on-a-stick: WAN port + one 802.1Q trunk to SG3210X `Tw1/0/8` |
| dnsmasq (LAN DHCP/DNS) + `dnsmasq-tailnet` | `mods/networking.nix` | Static leases in `_constants.nix` |
| AdGuard Home | `mods/adguardhome.nix` | Copy `/var/lib/AdGuardHome` state if wanted (query logs and stats are optional) |
| DDNS (bunny) | `mods/ddns.nix` | Secret `machines/high-trust/bunny_rw_dns_2026-03-15` |
| NUT, 2× APC Back-UPS XS 1500M over USB | `mods/ups.nix` | The Quieter DL has 3 USB-A ports; both UPS cables move over |
| ISP speedtest → Home Assistant | `mods/speedtest.nix` | Secret path is `machines/by-host/h003/...`; needs an h004 copy |
| `omada` serial alias, picocom | `flake.nix` | Optional: needs USB to the switch console |
| nginx squaremap proxy on the overlay IP | `containers.nix` | **Decide:** it fronts Minecraft, which runs on h003. Leave both on h003 (worker) or move both elsewhere. Don't run game servers on the router. |
| Minecraft port forward (TCP 25565) | `containers.nix` → firewall | If Minecraft stays on h003, h004 needs a DNAT to h003's new LAN IP |

### Things that reference h003 elsewhere

- `hosts/fleet.nix`: `h003` entry (`overlayIp 100.64.0.14`, `lanIp 10.12.14.1`). Add `h004`; the router LAN IP `10.12.14.1` moves to h004.
- `hosts/sec-agent.nix`: per-host secret mapping.
- `hosts/h001/mods/sec.nix` and `hosts/h001/mods/homepage-dashboard.nix`: references to h003 (dashboard links, Beszel, etc.).
- `hosts/oracle/o002/headscale.nix` and `hosts/oracle/o002/nginx.nix`: tailnet DNS/routes and the l001 proxy pointing at h003's overlay IP.
- Search again before cutover: `grep -rn 'h003\|100.64.0.14' hosts flakes`.

### Phase 1: prepare config (before hardware arrives)

1. Create `hosts/h004/` from h003: `flake.nix`, `_constants.nix`, `mods/` (networking, adguardhome, ddns, ups, speedtest), `sec-agent.nix`.
   - Do **not** copy `containers.nix` (Minecraft) or the podman module unless you decide to keep the proxy here.
   - `host.name = "h004"`, new `stateVersion`, new hashed password, new Beszel token.
2. Keep the gateway addresses identical (`10.12.16.1`, `10.12.14.1`, `fd12:14:1::1`, `fd12:14:0::1`) so clients and the switch need no changes.
3. Leave `wanInterface` / `trunkInterface` as placeholders until the real names are known (Phase 2).
4. Add secrets for h004 in the secrets manager (bunny DNS token, HA speedtest token) and the `secretsRole`.
5. Add the `h004` entry to `hosts/fleet.nix`. Don't remove h003 yet.
6. **Firewall fix (do it now, not later):** in `mods/networking.nix`, replace the blanket `oifname "${mng.name}" accept` with explicit allows. As written, any new interface (for example a future agent VLAN 30, or tailscale0) can reach management.

### Phase 2: bench setup (h004 not yet in the network path)

1. Boot the NixOS installer and check the BIOS: Auto Power On after AC loss **on**, latest BIOS.
2. Record the real NIC names and MACs: `ip -br link`. Decide which i226 port is WAN and which is the trunk, label them physically, and set them in `_constants.nix`.
3. Partition the NVMe as GPT with EFI + root (`hosts/testbed/disko-config.nix` as a template). Install, generate `hardware-configuration.nix`, and commit.
4. Build on lio and deploy to h004 (8 GB RAM; avoid big builds on the box itself).
5. Join the tailnet. Get h004's overlay IP and update `fleet.nix`.
6. Hydrate secrets and confirm the sec-agent paths exist.
7. Optional: on a spare switch port, give the trunk port a temporary IP to test tagged VLANs without serving DHCP. Keep dnsmasq **stopped** on the bench so there are never two DHCP servers.

### Phase 3: cutover (maintenance window, ~30 min)

1. Before starting: note the ISP modem/ONT's current lease behaviour. If the ISP binds to the WAN MAC, either power-cycle the modem after the swap or set `networking.interfaces.<wan>.macAddress` to h003's WAN MAC.
2. Shut down h003 routing services (or power h003 off).
3. Move cables: modem → h004 WAN; SG3210X `Tw1/0/8` trunk → h004 trunk port.
4. Move both UPS USB cables to h004.
5. Power-cycle the modem if needed. Start h004.

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
- Throughput: a speed test from a LAN client close to the ISP plan (~1.5 Gbps). Check h004 CPU in `htop` during the test.
- Fanless temps under load: `sensors` (the case runs 55–70 °C by design).

### Rollback

Move the WAN, trunk and UPS cables back to h003 and power-cycle the modem. h003's config stays untouched until Phase 5.

### Phase 5: after about a week of stable running

1. Update the other references (`fleet.nix` router IP, o002 headscale/nginx, h001 dashboard, `sec-agent.nix`).
2. Convert h003 to a worker: remove the router mods, plain DHCP client on one port (or a static IP on the future agent VLAN), and decide about Minecraft and squaremap.
3. Update `hosts/h003/readme.md` description ("WAN Local networking computer" → worker).
4. Update `hosts/h003/switch_readme.md` diagrams to name h004 as the router.
