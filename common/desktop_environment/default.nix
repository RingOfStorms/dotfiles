{ config, lib, ... }:
let
  ccfg = import ../config.nix;
  cfg = config.${ccfg.custom_config_key}.desktopEnvironment;
in
{
  imports = [
    ./gnome
    ./hyprland
  ];
  config = {
    assertions = [
      (
        let
          enabledDEs = lib.filter (x: x.enabled) [
            {
              name = "gnome";
              enabled = cfg.gnome.enable;
            }
            {
              name = "hyprland";
              enabled = cfg.hyprland.enable;
            }
          ];
        in
        {
          assertion = lib.length enabledDEs <= 1;
          message =
            "Only one desktop environment can be enabled at a time. Enabled: "
            + lib.concatStringsSep ", " (map (x: x.name) enabledDEs);
        }
      )
    ];
  };
}
