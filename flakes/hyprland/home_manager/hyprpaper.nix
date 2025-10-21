{
  osConfig,
  lib,
  ...
}:
let
  ccfg = import ../../../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "desktopEnvironment"
    "hyprland"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path osConfig;
in
{
  config = {
    services.hyprpaper = {
      enable = true;
      settings = cfg.hyprpaperSettings;
    };
  };
}
