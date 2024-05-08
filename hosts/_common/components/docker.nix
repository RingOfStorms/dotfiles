{ settings, ... }:
{
  virtualisation.docker.enable = true;
  users.extraGroups.docker.members = [ settings.user.username ];
}
