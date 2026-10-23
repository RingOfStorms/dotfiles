# Restic Backups: Status & Remaining Work

## Current Production State (Live)

Architecture: **Direct to Backblaze B2** (`s3:https://<b2-endpoint>/<bucket>/...`) using `restic_h001_env_2026-10-01` hydrated via `sec-agent`. The earlier local `rest-server` + Hetzner Storage Box `restic copy` design was dropped in favor of direct B2 uploads with per-tag grouping (`--group-by host,tags`).

### What is Deployed & Verified

1. **Per-Service Floating Container Backups (`ringofstorms.containers.backup` / `fleet-backup.service`):**
   - Configured in `containers/host-module.nix` (see `containers/ROUTING-PLAN.md` §9.1), enabled on `h001` (`hosts/h001/floating-containers.nix:23-26`) and `lio` (`hosts/lio/flake.nix:94`).
   - Runs nightly at `03:00`. For each service in `/srv/containers/<svc>`, runs pre-backup hooks (`postgresqlBackup`, custom `backupHooks`), snapshots SQLite files via `.backup`, backs up to B2 tagged `svc:<name>`, prunes per-service snapshots, and writes a timestamp read by `fleet-agent` (`/status.json`) and rendered in the `fleet-edge` dashboard on `h005` (flags stale after 36h).
   - Verified 2026-10-22 across all 17 services on `h001`; `cnt restore-check <svc>` verifies SQLite `PRAGMA integrity_check` and PG dump completeness.
2. **`h001` Host-Only Media/Archive Backup (`hosts/h001/mods/restic-backup.nix`):**
   - Runs nightly at `03:00` (`restic-backups-h001.service`), tagged `h001` (`--group-by host,tags`, `--retry-lock 2h`).
   - Backs up `/drives/wd10/immich/media` (excluding regenerable `thumbs` and `encoded-video`), `/drives/wd10/paperless` (excluding `thumbnails`), and `/home/luser/backups`.
   - Prunes nightly (`--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 3`).
3. **Break-Glass Keys & Cold-Restore Verification (`ROUTING-PLAN.md` §9.3):**
   - Completed 2026-10-22: restic B2 env, `sec` encryption key (`/srv/containers/sec/data/db.key`), Zitadel masterkey (32 bytes), and `root_fleet_backup` SSH key are stored outside the fleet in the password manager, alongside an independent data copy of `sec` and `zitadel` and a verified cold restore.
4. **Legacy Rsync Module Retired:**
   - `flakes/common/nix_modules/backup.nix` (`ros-backup` to `h004`) has been removed; `h004` exports `/data/nixarr` only.

---

## Remaining Work (Worth Doing)

### 1. `lio` Workstation Home Backup (`hosts/lio/restic.nix`)
`lio` is the daily driver workhorse (`hosts/lio/flake.nix`). Currently `ringofstorms.containers.backup.enable = true` on `lio` only backs up floating containers hosted on `lio`—**not** `/home/josh` or `/mnt/nvme1tb`. This is also a prerequisite before re-imaging `lio` onto impermanence (`ideas/impermanence_everywhere.md`).

```nix
# hosts/lio/restic.nix
{ ... }:
{
  services.restic.backups.lio-home = {
    # Wire environmentFile in hosts/lio/sec-agent.nix (either shared repo with --tag lio-home or dedicated B2 prefix)
    initialize = true;
    inhibitsSleep = true;
    timerConfig = {
      OnCalendar = "02:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    paths = [
      "/home/josh/Documents"
      "/home/josh/projects"
      "/home/josh/Pictures"
      "/home/josh/Desktop"
      "/home/josh/.ssh"
      "/home/josh/.gnupg"
      "/home/josh/.config/nixos-config"
      # Add any critical paths on /mnt/nvme1tb
    ];
    exclude = [
      "**/.cache"
      "**/node_modules"
      "**/target"
      "**/.direnv"
      "**/result"
      "**/result-*"
      "**/.venv"
      "**/__pycache__"
      "**/.gradle"
      "**/build/intermediates"
      "**/.next"
      "**/dist"
      "/home/josh/.local/share/Steam"
      "/home/josh/.steam"
      "**/SteamLibrary"
      "/home/josh/.local/share/containers"
      "/home/josh/.local/share/Trash"
      "/home/josh/.local/share/flatpak"
      "/home/josh/.var/app/*/cache"
      "/home/josh/Downloads"
      "**/*.qcow2"
      "**/*.iso"
    ];
    extraBackupArgs = [
      "--exclude-caches"
      "--exclude-if-present=.nobackup"
      "--one-file-system"
      "--retry-lock"
      "2h"
      "--group-by"
      "host,tags"
      "--tag"
      "lio-home"
    ];
    pruneOpts = [
      "--retry-lock 2h"
      "--tag lio-home"
      "--group-by host,tags"
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];
  };
}
```

### 2. Enable `ringofstorms.containers.backup` on `h003` (and `joe`)
`cnt move <svc> --to h003` enforces that both source and target hosts have `ringofstorms.containers.backup` configured (`ROUTING-PLAN.md` §9.1). Enabling this on `h003` is required before using `h003` as a warm failover target (`ideas/resilience.md`) or evacuating `h001` for its impermanence re-image (`ideas/impermanence_everywhere.md`):
- In `hosts/h003/containers.nix`: set `ringofstorms.containers.backup.enable = true;`.
- In `hosts/h003/sec-agent.nix`: hydrate `restic_h001_env_2026-10-01` with `configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";`.

### 3. `o002` Headscale State Backup
`o002` runs the fleet's `headscale` control plane (`hosts/oracle/o002/headscale.nix`) with state in `/persist/var/lib/headscale`. Since `backup.nix` was retired, `o002` has no automated off-host backup:
- Add a restic job on `o002` (with SQLite `.backup` of `/var/lib/headscale/db.sqlite` in `backupPrepareCommand`, tagged `o002-headscale`) pushing to B2, **or** pull a daily `sqlite3 .backup` snapshot from `h001`/`h005` into a backed-up directory.

### 4. Failure Alerting & Dead-Man Switch
Currently `fleet-edge` on `h005` visually flags container backups older than 36h, but nothing sends a push notification when `fleet-backup`, `restic-backups-h001`, or a timer fails silently:
- Add an `OnFailure = [ "notify-failure@%n.service" ]` hook (or poll `/status.json` from `h005` / external healthcheck) to alert on failed units or stale `lastBackup` timestamps.

### 5. Consolidate `life` Container Backup (Optional Cleanup)
`containers/life/` runs its own internal `restic` + `pgBackRest` timer (`life_backup_env_2026-09-30` and `life_pgbackrest_2026-09-30` in `hosts/h001/sec-agent.nix:49-61`) in addition to `fleet-backup` (`svc:life`). Decide whether to keep both as independent layers or fold `life`'s pgBackRest output into `fleet-backup` alone.
