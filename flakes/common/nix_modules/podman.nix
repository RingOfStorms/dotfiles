{
  config,
  ...
}:
{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
  };
  users.extraGroups.docker.members = builtins.AttrNames config.users.users;
}
