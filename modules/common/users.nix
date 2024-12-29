{
  lib,
  config,
  ...
}:
with lib;
{
  config = {
    users.users = mapAttrs (
      name: config:
      {
        inherit name;
      }
      // config
    ) config.mods.common.users;
  };
}
