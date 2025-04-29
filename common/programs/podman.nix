{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "podman"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "podman";
    };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerSocket.enable = true;
      autoPrune.enable = true;
    };
    # TODO add admins?
    users.extraGroups.podman.members = lib.mkIf (users_cfg.primary != null) [ users_cfg.primary ];
  };
}
