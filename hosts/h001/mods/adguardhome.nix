{
  ...
}:
{
  config = {
    services.adguardhome = {
      enable = true;
      allowDHCP = true;
      openFirewall = false;
    };

    networking.firewall.allowedTCPPorts = [
      53 # DNS
      68 # DHCP
      5543 # DNSCrypt
      # 3000 # Initial installation
      80 # admin panel
      443 # admin panel
      853 # DNS over tls
      # 6060 # Debugging profile
    ];
    networking.firewall.allowedUDPPorts = [
      53 # DNS
      # 67 # DHCP
      # 68 # DHCP
      443 # Admin panel/https dns over https
      853 # DNS over quic
      5443 # DNSCrypt
    ];
  };
}
