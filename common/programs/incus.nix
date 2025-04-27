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
    "incus"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "incus";
    };

  config = lib.mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;
      agent.enable = true;
      ui.enable = true;
    };

    users.extraGroups.incus_admin.members = lib.mkIf (users_cfg.primary != null) [ users_cfg.primary ];
    users.extraGroups.incus.members = lib.mkIf (users_cfg.primary != null) [ users_cfg.primary ];
  };
}
