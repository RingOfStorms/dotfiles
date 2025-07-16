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
    "opencode"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "opencode";
    };

  config = lib.mkIf cfg.enable ({
    

    environment.systemPackages = with pkgs; [
      opencode
    ];

    environment.shellAliases = {
      "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
    };
  });
}
