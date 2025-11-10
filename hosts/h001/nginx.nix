{
  config,
  lib,
  ...
}:
let
  homarr = {
    proxyWebsockets = true;
    proxyPass = "http://localhost:7575";
  };
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  # TODO transfer these to o001 to use same certs?
  # Will I ever get rate limited by lets encrypt with both doing their own?
  security.acme = lib.mkIf (hasSecret "linode_rw_domains") {
    acceptTerms = true;
    defaults.email = "admin@joshuabell.xyz";
    certs."joshuabell.xyz" = {
      domain = "joshuabell.xyz";
      extraDomainNames = [ "*.joshuabell.xyz" ];
      credentialFiles = {
        LINODE_TOKEN_FILE = config.age.secrets.linode_rw_domains.path;
      };
      dnsProvider = "linode";
      group = "nginx";
    };
  };

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

      "_" = {
        rejectSSL = true;
        default = true;
        locations."/" = {
          return = "444"; # 404 for not found or 444 for drop
        };
      };
    };
  };
}
