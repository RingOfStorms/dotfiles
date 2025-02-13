{
  ...
}:
{
  security.acme.acceptTerms = true;
  security.acme.email = "admin@joshuabell.xyz";
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      # default that is put first for fallbacks
      # Note that order here doesn't matter it orders alphabetically so `0` puts it first
      # I had an issue tha the first SSL port 443 site would catch any https traffic instead
      # of hitting my default fallback and this fixes that issue and ensure this is hit instead
      "001.linodes.joshuabell.xyz" = {
        default = true;
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          return = "444"; # 404 for not found or 444 for drop
        };
      };
      "172.236.111.33" = {
        locations."/" = {
          return = "444";
        };
      };
      "2600:3c06::f03c:95ff:fe1c:84d3" = {
        locations."/" = {
          return = "444";
        };
      };

      "headscale.joshuabell.xyz" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://localhost:8080"; # headscale
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # web http
    443 # web https
  ];
}
