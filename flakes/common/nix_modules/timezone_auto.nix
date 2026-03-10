{ lib, pkgs, ... }:
{
  services.dbus.enable = lib.mkDefault true;
  services.geoclue2.enable = true;

  time.timeZone = null;
  services.automatic-timezoned.enable = true;

  systemd.services.automatic-timezoned = {
    after = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" "fix-var-run-symlink.service" ];
    wants = [ "dbus.socket" "systemd-timedated.service" "geoclue.service" "fix-var-run-symlink.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  systemd.services.automatic-timezoned-geoclue-agent = {
    after = [ "dbus.socket" ];
    wants = [ "dbus.socket" ];
  };
}
