# restic backup of h001's critical data: immich, paperless, dawarich,
# plus manual archives in ~luser/backups (`cnt backup` tarballs etc.).
#
# The repository, password and backend credentials all come from the
# `restic_h001_env_2026-10-01` EnvironmentFile (sec-agent.nix), so the
# offsite backend can be chosen without touching this file.
#
# Runs nightly at ~03:00 and prunes per pruneOpts. `initialize = false`, so a
# new repository must be created by hand first: `sudo restic-h001 init`.
# Manual run: `sudo systemctl start restic-backups-h001`.
#
# Databases are backed up as dumps, never as live cluster directories.
{
  pkgs,
  lib,
  constants,
  ...
}:
let
  s = constants.services;
  staging = "/var/lib/restic-staging";
in
{
  systemd.tmpfiles.rules = [ "d ${staging} 0700 root root - -" ];

  services.restic.backups.h001 = {
    initialize = false;
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
    # environmentFile is set by sec-agent configChanges.

    backupPrepareCommand = ''
      set -eu
      # Fresh pg_dumpall in each container (postgresqlBackup is a oneshot,
      # so this blocks until the dump is written).
      for ct in immich paperless; do
        ${pkgs.nixos-container}/bin/nixos-container run "$ct" -- systemctl start postgresqlBackup.service
      done
      # dawarich is a floating container (cnt): skip only if it is not running
      # here (stopped or moved); if it runs, a failed dump fails the backup.
      if [ "$(${pkgs.systemd}/bin/systemctl is-active container@dawarich.service || true)" = active ]; then
        ${pkgs.nixos-container}/bin/nixos-container run dawarich -- systemctl start postgresqlBackup.service
      else
        echo "dawarich not running on this host; pg dump skipped" >&2
      fi
    '';

    paths = [
      staging
      # immich: originals + immich's own DB dumps (media/backups), pg_dumpall
      "${s.immich.dataDir}/media"
      "${s.immich.varLibDir}/backups/postgres"
      # paperless: documents + consume dir, app data, pg_dumpall
      s.paperless.dataDir
      "${s.paperless.varLibDir}/data"
      "${s.paperless.varLibDir}/backups/postgres"
      # dawarich (floating container): uploads + secret key base, pg_dumpall
      "/srv/containers/dawarich/data"
      "/srv/containers/dawarich/pgdumps"
      # hand-made archives (cnt backup tarballs, pre-migration snapshots)
      "/home/luser/backups"
    ];

    exclude = [
      # regenerable
      "${s.immich.dataDir}/media/thumbs"
      "${s.immich.dataDir}/media/encoded-video"
      "${s.paperless.dataDir}/media/documents/thumbnails"
      "${s.paperless.varLibDir}/data/index"
    ];

    extraBackupArgs = [
      "--exclude-caches"
      "--tag"
      "h001"
    ];
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];
  };

  systemd.services.restic-backups-h001.unitConfig.RequiresMountsFor = [ "/drives/wd10" ];
}
