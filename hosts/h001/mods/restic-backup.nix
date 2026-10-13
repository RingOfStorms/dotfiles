# restic backup of h001's critical data: every floating container's persist
# dir (/srv/containers), the wd10 media of immich/paperless, plus manual
# archives in ~luser/backups (`cnt backup` tarballs etc.).
#
# The repository, password and backend credentials all come from the
# `restic_h001_env_2026-10-01` EnvironmentFile (sec-agent.nix), so the
# offsite backend can be chosen without touching this file.
#
# Runs nightly at ~03:00 and prunes per pruneOpts. `initialize = false`, so a
# new repository must be created by hand first: `sudo restic-h001 init`.
# Manual run: `sudo systemctl start restic-backups-h001`.
#
# Databases are backed up as dumps, never as live cluster directories: before
# the snapshot, each floating service that is running HERE gets its
# service.nix `backupHook` (pg_dumpall etc. into a persisted dir), the same
# hook `cnt backup` runs. A failing hook fails the backup. Services not
# running on h001 (stopped, or moved with `cnt move`) are skipped; their
# data on this host is then whatever was left behind.
{
  pkgs,
  lib,
  ...
}:
let
  staging = "/var/lib/restic-staging";
  containersDir = ../../../containers;
  dataRoot = "/srv/containers";
  entries = builtins.readDir containersDir;
  services = map (n: import (containersDir + "/${n}/service.nix")) (
    builtins.filter (
      n: entries.${n} == "directory" && builtins.pathExists (containersDir + "/${n}/service.nix")
    ) (builtins.attrNames entries)
  );
  withHook = builtins.filter (s: (s.backupHook or null) != null) services;
  hookCmd =
    s:
    let
      kind = s.kind or "nixos";
      unit = if kind == "podman" then "fleet-${s.name}.service" else "container@${s.name}.service";
      run =
        if kind == "podman" then
          "${pkgs.podman}/bin/podman exec ${s.name} sh -c ${lib.escapeShellArg s.backupHook}"
        else
          "${pkgs.nixos-container}/bin/nixos-container run ${s.name} -- bash -lc ${lib.escapeShellArg s.backupHook}";
    in
    ''
      if [ "$(${pkgs.systemd}/bin/systemctl is-active ${unit} || true)" = active ]; then
        echo "backup hook: ${s.name}" >&2
        ${run}
      else
        echo "backup hook: ${s.name} not running on this host, skipped" >&2
      fi
    '';
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
      ${lib.concatMapStrings hookCmd withHook}
    '';

    paths = [
      staging
      # every floating container's persist dirs (dumps from the hooks above)
      dataRoot
      # immich originals + immich's own DB dumps (media/backups)
      "/drives/wd10/immich/media"
      # paperless documents + consume dir
      "/drives/wd10/paperless"
      # hand-made archives (cnt backup tarballs, pre-migration snapshots)
      "/home/luser/backups"
    ];

    exclude = [
      # live database clusters: inconsistent when copied hot; the hooks'
      # dumps are what gets restored
      "${dataRoot}/*/postgres"
      "${dataRoot}/atuin/postgresql/[0-9]*"
      "${dataRoot}/minecraft/postgresql/[0-9]*"
      # regenerable
      "${dataRoot}/immich/mlcache"
      "${dataRoot}/open-webui/data/hf_home"
      "${dataRoot}/open-webui/data/transformers_home"
      "${dataRoot}/open-webui/data/xet"
      "${dataRoot}/open-webui/data/models--*"
      "${dataRoot}/paperless/data/index"
      "/drives/wd10/immich/media/thumbs"
      "/drives/wd10/immich/media/encoded-video"
      "/drives/wd10/paperless/media/documents/thumbnails"
    ];

    extraBackupArgs = [
      "--exclude-caches"
      # Pick the parent snapshot by host+tag, not host+paths: the default
      # (host,paths) finds no parent whenever the path list changes (services
      # moving to /srv/containers), forcing a full multi-hour re-read.
      "--group-by"
      "host,tags"
      "--tag"
      "h001"
    ];
    pruneOpts = [
      # Same grouping as backup: one retention series across path-list changes.
      "--group-by host,tags"
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];
  };

  systemd.services.restic-backups-h001.unitConfig.RequiresMountsFor = [
    "/drives/wd10"
    dataRoot
  ];
}
