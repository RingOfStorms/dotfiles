{
  ...
}:
{
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "admin@joshuabell.xyz";
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      # "172.236.111.33" = {
      #   locations."/" = {
      #     return = "444";
      #   };
      # };
      # "2600:3c06::f03c:95ff:fe1c:84d3" = {
      #   locations."/" = {
      #     return = "444";
      #   };
      # };
      "headscale.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://localhost:8080"; # headscale
        };
      };
      "_" = {
        rejectSSL = true;
        default = true;
        locations."/" = {
          return = "444"; # 404 for not found or 444 for drop
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
  ];
}
