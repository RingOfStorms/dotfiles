{ ... }:
{
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
}
