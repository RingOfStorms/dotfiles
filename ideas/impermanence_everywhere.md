# Impermanence Rollout Strategy (Remaining: `h001` & `lio`)

## Current Fleet State

Impermanence (`flakes/impermanence`, `ringofstorms.impermanence` on bcachefs with `@root`, `@nix`, `@persist`, `@snapshots`) is deployed on **9 of 11** active NixOS hosts:

| Host | Role | Impermanence | Notes |
|---|---|---|---|
| `juni` | Laptop | ✅ Implemented | Encrypted bcachefs |
| `oren` | Laptop | ✅ Implemented | Encrypted bcachefs |
| `gp3` | Laptop | ✅ Implemented | Encrypted bcachefs |
| `joe` | Workstation | ✅ Implemented | Encrypted bcachefs |
| `i001` | Workstation | ✅ Implemented | Encrypted bcachefs |
| `h003` | Container Host | ✅ Implemented | Encrypted bcachefs + USB key unlock (`hosts/h003/impermanence.nix`) |
| `h004` | NAS | ✅ Implemented | Encrypted NVMe root + USB key unlock; `/data` bcachefs pool separate (`hosts/h004/impermanence.nix`) |
| `h005` | Router / Edge | ✅ Implemented | Encrypted bcachefs + USB key unlock (`hosts/h005/impermanence.nix`) |
| `o002` | Cloud Gateway | ✅ Implemented | Unencrypted bcachefs via `nixos-anywhere` + `disko` (`hosts/oracle/o002/impermanence.nix`) |
| **`h001`** | **Primary Server** | ❌ **Pending** | All apps already moved to floating containers (`/srv/containers/*`); root is still legacy ext4 |
| **`lio`** | **Daily Workhorse** | ❌ **Pending** | Primary desktop (`1.8 TB` root NVMe + `/mnt/nvme1tb`) |

---

## Plan for `h001` (Evacuate to `h003` → Re-image → Move Back)

Stateful services use `/srv/containers/<svc>` and declared bulk extra paths
under `/srv/bulk`. On h001, `/srv/bulk` is the separate WD disk (formerly
`/drives/wd10`); on h003 it is persistent storage on the root NVMe. A root
re-image still needs a separate audit of host identity, `/home/luser/backups`,
retired roots and other non-container data in the [dated inventory](../containers/INVENTORY.md).
Preserve personal media/archives; a current service snapshot is not permission
to delete historical data.

### Step 0: Verify `h003` Readiness (see `ideas/resilience.md` §2)
1. h003 already configures private networking, the nightly backup client,
   wildcard-cert reception and the `bulk` capability. Verify deployed units,
   idmapped mounts, certs and hydrated service secrets before evacuation.
2. Verify source and destination clients, each selected service's enabled
   backups and runtime target policy. The reserved destination fetches fresh
   per-subject credentials from fleet-edge with its machine identity; do not
   restore the retired shared B2 secret or `backup.environmentFile` option.
3. Check space for `/srv/containers` **and** each declared `/srv/bulk` extra
   path on h003's NVMe. Match all `requires` capabilities; h003 does not
   currently offer `nfs-h004` or `intel-qsv`.

### Step 1: Evacuate Services to `h003`
1. Select backup-enabled portable services from the current runtime placement
   (`cnt place`) and inventory, then use `cnt move <svc> --to h003`. The move
   pre-syncs declared local bulk paths and retains the source bulk copy; allow
   time and space for that transfer. See [Moving a service](../containers/README.md#moving-a-service-to-another-host).
   - Immich/Paperless require `bulk`, not the retired `wd10` capability; h003
     can receive their declared extra paths if it has space. arr still needs
     `nfs-h004`/`intel-qsv`: retain those capabilities on a suitable host or
     leave it stopped during maintenance, preserving its state and h004 media.
   - `litellm`, `llm-router`, `searx`, `hello-nixos` and `hello-podman` disable
     nightly backups. Deliberately redeploy/re-authenticate their disposable
     state on the target; do not run restore-based `cnt move` unless backups
     are explicitly enabled first.
2. Placement is runtime state in fleet-edge, not a `host` field in
   `service.nix`. A successful move commits placement and reconciles routing
   without h005/o002 rebuilds. For deliberate disposable redeploys, stop the
   old copy, deploy to the chosen host and intentionally rebind with
   `cnt place <svc> --set h003`; do not leave two serving copies.
3. Prove independent recovery before re-imaging: a successful move can copy
   PostgreSQL clusters from the surviving source, so it does not demonstrate
   a B2-only dump import. Restore representative SQLite copies, PostgreSQL
   dumps and bulk paths to scratch and verify application data using the
   [recovery runbook](../containers/README.md#b2-only-recovery-independent-of-h005h004).

### Step 2: Re-image `h001` Root onto Encrypted bcachefs + Impermanence
1. Follow `utilities/nixos-install-disko/readme.md` (same pattern as `h003`, `h004`, `h005`):
   - Disconnect or leave the disk normally mounted at `/srv/bulk` unmounted so the installer only touches the boot NVMe.
   - Partition the boot NVMe via `disko` single-drive encrypted bcachefs (`@root`, `@nix`, `@persist`, `@snapshots`).
   - Create a USB unlock stick (`utilities/nixos-install-disko/usb_key.md`), label `"h001 key"`, leave plugged in.
2. Add `hosts/h001/impermanence.nix`:
   - Shared `essentials` + `tailscale` persistence.
   - `/var/lib/secrets_manager_hydrated` and `/persist/machine-key.json`.
   - `/srv/containers`, `/var/lib/fleet-containers`, `/etc/systemd-mutable`, `/var/lib/containers` (podman), `/var/lib/fleet-cert`.
3. Install, verify unattended USB unlock, verify `/srv/bulk` and `/nfs/h002/nixarr` mounts, and verify `sec-agent` hydrates. Restore retained host data/identity before resuming its services.

### Step 3: Move Services Back to `h001`
1. Restore any non-evacuated service roots and required SQLite copies/PostgreSQL dumps before starting them; reconnect preserved `/srv/bulk` and h004 NFS media as appropriate. A B2 restore is not automatic PostgreSQL recovery.
2. `cnt move <svc> --to h001` for backup-enabled services returning from h003; placement/routing follow at runtime. Deliberately redeploy disposable services instead, and leave any services on h003 that make sense to keep distributed.

---

## Plan for `lio` (Backup Daily Workhorse → Re-image)

`lio` is the daily driver workstation, so minimizing disruption and guaranteeing zero lost local work is the priority.

### Step 1: Complete & Verify `lio` Restic Backup
1. Declare and deploy a host backup subject for the selected `/home/josh` paths (and any needed `/mnt/nvme1tb` data), using the per-subject h004/B2 architecture in `containers/README.md`. No full-home backup is established by the container backup timer; verify coverage and an independent restore before re-imaging.
2. Audit unpushed git repos / dirty worktrees across `/home/josh/projects`:
   ```sh
   find ~/projects -name .git -type d -prune -exec dirname {} \; | while read -r r; do
     git -C "$r" status --porcelain -b | grep -E 'ahead|^[MADRCU?!]' && echo "=== $r ==="
   done
   ```
3. Take a secondary local copy of critical `/home/josh` directories onto `/mnt/nvme1tb` (the second NVMe disk) or a dedicated path under `/srv/bulk` on h001 for fast local restore after re-imaging; confirm that copy and its destination survive the planned install.

### Step 2: Re-image `lio` Root NVMe onto bcachefs + Impermanence
1. Model `hosts/lio/impermanence.nix` after `juni/impermanence.nix` and `joe/impermanence.nix`:
   - Shared persistence modules: `essentials`, `network_manager`, `bluetooth`, `pipewire`, `tailscale`, `flatpak`, `de_plasma`, `steam`, `vesktop`, `bitwarden`, `firefox`, `chrome`, `atuin`, `direnv`, `zoxide`, `tmux`, `nvim_ros`, `opencode`, `nono`, `mva`, `xdg_user_dirs`.
   - Container/VM state if kept on root: `/srv/containers`, `/var/lib/fleet-containers`, `/var/lib/libvirt`.
   - User directories (`projects`, `.ssh`, `.gnupg`, `.local/share/omp`, etc.).
2. Install via `utilities/nixos-install-disko/readme.md` onto the root NVMe (leaving `/mnt/nvme1tb` untouched).
3. Restore `/home/josh` persisted paths from `/mnt/nvme1tb` (or B2), seed `/persist/machine-key.json`, and reboot twice to confirm clean root reset.
