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
    "docker"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "docker";
    };

  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune.enable = true;
    };
    # TODO add admins?
    users.extraGroups.docker.members = lib.mkIf (users_cfg.primary != null) [ users_cfg.primary ];
    environment.shellAliases = {
      dockerv = "docker volume";
      dockeri = "docker image";
      dockerc = "docker container";
    };
  };
}
