{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
with lib;
let
  name = "ssh";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    # Use fail2ban
    services.fail2ban = {
      enable = true;
    };

    # Open ports in the firewall.
    networking.firewall.allowedTCPPorts = [
      22 # sshd
    ];

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings = {
        LogLevel = "VERBOSE";
        PermitRootLogin = "yes";
      };
    };
  };
}
