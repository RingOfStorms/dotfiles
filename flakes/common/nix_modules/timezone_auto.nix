{ lib, ... }:
{
  services.dbus.enable = lib.mkDefault true;
  services.geoclue2.enable = true;

  time.timeZone = null;
  services.automatic-timezoned.enable = true;

  systemd.services.automatic-timezoned = {
    after = [ "dbus.socket" "systemd-timedated.service" ];
    wants = [ "dbus.socket" "systemd-timedated.service" ];
  };

  systemd.services.automatic-timezoned-geoclue-agent = {
    after = [ "dbus.socket" ];
    wants = [ "dbus.socket" ];
  };
}
