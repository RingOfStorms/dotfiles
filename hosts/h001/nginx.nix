{
  config,
  lib,
  constants,
  fleet,
  ...
}:
let
  c = constants.host;
  domain = fleet.global.domain;
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
    defaults.email = fleet.global.acmeEmail;
    certs."${domain}" = {
      inherit domain;
      extraDomainNames = [ "*.${domain}" ];
      # credentialFiles.LINODE_TOKEN_FILE injected via secrets-bao configChanges
      dnsProvider = "linode";
      group = "nginx";
    };
  };

  # nginx listens on overlay IP, needs tailscale interface up.
  # tailscaled-autoconnect.service (Type=notify) only finishes once `tailscale up`
  # has returned and tailscale0 has its address; tailscaled.service alone is just
  # the daemon being started and races nginx's bind. IPFreeBind=true also lets
  # nginx bind to addresses not yet on any interface as belt-and-suspenders.
  systemd.services.nginx = {
    wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
    after = [ "network-online.target" "tailscaled-autoconnect.service" ];
    serviceConfig.IPFreeBind = true;
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "500m";
    appendHttpConfig = ''
      proxy_headers_hash_max_size 1024;
    '';
    virtualHosts = {
      "${c.lanIp}" = {
        locations = {
          "/" = {
            return = "301 http://h001.local.${domain}";
          };
        };
      };
      "h001.local.${domain}" = {
        locations = {
          "/" = homepage;
        };
      };
      "${c.overlayIp}" = {
        locations."/" = {
          return = "301 http://h001.net.${domain}";
        };
      };
      "h001.net.${domain}" = {
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
