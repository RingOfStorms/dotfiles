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

Because all stateful services on `h001` now live in floating containers (`containers/*`) managed by `cnt` (`fleet containers`), `h001` no longer has sprawling `/var/lib/<service>` host state. The only non-container data on `h001` is on the separate `/drives/wd10` disk (`immich/media`, `paperless`, etc.), which stays untouched during a root NVMe re-image.

### Step 0: Prerequisites on `h003`
1. Enable `ringofstorms.containers.backup` on `h003` (wire `restic_h001_env_2026-10-01` in `hosts/h003/sec-agent.nix` so `cnt move` preflight passes).
2. Ensure `h003` has enough disk space on `/persist/srv/containers` for the services being evacuated.

### Step 1: Evacuate Services to `h003`
1. Move portable floating containers (`zitadel`, `sec`, `forgejo`, `vaultwarden`, `atuin`, `trilium`, `matrix`, `dawarich`, `life`, `puzzles`, `searx`, `opengist`, `open-webui`, `litellm`, etc.) to `h003` using `cnt move <svc> --to h003`.
   - Note: Services requiring `h001`-only hardware capabilities (`wd10` for `immich`/`paperless`, or `nfs-h004`/`intel-qsv` for `arr` unless temporarily mounted on `h003`) can either be stopped during the maintenance window (`cnt stop <svc>`) after a fresh `fleet-backup` run + local backup on `/drives/wd10`, or temporarily given an NFS mount on `h003`.
2. Update `host = "h003"` in `containers/<svc>/service.nix` for evacuated services and redeploy `h005` (`dns-records.nix`) / `o002` (`nginx.nix`) if needed so routes stay live while `h001` is on the bench.

### Step 2: Re-image `h001` Root onto Encrypted bcachefs + Impermanence
1. Follow `utilities/nixos-install-disko/readme.md` (same pattern as `h003`, `h004`, `h005`):
   - Disconnect or leave `/drives/wd10` unmounted (`RequiresMountsFor` / `nofail`) so the installer only touches the boot NVMe.
   - Partition the boot NVMe via `disko` single-drive encrypted bcachefs (`@root`, `@nix`, `@persist`, `@snapshots`).
   - Create a USB unlock stick (`utilities/nixos-install-disko/usb_key.md`), label `"h001 key"`, leave plugged in.
2. Add `hosts/h001/impermanence.nix`:
   - Shared `essentials` + `tailscale` persistence.
   - `/var/lib/secrets_manager_hydrated` and `/persist/machine-key.json`.
   - `/srv/containers`, `/var/lib/fleet-containers`, `/etc/systemd-mutable`, `/var/lib/containers` (podman), `/var/lib/fleet-cert`.
3. Install, verify unattended USB unlock, verify `/drives/wd10` and `/nfs/h002/nixarr` autofs mounts cleanly, and verify `sec-agent` hydrates.

### Step 3: Move Services Back to `h001`
1. Restart `wd10`-bound services (`immich`, `paperless`, `arr`) from their preserved state / B2 snapshot.
2. `cnt move <svc> --to h001` for the services that belong on `h001` permanently (and leave any services on `h003` that make sense to keep distributed).

---

## Plan for `lio` (Backup Daily Workhorse → Re-image)

`lio` is the daily driver workstation, so minimizing disruption and guaranteeing zero lost local work is the priority.

### Step 1: Complete & Verify `lio` Restic Backup
1. Deploy `hosts/lio/restic.nix` (see `ideas/restic_backups.md`) backing up `/home/josh` (and any needed paths on `/mnt/nvme1tb`) to B2.
2. Audit unpushed git repos / dirty worktrees across `/home/josh/projects`:
   ```sh
   find ~/projects -name .git -type d -prune -exec dirname {} \; | while read -r r; do
     git -C "$r" status --porcelain -b | grep -E 'ahead|^[MADRCU?!]' && echo "=== $r ==="
   done
   ```
3. Take a secondary local copy of critical `/home/josh` directories onto `/mnt/nvme1tb` (the second NVMe disk) or `/drives/wd10` on `h001` for fast local restore after re-imaging (so we don't have to pull hundreds of GBs back down from B2).

### Step 2: Re-image `lio` Root NVMe onto bcachefs + Impermanence
1. Model `hosts/lio/impermanence.nix` after `juni/impermanence.nix` and `joe/impermanence.nix`:
   - Shared persistence modules: `essentials`, `network_manager`, `bluetooth`, `pipewire`, `tailscale`, `flatpak`, `de_plasma`, `steam`, `vesktop`, `bitwarden`, `firefox`, `chrome`, `atuin`, `direnv`, `zoxide`, `tmux`, `nvim_ros`, `opencode`, `nono`, `mva`, `xdg_user_dirs`.
   - Container/VM state if kept on root: `/srv/containers`, `/var/lib/fleet-containers`, `/var/lib/libvirt`.
   - User directories (`projects`, `.ssh`, `.gnupg`, `.local/share/omp`, etc.).
2. Install via `utilities/nixos-install-disko/readme.md` onto the root NVMe (leaving `/mnt/nvme1tb` untouched).
3. Restore `/home/josh` persisted paths from `/mnt/nvme1tb` (or B2), seed `/persist/machine-key.json`, and reboot twice to confirm clean root reset.
