# restic backup of h001's host-only data: the wd10 media of immich/paperless
# and manual archives in ~luser/backups (`cnt backup` tarballs etc.).
#
# Floating containers (/srv/containers/<svc>, their backupHooks and SQLite
# copies) are backed up by the containers host module instead
# (ringofstorms.containers.backup, fleet-backup.service, one snapshot per
# service tagged `svc:<name>`; see floating-containers.nix and
# containers/ROUTING-PLAN.md §9.1). Both jobs use the same repository.
#
# The repository, password and backend credentials all come from the
# `restic_h001_env_2026-10-01` EnvironmentFile (sec-agent.nix).
#
# Runs nightly at ~03:00 and prunes per pruneOpts. `initialize = false`, so a
# new repository must be created by hand first: `sudo restic-h001 init`.
# Manual run: `sudo systemctl start restic-backups-h001`.
# Snapshots before 2026-10-22 (tag h001) also hold /srv/containers.
{ ... }:
{
  services.restic.backups.h001 = {
    initialize = false;
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
    # environmentFile is set by sec-agent configChanges.

    paths = [
      # immich originals + immich's own DB dumps (media/backups)
      "/drives/wd10/immich/media"
      # paperless documents + consume dir
      "/drives/wd10/paperless"
      # hand-made archives (cnt backup tarballs, pre-migration snapshots)
      "/home/luser/backups"
    ];

    exclude = [
      # regenerable
      "/drives/wd10/immich/media/thumbs"
      "/drives/wd10/immich/media/encoded-video"
      "/drives/wd10/paperless/media/documents/thumbnails"
    ];

    extraBackupArgs = [
      "--exclude-caches"
      # fleet-backup runs at the same time; wait for its prune lock
      "--retry-lock"
      "2h"
      # Pick the parent snapshot by host+tag, not host+paths (path list changes
      # would otherwise force a full re-read).
      "--group-by"
      "host,tags"
      "--tag"
      "h001"
    ];
    pruneOpts = [
      "--retry-lock 2h"
      # Same grouping as backup; --tag h001 keeps it off the fleet-backup
      # (svc:*) snapshots, which fleet-backup prunes itself.
      "--tag h001"
      "--group-by host,tags"
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];
  };

  systemd.services.restic-backups-h001.unitConfig.RequiresMountsFor = [ "/drives/wd10" ];
}
