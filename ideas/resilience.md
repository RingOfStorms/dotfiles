# Infrastructure Resilience & Failover

## Current Fleet Architecture (2026-10)

```
                         INTERNET
                             │
                     ┌───────▼───────┐
                     │     o002      │
                     │ (Oracle ARM)  │
                     │ nginx public  │
                     │ + Headscale   │
                     └───────┬───────┘
                             │ Tailscale Mesh
        ┌────────────────────┼────────────────────┐
        │                    │                    │
┌───────▼───────┐    ┌───────▼───────┐    ┌───────▼───────┐
│     h005      │    │     h001      │    │     h003      │
│   (Router)    │    │ (Primary Svc) │    │ (Warm/2nd Svc)│
│ DHCP, NAT,    │    │ Floating      │◄──►│ Floating      │
│ Split-DNS,    │    │ Containers    │cnt │ Containers    │
│ Wildcard ACME,│    │ + /drives/wd10│move│ (32GB, NVMe)  │
│ fleet-edge    │    └───────┬───────┘    └───────────────┘
└───────────────┘            │ NFS (/nfs/h002/nixarr)
                     ┌───────▼───────┐
                     │     h004      │
                     │ (NAS bcachefs)│
                     │ 5× 12TB rep=2 │
                     └───────────────┘
```

### Resilience Measures Already Deployed
- **Wildcard DNS-01 Certificates (`hosts/h005/wildcard-cert.nix`):** `h005` mints `*.joshuabell.xyz` via Bunny DNS-01 and pushes certs to `h001` and `o002` (`hosts/wildcard-cert-receiver.nix`).
- **UPS Shutdown Coordination (`hosts/ups-shutdown-receiver.nix`):** `h005` monitors the workshop UPS via NUT and triggers clean shutdowns on `h001` and `h004`.
- **NFS Guard (`hosts/h001/floating-containers.nix`):** `guards.h004` watches `/nfs/h002/nixarr/.h004-online` and automatically stops/starts the `arr` container when `h004` goes down or returns.
- **Floating Containers + B2 Restic (`containers/`):** All self-hosted apps (`zitadel`, `sec`, `vaultwarden`, `forgejo`, `immich`, `paperless`, `matrix`, etc.) are encapsulated in `/srv/containers/<svc>` with nightly per-service `svc:<name>` snapshots to Backblaze B2 (`fleet-backup.service`).
- **Identity Break-Glass (`containers/ROUTING-PLAN.md` §9.3):** Cold-restore tested 2026-10-22; `sec` and `zitadel` keys + restic credentials + `root_fleet_backup` SSH key live in the password manager alongside an independent backup copy.

---

## Remaining Gaps & High-Value Improvements

### 1. `o002` (Headscale + Public Edge) Backup & Recovery Gap

`o002` runs both the public nginx edge and the **Headscale control plane** (`hosts/oracle/o002/headscale.nix`), with state in `/persist/var/lib/headscale/db.sqlite`.
- **Impact if `o002` dies:** Existing tailnet peers stay connected briefly via cached keys, but no node can re-authenticate on reboot, no new nodes can join, and all public ingress (`*.joshuabell.xyz`) drops.
- **Current gap:** When the old `flakes/common/nix_modules/backup.nix` rsync module was retired, `o002` lost its automated backup of `/var/lib/headscale`.

#### Fix: Automated Headscale SQLite Backup + Warm Rebuild Path
1. **Back up `/var/lib/headscale` nightly to B2 (or `h001`):**
   - Add a `services.restic.backups.o002` job on `o002` using a `backupPrepareCommand` that runs:
     ```sh
     sqlite3 /var/lib/headscale/db.sqlite ".backup '/var/lib/headscale/db.sqlite.backup'"
     ```
   - Back up `/var/lib/headscale/db.sqlite.backup` and `/var/lib/headscale/noise_private.key` to B2 (tagged `o002-headscale`).
2. **Fast Recovery Procedure (`hosts/oracle/readme.md`):**
   - Oracle Always Free gives room for a second 2 OCPU / 12 GB ARM instance (`hosts/oracle/bootstrap/`).
   - If `o002` fails or needs migration:
     1. Provision new VM from `hosts/oracle/bootstrap` via `nixos-anywhere` (`hosts/oracle/readme.md`).
     2. Restore `/persist/var/lib/headscale/{db.sqlite,noise_private.key}` and `/persist/machine-key.json` from backup.
     3. Start `headscale` and `nginx`, then update the public IP in Bunny DNS (`headscale.joshuabell.xyz` and public vhosts) and `hosts/fleet.nix`.

---

### 2. `h003` as Warm Container Host (`h001` Failover & Maintenance Target)

`h003` (Ryzen 7 5825U, 32 GB RAM, encrypted NVMe bcachefs + impermanence) was re-imaged on 2026-10-15 as a dedicated secondary floating-container host (`hosts/h003/readme.md`) when `h005` took over routing.

Currently `h003` has `inputs.containers.nixosModules.default` enabled (`hosts/h003/containers.nix`), but it is **missing two pieces** to be a turnkey warm target for `cnt move <svc> --to h003` or `cnt restore <svc> --host h003`:

1. **Enable `ringofstorms.containers.backup` on `h003`:**
   - `cnt move` refuses to move a service unless both source and target hosts have `ringofstorms.containers.backup.enable = true` (`ROUTING-PLAN.md` §9.1).
   - Add `restic_h001_env_2026-10-01` to `hosts/h003/sec-agent.nix` with:
     ```nix
     configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";
     ```
   - Set `ringofstorms.containers.backup = { enable = true; schedule = "03:00"; };` in `hosts/h003/containers.nix`.
2. **Receive Wildcard TLS Certs on `h003`:**
   - Import `../wildcard-cert-receiver.nix` in `hosts/h003/flake.nix` and add `"h003"` to `hosts/h005/wildcard-cert.nix` push targets so internal HTTPS container vhosts (`nginx.tls.certDir = "/var/lib/fleet-cert/joshuabell.xyz/current"`) work immediately when a service is moved to `h003`.
   - Set `nginx.acl.lan = [ "10.12.14.0/24" ];` and `nginx.edge.blockInternal = true;` in `hosts/h003/containers.nix` to match `h001/floating-containers.nix`.

Once those two items are in place:
- **Planned maintenance on `h001` (e.g., impermanence re-image):** `cnt move <svc> --to h003` evacuates services cleanly in minutes.
- **Unplanned `h001` hardware failure:** Any non-`wd10` service (`vaultwarden`, `zitadel`, `sec`, `forgejo`, `trilium`, `atuin`, `matrix`, `life`, etc.) can be restored straight from B2 onto `h003` and served immediately once `host = "h003"` is flipped in `containers/<svc>/service.nix` and `h005`/`o002` are updated.

---

### 3. Alerting on Silent Backup / Service Failures

`fleet-edge` on `h005` polls `fleet-agent` (`:9101`) across all hosts and displays service health and stale backup counts (>36h), and Beszel monitors host disk/CPU metrics, but **nothing pushes an alert** when a timer or unit fails:
- Add a lightweight `OnFailure = [ "notify-failure@%n.service" ]` hook or a periodic check on `h005` that alerts when `fleet-edge` detects a down service or a stale backup (>36h).
