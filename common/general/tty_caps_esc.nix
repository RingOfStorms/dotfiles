{
  lib,
  pkgs,
  config,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "general"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      ttyCapsEscape = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable caps for escape key";
      };
    };
  config = lib.mkIf cfg.ttyCapsEscape {
    services.xserver.xkb.options = "caps:escape";
    console = {
      earlySetup = true;
      packages = with pkgs; [ terminus_font ];
      useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
    };
  };
}
