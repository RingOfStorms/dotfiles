# Reusable host backup via rsync push to the h002 NAS.
#
# Each opted-in host pushes its declared `paths` to
#   <user>@<targetHost>:<targetDir>/<hostName>/<timestamp>/
# using rsync over SSH with the fleet's nix2nix key. Each run is
# hardlinked (`--link-dest`) against the previous snapshot, giving cheap
# Time-Machine-style incremental history on the (bcachefs, 2x-replicated)
# NAS without per-run full copies. Old snapshots are pruned after
# `keepDays` days. `--fake-super` preserves original uid/gid/mode in
# xattrs on the receiver (which writes as an unprivileged user), so
# restores reproduce ownership correctly (e.g. vaultwarden uid 114).
#
# NOTE: backups are NOT encrypted at rest. This is intentional — the NAS
# is self-owned and on the private tailnet. Add encryption (e.g. restic)
# if/when offsite (B2/S3) backups are introduced.
#
# Wiring (per host):
#
#   ringofstorms.backup = {
#     enable = true;
#     paths = [ "/var/lib/vaultwarden" "/var/lib/acme" ];
#   };
#
# Database dumps are a per-host concern: if a host wants its DBs backed
# up, it enables services.postgresqlBackup (or equivalent) itself and
# adds the dump directory (e.g. /var/backup/postgresql) to `paths`.
#
# Requires: the host is on the tailnet and has the nix2nix SSH key at
# `sshKeyFile` (default /var/lib/openbao-secrets/nix2nix_2026-03-15),
# i.e. a machines-hightrust secrets-bao host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.backup;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    concatStringsSep
    escapeShellArg
    ;

  hostName = config.networking.hostName;
in
{
  options.ringofstorms.backup = {
    enable = mkEnableOption "rsync-push backups to the h002 NAS";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Absolute paths to back up.";
      example = [ "/var/lib/vaultwarden" "/var/lib/acme" ];
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [
        "**/cache/**"
        "**/Cache/**"
        "**/.cache/**"
        "**/tmp/**"
      ];
      description = "rsync exclude patterns (applied to every path).";
    };

    targetHost = mkOption {
      type = types.str;
      default = "100.64.0.3";
      description = "h002 NAS address (tailnet overlay IP by default).";
    };

    targetUser = mkOption {
      type = types.str;
      default = "luser";
      description = "SSH user on the NAS that owns the backup tree.";
    };

    targetDir = mkOption {
      type = types.str;
      default = "/data/backups";
      description = "Base backup directory on the NAS (per-host subdir is appended).";
    };

    sshKeyFile = mkOption {
      type = types.str;
      default = "/var/lib/openbao-secrets/nix2nix_2026-03-15";
      description = "Private SSH key used to authenticate to the NAS.";
    };

    keepDays = mkOption {
      type = types.int;
      default = 14;
      description = "Delete dated snapshots older than this many days.";
    };

    startAt = mkOption {
      type = types.str;
      default = "03:00";
      description = "systemd OnCalendar time for the backup run.";
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "30m";
      description = "Randomized delay added to the timer.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.paths != [ ];
        message = "ringofstorms.backup.enable is true but no paths are set on ${hostName}.";
      }
    ];

    systemd.services.ros-backup = {
      description = "rsync-push backup to h002 NAS";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # Needs root to read /var/lib/<service> trees.
        User = "root";
      };

      path = with pkgs; [ rsync openssh coreutils ];

      script =
        let
          pathsLine = concatStringsSep " " (map escapeShellArg cfg.paths);
          excludeArgs = concatStringsSep " " (
            map (e: "--exclude=${escapeShellArg e}") cfg.exclude
          );
          remote = "${cfg.targetUser}@${cfg.targetHost}";
          base = "${cfg.targetDir}/${hostName}";
        in
        ''
          set -euo pipefail

          KEY=${escapeShellArg cfg.sshKeyFile}
          REMOTE=${escapeShellArg remote}
          BASE=${escapeShellArg base}
          TS="$(date +%Y-%m-%d_%H%M%S)"

          SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"

          echo "=== backup $TS: ${hostName} -> $REMOTE:$BASE/$TS ==="

          # Ensure the per-host base dir exists on the NAS.
          $SSH "$REMOTE" "mkdir -p $BASE"

          # Find the previous snapshot to hardlink against (cheap incrementals).
          PREV="$($SSH "$REMOTE" "ls -1 $BASE | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort | tail -1" || true)"
          LINKDEST=""
          if [ -n "$PREV" ]; then
            echo "Hardlinking against previous snapshot: $PREV"
            LINKDEST="--link-dest=$BASE/$PREV"
          else
            echo "No previous snapshot; first full backup."
          fi

          # rsync each declared path into the new timestamped snapshot.
          # -a archive, -R relative (preserves full source path under dest),
          # --numeric-ids keeps numeric ownership. The sender runs as real
          # root (sees true uid/gid); the receiver runs as an unprivileged
          # user, so --rsync-path 'rsync --fake-super' makes the remote
          # rsync store uid/gid/mode in xattrs instead of failing to chown.
          # Restores must use the matching --fake-super to reproduce them.
          rsync -aR --numeric-ids --delete \
            ${excludeArgs} \
            $LINKDEST \
            -e "$SSH" \
            --rsync-path="rsync --fake-super" \
            ${pathsLine} \
            "$REMOTE:$BASE/$TS/"

          # Update a convenience 'latest' symlink on the NAS.
          $SSH "$REMOTE" "ln -sfn $BASE/$TS $BASE/latest"

          echo "=== pruning snapshots older than ${toString cfg.keepDays} days ==="
          CUTOFF="$(date -d '-${toString cfg.keepDays} days' +%Y-%m-%d_%H%M%S)"
          for snap in $($SSH "$REMOTE" "ls -1 $BASE | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort"); do
            if [ "$snap" \< "$CUTOFF" ]; then
              echo "  pruning $snap"
              $SSH "$REMOTE" "rm -rf $BASE/$snap"
            fi
          done

          echo "=== backup complete: $REMOTE:$BASE/$TS ==="
        '';
    };

    systemd.timers.ros-backup = {
      description = "Timer for rsync-push backup to h002 NAS";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.startAt;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Persistent = true;
      };
    };
  };
}
