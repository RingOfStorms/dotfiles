{ config, lib, pkgs, ... }:
let
  cfg = config.services.automatic-timezoned;
  persistFile = if cfg.persistDir == null then null else "${cfg.persistDir}/timezone";
  tzdata = pkgs.tzdata;
in
{
  options.services.automatic-timezoned.persistDir = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Absolute runtime directory used to persist the timezone for impermanence setups.

      Important: this must be a normal filesystem path (a string like
      "/persist/var/lib/timezone-persist"), not a Nix `path` value, otherwise it
      can be coerced into a `/nix/store/...` path and become unwritable at runtime.

      When set, the timezone is saved to this directory and restored on boot,
      allowing offline boots to use the last known timezone.
      Set to null to disable persistence (default).
    '';
  };

  config = {
    assertions = [
      {
        assertion = cfg.persistDir == null || lib.hasPrefix "/" cfg.persistDir;
        message = "services.automatic-timezoned.persistDir must be an absolute path";
      }
    ];

    services.dbus.enable = lib.mkDefault true;
    services.geoclue2.enable = true;

    time.timeZone = null;
    services.automatic-timezoned.enable = true;

    systemd.services.automatic-timezoned = {
      after = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ]
        ++ lib.optional (cfg.persistDir != null) "timezone-restore.service";
      wants = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ]
        ++ lib.optional (cfg.persistDir != null) "timezone-restore.service";
      serviceConfig = {
        ExecStartPre = "${lib.getExe' pkgs.coreutils "sleep"} 5";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };

    systemd.services.automatic-timezoned-geoclue-agent = {
      after = [ "dbus.socket" ];
      wants = [ "dbus.socket" ];
    };

    # Ensure anything using timedate1 sees restored timezone first.
    systemd.services.systemd-timedated = lib.mkIf (cfg.persistDir != null) {
      after = [ "timezone-restore.service" ];
      wants = [ "timezone-restore.service" ];
      requires = [ "timezone-restore.service" ];
    };

    # Restore timezone from persistent storage on boot (fallback for offline boots)
    systemd.services.timezone-restore = lib.mkIf (cfg.persistDir != null) {
      description = "Restore timezone from persistent storage";
      wantedBy = [ "sysinit.target" ];

      # NixOS activation may recreate /etc/localtime based on config.
      # Run after activation so the restored timezone "wins" on offline boots.
      after = [
        "local-fs.target"
        "systemd-remount-fs.service"
        "nixos-activation.service"
      ];
      wants = [ "nixos-activation.service" ];

      before = [
        "time-sync.target"
        "automatic-timezoned.service"
        "systemd-timedated.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RequiresMountsFor = [ cfg.persistDir ];
        ExecStart = pkgs.writeShellScript "timezone-restore" ''
          set -euo pipefail
          persist_file="${persistFile}"

          if [ ! -f "$persist_file" ]; then
            echo "No persisted timezone found, skipping restore"
            exit 0
          fi

          tz=$(${pkgs.coreutils}/bin/cat "$persist_file")
          if [ -z "$tz" ]; then
            echo "Persisted timezone file is empty, skipping restore"
            exit 0
          fi

          tzfile="${tzdata}/share/zoneinfo/$tz"
          if [ ! -f "$tzfile" ]; then
            echo "Invalid timezone '$tz' in persist file, skipping restore"
            exit 0
          fi

          echo "Restoring timezone: $tz"
          ${pkgs.coreutils}/bin/ln -sf "$tzfile" /etc/localtime

          # Some NixOS setups may generate /etc/timezone as a symlink into the store.
          # Replace it so we don't fail the whole restore.
          ${pkgs.coreutils}/bin/rm -f /etc/timezone
          ${pkgs.coreutils}/bin/printf '%s\n' "$tz" > /etc/timezone
        '';
      };
    };

    # Save timezone whenever it changes
    systemd.services.timezone-persist = lib.mkIf (cfg.persistDir != null) {
      description = "Persist timezone to storage";

      serviceConfig = {
        Type = "oneshot";
        RequiresMountsFor = [ cfg.persistDir ];
        ExecStart = pkgs.writeShellScript "timezone-persist" ''
          set -euo pipefail
          ${pkgs.coreutils}/bin/mkdir -p "${cfg.persistDir}"

          # Try to read timezone from /etc/timezone first, fall back to parsing symlink
          if [ -f /etc/timezone ]; then
            tz=$(${pkgs.coreutils}/bin/cat /etc/timezone | ${pkgs.coreutils}/bin/tr -d '[:space:]')
          else
            target=$(${pkgs.coreutils}/bin/readlink /etc/localtime 2>/dev/null || true)
            if [ -z "$target" ]; then
              echo "Cannot determine timezone, skipping persist"
              exit 0
            fi
            # Extract timezone name from path like /nix/store/.../share/zoneinfo/America/Chicago
            tz=$(echo "$target" | ${pkgs.gnused}/bin/sed -n 's|.*/zoneinfo/||p')
          fi

          if [ -z "$tz" ]; then
            echo "Cannot determine timezone, skipping persist"
            exit 0
          fi

          persist_file="${persistFile}"

          echo "Persisting timezone: $tz"
          echo "$tz" > "$persist_file"
        '';
      };
    };

    # Watch /etc/localtime and /etc/timezone for changes and trigger persist
    systemd.paths.timezone-persist = lib.mkIf (cfg.persistDir != null) {
      description = "Watch timezone changes to persist";
      wantedBy = [ "multi-user.target" ];

      pathConfig = {
        PathChanged = [ "/etc/localtime" "/etc/timezone" ];
        Unit = "timezone-persist.service";
      };
    };

    systemd.services.fix-localtime-symlink = {
      description = "Fix /etc/localtime symlink to be absolute";
      wantedBy = [ "multi-user.target" ];
      after = [ "automatic-timezoned.service" ];
      wants = [ "automatic-timezoned.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "fix-localtime-symlink" ''
          target=$(${pkgs.coreutils}/bin/readlink /etc/localtime 2>/dev/null || true)
          if [ -z "$target" ]; then
            exit 0
          fi

          if [[ "$target" == /* ]]; then
            exit 0
          fi

          abs_target="/etc/$target"
          if [ -e "$abs_target" ]; then
            ${pkgs.coreutils}/bin/ln -sf "$abs_target" /etc/localtime
          fi
        '';
      };

      unitConfig = {
        ConditionPathIsSymbolicLink = "/etc/localtime";
      };
    };

    systemd.paths.fix-localtime-symlink = {
      description = "Watch /etc/localtime for changes";
      wantedBy = [ "multi-user.target" ];

      pathConfig = {
        PathChanged = "/etc/localtime";
        Unit = "fix-localtime-symlink.service";
      };
    };
  };
}
