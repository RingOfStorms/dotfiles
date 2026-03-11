{ config, lib, pkgs, ... }:
let
  cacheDir = "/var/lib/timezone-cache";
  cacheFile = "${cacheDir}/last-timezone";

  # Detect whether any impermanence persistence roots are configured.
  # When true, /etc/localtime won't survive reboot, so we need the
  # restore/save services and the fix-var-run-symlink ordering.
  hasImpermanence = (config.environment.persistence or { }) != { };
in
{
  services.dbus.enable = lib.mkDefault true;
  services.geoclue2.enable = true;

  time.timeZone = null;
  services.automatic-timezoned.enable = true;

  systemd.services.automatic-timezoned = {
    after = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ]
      ++ lib.optionals hasImpermanence [ "fix-var-run-symlink.service" ];
    wants = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ]
      ++ lib.optionals hasImpermanence [ "fix-var-run-symlink.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  systemd.services.automatic-timezoned-geoclue-agent = {
    after = [ "dbus.socket" ];
    wants = [ "dbus.socket" ];
  };

  # ── Impermanence-only: restore & save timezone cache ───────────────────
  # On an impermanence system /etc/localtime doesn't survive reboot.
  # restore-timezone re-creates the symlink early at boot from a cached
  # timezone name so the system has the correct timezone immediately,
  # even without internet. save-timezone watches for changes and persists
  # the current timezone name for the next boot.
  systemd.services.restore-timezone = lib.mkIf hasImpermanence {
    description = "Restore timezone from cache";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" "systemd-timedated.service" "automatic-timezoned.service" ];
    after = [ "local-fs.target" ];
    unitConfig.DefaultDependencies = false;
    unitConfig.ConditionPathExists = cacheFile;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "restore-timezone" ''
        tz=$(${pkgs.coreutils}/bin/cat ${cacheFile} 2>/dev/null)
        if [ -z "$tz" ]; then
          exit 0
        fi
        zonefile="/etc/zoneinfo/$tz"
        if [ ! -f "$zonefile" ]; then
          echo "restore-timezone: zone file $zonefile not found, skipping"
          exit 0
        fi
        echo "restore-timezone: restoring timezone to $tz"
        ${pkgs.coreutils}/bin/ln -sf "$zonefile" /etc/localtime
      '';
    };
  };

  systemd.services.save-timezone = lib.mkIf hasImpermanence {
    description = "Save current timezone to cache";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "save-timezone" ''
        ${pkgs.coreutils}/bin/mkdir -p ${cacheDir}
        target=$(${pkgs.coreutils}/bin/readlink -f /etc/localtime 2>/dev/null || true)
        if [ -z "$target" ]; then
          exit 0
        fi
        # Extract timezone name from path (e.g. /nix/store/.../zoneinfo/America/Chicago -> America/Chicago)
        tz=$(echo "$target" | ${pkgs.gnused}/bin/sed -n 's|.*/zoneinfo/||p')
        if [ -n "$tz" ]; then
          echo "$tz" > ${cacheFile}
          echo "save-timezone: saved $tz"
        fi
      '';
    };
  };

  systemd.paths.save-timezone = lib.mkIf hasImpermanence {
    description = "Watch /etc/localtime for timezone changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/etc/localtime";
      Unit = "save-timezone.service";
    };
  };
}
