{ lib, pkgs, ... }:
{
  services.dbus.enable = lib.mkDefault true;
  services.geoclue2.enable = true;

  time.timeZone = null;
  services.automatic-timezoned.enable = true;

  systemd.services.automatic-timezoned = {
    after = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ];
    wants = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" ];
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
}
