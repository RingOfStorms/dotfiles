{ config, lib, ... }:
let
  # The `systemd.sleep.extraConfig` option was removed in NixOS 26.05 in favor
  # of `systemd.sleep.settings`. This is tied to the nixpkgs release, NOT the
  # host's stateVersion (which we intentionally don't bump on existing hosts).
  useNewApi = lib.versionAtLeast config.system.nixos.release "26.05";
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
