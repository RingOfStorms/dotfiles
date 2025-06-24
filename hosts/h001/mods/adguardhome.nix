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
      53
      67
      68
      5543
      3000
    ];
    networking.firewall.allowedUDPPorts = [
      53
      67
      68
      784
      853
      8853
      5443
    ];
  };
}
