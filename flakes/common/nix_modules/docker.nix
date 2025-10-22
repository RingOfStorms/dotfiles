{
  config,
  ...
}:

{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };
  users.extraGroups.docker.members = builtins.attrNames config.users.users;
  environment.shellAliases = {
    dockerv = "docker volume";
    dockeri = "docker image";
    dockerc = "docker container";
  };
}
