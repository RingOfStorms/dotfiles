{
  config,
  lib,
  ...
}:
with lib;
{
  config = {
    # Use fail2ban
    services.fail2ban = {
      enable = true;
    };

    # Open ports in the firewall if enabled.
    networking.firewall.allowedTCPPorts = mkIf config.mods.common.sshPortOpen [
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
