{
  ...
}:
let
  homarr = {
    proxyWebsockets = true;
    proxyPass = "http://localhost:7575";
  };
in
{
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "admin@joshuabell.xyz";
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    virtualHosts = {
      "10.12.14.10" = {
        locations = {
          "/" = {
            return = "301 http://h001.local.joshuabell.xyz";
          };
        };
      };
      "h001.local.joshuabell.xyz" = {
        locations = {
          "/" = homarr;
        };
      };
      "100.64.0.13" = {
        locations."/" = {
          return = "301 http://h001.net.joshuabell.xyz";
        };
      };
      "h001.net.joshuabell.xyz" = {
        locations = {
          "/grafana/" = {
            proxyPass = "http://localhost:3001";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
          "/" = homarr;
        };
      };
    };
  };
}
