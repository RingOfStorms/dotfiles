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

    # networking = {
    #   interfaces = {
    #     enp0s31f6 = {
    #       useDHCP = true;
    #       ipv4.addresses = [
    #         {
    #           address = "10.12.14.2";
    #           prefixLength = 24;
    #         }
    #       ];
    #     };
    #   };
    # };

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
