{ settings, ... }:
{
  virtualisation.docker.enable = true;
  users.extraGroups.docker.members = [ settings.user.username ];
  environment.shellAliases = {
    dockerv = "docker volume";
    dockeri = "docker image";
    dockerc = "docker container";
  };
}
