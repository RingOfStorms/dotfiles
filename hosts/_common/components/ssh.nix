{ ... }:
{
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    22 # sshd
  ];
}
