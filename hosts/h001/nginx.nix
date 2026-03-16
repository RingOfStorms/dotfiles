{
  config,
  lib,
  constants,
  ...
}:
let
  c = constants.host;
  homepagePort = constants.services.homepage.port;
  homepage = {
    proxyWebsockets = true;
    proxyPass = "http://localhost:${toString homepagePort}";
  };
in
{
  # TODO transfer these to o001 to use same certs?
  # Will I ever get rate limited by lets encrypt with both doing their own?
  security.acme = {
    acceptTerms = true;
    defaults.email = c.acmeEmail;
    certs."${c.domain}" = {
      domain = c.domain;
      extraDomainNames = [ "*.${c.domain}" ];
      # credentialFiles.LINODE_TOKEN_FILE injected via secrets-bao configChanges
      dnsProvider = "linode";
      group = "nginx";
    };
  };

  # nginx listens on overlay IP, needs tailscale interface up
  systemd.services.nginx = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    virtualHosts = {
      "${c.lanIp}" = {
        locations = {
          "/" = {
            return = "301 http://h001.local.${c.domain}";
          };
        };
      };
      "h001.local.${c.domain}" = {
        locations = {
          "/" = homepage;
        };
      };
      "${c.overlayIp}" = {
        locations."/" = {
          return = "301 http://h001.net.${c.domain}";
        };
      };
      "h001.net.${c.domain}" = {
        locations = {
          "/" = homepage;
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
