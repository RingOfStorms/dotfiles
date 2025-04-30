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

    services.nginx = {
      virtualHosts = {
        "h001.net.joshuabell.xyz  " = {
          locations."/" = {
            proxyPass = "http://localhost:3000";
          };
        };
      };
    };
  };
}
