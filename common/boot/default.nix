{ config, lib, ... }:
let
  ccfg = import ../config.nix;
  cfg = config.${ccfg.custom_config_key}.boot;
in
{
  imports = [
    ./grub.nix
    ./systemd.nix
  ];
  config = {
    assertions = [
      (
        let
          enabledBootloaders = lib.filter (x: x.enabled) [
            {
              name = "systemd";
              enabled = cfg.systemd.enable;
            }
            {
              name = "grub";
              enabled = cfg.grub.enable;
            }
          ];
        in
        {
          assertion = lib.length enabledBootloaders <= 1;
          message =
            "Only one bootloader can be enabled at a time. Enabled: "
            + lib.concatStringsSep ", " (map (x: x.name) enabledBootloaders);
        }
      )
    ];
  };
}
