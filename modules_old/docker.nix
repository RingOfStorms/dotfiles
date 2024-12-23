{
  config,
  lib,
  settings,
  ...
}:
with lib;
let
  name = "docker";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;
    users.extraGroups.docker.members = [ settings.user.username ];
    environment.shellAliases = {
      dockerv = "docker volume";
      dockeri = "docker image";
      dockerc = "docker container";
    };
  };
}
