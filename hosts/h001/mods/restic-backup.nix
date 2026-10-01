# restic backup of h001's critical data: immich, paperless, dawarich, etebase.
#
# The repository, password and backend credentials all come from the
# `restic_h001_env_2026-10-01` EnvironmentFile (sec-agent.nix), so the
# offsite backend can be chosen without touching this file.
#
# Manual-only for now: no timer and `initialize = false`. First run:
#   sudo restic-h001 init
#   sudo systemctl start restic-backups-h001
# To schedule it, set `timerConfig`, e.g.
#   { OnCalendar = "03:00"; Persistent = true; RandomizedDelaySec = "15m"; }
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
    timerConfig = null;
    # environmentFile is set by sec-agent configChanges.

    backupPrepareCommand = ''
      set -eu
      # Fresh pg_dumpall in each container (postgresqlBackup is a oneshot,
      # so this blocks until the dump is written).
      for ct in immich paperless dawarich; do
        ${pkgs.nixos-container}/bin/nixos-container run "$ct" -- systemctl start postgresqlBackup.service
      done
      # Consistent copy of etebase's live SQLite database.
      ${lib.getExe pkgs.sqlite} ${s.etebase.dataDir}/db.sqlite3 ".backup '${staging}/etebase.sqlite3'"
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
      # dawarich: uploads, secret key base, pg_dumpall (under backups/)
      s.dawarich.dataDir
      # etebase: secret.txt + media (live db excluded, staged above)
      s.etebase.dataDir
    ];

    exclude = [
      # live database clusters / caches (dumps are backed up instead)
      "${s.dawarich.dataDir}/postgres"
      "${s.dawarich.dataDir}/redis"
      "${s.etebase.dataDir}/db.sqlite3*"
      # regenerable
      "${s.immich.dataDir}/media/thumbs"
      "${s.immich.dataDir}/media/encoded-video"
      "${s.paperless.dataDir}/media/documents/thumbnails"
      "${s.paperless.varLibDir}/data/index"
      "${s.etebase.dataDir}/static"
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
