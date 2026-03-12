{ config, lib, ... }:
let
  useNewApi = lib.versionAtLeast config.system.stateVersion "26.05";
in
{
  # Turn off sleep
  systemd.sleep = if useNewApi then {
    settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowSuspendThenHibernate = "no";
      AllowHybridSleep = "no";
    };
  } else {
    extraConfig = ''
      [Sleep]
      AllowSuspend=no
      AllowHibernation=no
      AllowSuspendThenHibernate=no
      AllowHybridSleep=no
    '';
  };
}
