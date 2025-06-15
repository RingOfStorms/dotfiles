{ config, lib, ... }:
let
  ccfg = import ../config.nix;
  cfg = config.${ccfg.custom_config_key}.programs;
in
{
  imports = [
    ./qFlipper.nix
    ./rustDev.nix
    ./uhkAgent.nix
    ./tailnet.nix
    ./ssh.nix
    ./docker.nix
    ./podman.nix
    ./incus.nix
    ./flatpaks.nix
  ];
  config = {
    assertions = [
      (
        let
          enabledVirtualizers = lib.filter (x: x.enabled) [
            {
              name = "docker";
              enabled = cfg.docker.enable;
            }
            {
              name = "podman";
              enabled = cfg.podman.enable;
            }
          ];
        in
        {
          assertion = lib.length enabledVirtualizers <= 1;
          message =
            "Only one virtualizer can be enabled at a time. Enabled: "
            + lib.concatStringsSep ", " (map (x: x.name) enabledVirtualizers);
        }
      )
    ];
  };
}
