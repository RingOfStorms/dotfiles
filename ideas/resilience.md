# Infrastructure Resilience & Failover

## Fleet Architecture (backup model updated 2026-11-13)

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
│ Wildcard ACME,│    │ + /srv/bulk   │move│ (32GB, NVMe)  │
│ fleet-edge    │    └───────┬───────┘    └───────────────┘
└───────────────┘            │ NFS (/nfs/h002/nixarr)
                     ┌───────▼───────┐
                     │     h004      │
                     │ (NAS bcachefs)│
                     │ 5× 12TB rep=2 │
                     └───────────────┘
```

### Resilience Measures Already Deployed
- **Wildcard DNS-01 Certificates (`hosts/h005/wildcard-cert.nix`):** `h005` mints `*.joshuabell.xyz` via Bunny DNS-01 and pushes certs to `h001`, `h003`, `joe`, `lio` and `o002` (`hosts/_shared_assets/utilities/wildcard-cert-receiver.nix`).
- **UPS Shutdown Coordination (`hosts/_shared_assets/utilities/ups-shutdown-receiver.nix`):** `h005` monitors the workshop UPS via NUT and triggers clean shutdowns on `h001` and `h004`.
- **NFS Guard (`hosts/h001/floating-containers.nix`):** `guards.h004` watches `/nfs/h002/nixarr/.h004-online` and automatically stops/starts the `arr` container when `h004` goes down or returns.
- **Floating Containers + Per-Subject Restic (`containers/`):** Service roots live under `/srv/containers/<svc>`; declared bulk paths such as Immich/Paperless media live under `/srv/bulk`. Enabled subjects write nightly `svc:<name>` snapshots to separate h004 repositories; h004 alone holds the B2 pusher key and copies offsite-enabled subjects. There is no shared client B2 key or repository. Coverage and completion are separate: see [Nightly restic](../containers/README.md#nightly-restic-fleet-backup) and the [dated inventory](../containers/INVENTORY.md).
- **Identity Break-Glass:** Preserve independent Sec/Zitadel application keys, machine/SSH recovery material, the pusher B2 credentials and the latest fleet-edge subject-password export outside the fleet. A historical cold-restore report is not proof that today's complete recovery kit is available; follow [B2-only recovery](../containers/README.md#b2-only-recovery-independent-of-h005h004).

---

## Remaining Gaps & High-Value Improvements

### 1. `o002` (Headscale + Public Edge) Backup & Recovery Gap

`o002` runs both the public nginx edge and the **Headscale control plane** (`hosts/oracle/o002/headscale.nix`), with state in `/persist/var/lib/headscale/db.sqlite`.
- **Impact if `o002` dies:** Existing tailnet peers stay connected briefly via cached keys, but no node can re-authenticate on reboot, no new nodes can join, and all public ingress (`*.joshuabell.xyz`) drops.
- **Current gap:** When the old `flakes/common/nix_modules/backup.nix` rsync module was retired, `o002` lost its automated backup of `/var/lib/headscale`.

#### Fix: Automated Headscale SQLite Backup + Warm Rebuild Path
1. **Declare an off-host Headscale backup subject:**
   - Use `ringofstorms.backup.subjects` and register its host ownership in h005's `backup.hostSubjects`, following [Subject declarations and consistent data](../containers/README.md#subject-declarations-and-consistent-data).
   - A pre-hook should take a SQLite online copy of `/var/lib/headscale/db.sqlite`; include that copy and `/var/lib/headscale/noise_private.key`, excluding the live DB and its WAL/SHM. Keep host identity recovery material separately available.
   - Use per-subject credentials from fleet-edge and a runtime target/offsite policy; no legacy shared secret or direct client B2 key is needed. Verify offsite completion and an independent restore before claiming recovery coverage.
2. **Fast Recovery Procedure (`hosts/oracle/readme.md`):**
   - Oracle Always Free gives room for a second 2 OCPU / 12 GB ARM instance (`hosts/oracle/bootstrap/`).
   - If `o002` fails or needs migration:
     1. Provision new VM from `hosts/oracle/bootstrap` via `nixos-anywhere` (`hosts/oracle/readme.md`).
     2. Restore `/persist/var/lib/headscale/{db.sqlite,noise_private.key}` and `/persist/machine-key.json` from backup.
     3. Start `headscale` and `nginx`, then update the public IP in Bunny DNS (`headscale.joshuabell.xyz` and public vhosts) and `hosts/fleet.nix`.

---

### 2. `h003` as Warm Container Host (`h001` Failover & Maintenance Target)

`h003` (Ryzen 7 5825U, 32 GB RAM, encrypted NVMe bcachefs + impermanence) was re-imaged on 2026-10-15 as a dedicated secondary floating-container host (`hosts/h003/readme.md`) when `h005` took over routing.

`h003` already has the floating-container host module, private networking,
nightly backup client, `bulk` capability and persistent `/srv/bulk` configured
in `hosts/h003/containers.nix`. The host module receives h005's wildcard
certificate. Before a planned evacuation, verify the deployed target rather
than reintroducing retired shared credentials:

1. **Target readiness:** Check idmapped mounts, private networking, certificate
   delivery, required hydrated service secrets and free space for both
   `/srv/containers` and declared `/srv/bulk` extra paths. h003's bulk directory
   shares its root NVMe; it is not h001's separate media disk.
2. **Backup-backed moves:** Both hosts need the client enabled; the service
   must have backups enabled and a runtime target other than `none`. Its
   reserved destination must freshly fetch per-subject credentials from
   fleet-edge using the host's machine identity. No shared B2 environment
   file belongs on h003. Follow [Moving a service](../containers/README.md#moving-a-service-to-another-host).
3. **Capabilities and disposable services:** h003 offers `bulk`, but not
   `nfs-h004` or `intel-qsv`; do not assume arr can run there. `litellm`,
   `llm-router`, `searx`, `hello-nixos` and `hello-podman` disable backups:
   redeploy/re-authenticate their disposable state, or deliberately enable
   backups before a state-preserving move.

- **Planned h001 maintenance:** `cnt move <svc> --to h003` preserves enabled
  service state, including declared local bulk paths. Bulk pre-sync can be
  substantial. Placement and routing change at runtime; never add a `host`
  field to `service.nix` or rebuild h005/o002 just to move a service.
- **Unplanned h001 failure:** Recover only subjects with verified usable
  snapshots. Use the [B2-only recovery runbook](../containers/README.md#b2-only-recovery-independent-of-h005h004)
  if h004 is unavailable; recover SQLite online copies and import PostgreSQL
  dumps before starting applications. `cnt move` needs the surviving source
  for raw PostgreSQL clusters and is not a cold-recovery proof. Recover
  declared bulk paths too, then deploy and intentionally update the runtime
  placement binding (`cnt place`); routing follows it. Do not promise an
  immediate service restart from a placement edit alone.

---

### 3. Alerting on Silent Backup / Service Failures

`fleet-edge` on h005 already minute-polls placed-service health, missing/stale
backup stamps and certificate expiry with deduplicated alerts. Push delivery
is not configured (`alerts.ntfyUrl` is empty); generic host subjects and pusher
completeness are not covered by those age checks. Configure a push destination
and an independent backup/pusher or dead-man monitor before treating the
dashboard as an active notification guarantee.
