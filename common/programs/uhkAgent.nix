{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "uhkAgent"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "uhk agent (ultimate hacking keyboard)";
    };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      uhk-agent
      uhk-udev-rules
    ];
    services.udev.packages = [ pkgs.uhk-udev-rules ];
  };

}
