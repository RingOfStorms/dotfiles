{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.mods.common;
in
{
  config = mkIf cfg.docker {
    virtualisation.docker.enable = true;
    users.extraGroups.docker.members = [ config.mods.common.primaryUser ];
    environment.shellAliases = {
      dockerv = "docker volume";
      dockeri = "docker image";
      dockerc = "docker container";
    };
  };
}
