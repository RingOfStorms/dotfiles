{
  config,
  ...
}:
{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
  };
  users.extraGroups.docker.members = builtins.attrNames config.users.users;
}
