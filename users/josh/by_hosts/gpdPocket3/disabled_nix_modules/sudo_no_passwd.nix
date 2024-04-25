{ pkgs, settings, ... }:
{
  security.sudo.extraRules = [
    {
      users = [ settings.user.username ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}

