# Daily sweeper for LocalAI's generated media.
#
# LocalAI writes every result it produces (images, TTS wavs, 3D GLBs, videos)
# into `persist.images` = /tmp/generated inside the container, i.e.
# /srv/containers/localai/images on the host. Nothing prunes it: the files
# from the web UI, Open WebUI, life and any script/dev task calling the API
# all pile up forever. Anything worth keeping is expected to be saved by the
# caller at generation time (the UI downloads, scripts copy the b64 out), so
# the server side is treated as scratch space.
#
# Chat history is not touched: it is not stored on this filesystem (the
# LocalAI web UI keeps it in browser storage; Open WebUI has its own database
# in containers/open-webui).
{
  pkgs,
  lib,
  ...
}:
let
  # Host path of containers/localai/service.nix `persist.images`.
  generatedDir = "/srv/containers/localai/images";
  retentionDays = 1;
in
{
  systemd.services.localai-cleanup = {
    description = "Delete generated LocalAI media older than ${toString retentionDays}d";
    # The bind source is on the persistent filesystem; don't run before it is
    # mounted (same guard the container unit uses).
    unitConfig.RequiresMountsFor = generatedDir;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "localai-cleanup" ''
        set -eu
        dir=${lib.escapeShellArg generatedDir}
        if [ ! -d "$dir" ]; then
          echo "localai-cleanup: $dir does not exist, nothing to do"
          exit 0
        fi
        before=$(${pkgs.coreutils}/bin/du -sk "$dir" | ${pkgs.coreutils}/bin/cut -f1)
        # -xdev: never follow a stray mount out of the generated tree.
        # -print keeps one journal line per file (what was deleted and when).
        deleted=$(${pkgs.findutils}/bin/find "$dir" -xdev -type f \
          -mmin +$(( ${toString retentionDays} * 24 * 60 )) -print -delete \
          | ${pkgs.coreutils}/bin/wc -l)
        after=$(${pkgs.coreutils}/bin/du -sk "$dir" | ${pkgs.coreutils}/bin/cut -f1)
        echo "localai-cleanup: deleted $deleted file(s), freed $((before - after)) KiB, $dir is now $after KiB"
      '';
      # Only the generated tree is writable.
      ProtectSystem = "strict";
      ReadWritePaths = [ generatedDir ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.localai-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 04:15, after the nightly fleet backup (03:00) has picked up whatever
      # is still there.
      OnCalendar = "*-*-* 04:15:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
