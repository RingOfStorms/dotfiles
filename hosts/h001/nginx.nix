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
  services.nginx.virtualHosts = {
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
}
