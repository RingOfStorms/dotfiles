{
  inputs,
  pkgs,
  constants,
  ...
}:
let
  declaration = "services/web-apps/trilium.nix";
  nixpkgsTrilium = inputs.trilium-nixpkgs;
  pkgsTrilium = import nixpkgsTrilium {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.trilium;
  overlayIp = constants.host.overlayIp;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsTrilium}/nixos/modules/${declaration}" ];
  config = {
    services.trilium-server = {
      enable = true;
      package = pkgsTrilium.trilium-server;
      port = c.port;
      host = "127.0.0.1";
      dataDir = c.dataDir;
      # NOTE using oauth2-proxy for auth, ensure that is not removed below while keeping this on
      noAuthentication = true;
      instanceName = "joshuabell";
    };

    systemd.services.trilium-server.environment = {
      TRILIUM_NO_UPLOAD_LIMIT = "true";

      # TRILIUM_PUBLIC_URL = "https://${c.domain}";

      # TODO this did not work... sad we use oauth2-proxy instead
      # TRILIUM_OAUTH_BASE_URL = "https://${c.domain}";
      # TRILIUM_OAUTH_CLIENT_ID = "REPLACE";
      # TRILIUM_OAUTH_CLIENT_SECRET = "REPLACE";
      # TRILIUM_OAUTH_ISSUER_BASE_URL = "https://sso.joshuabell.xyz/.well-known/openid-configuration";
      # TRILIUM_OAUTH_ISSUER_NAME = "SSO";
      # TRILIUM_OAUTH_ISSUER_ICON = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/zitadel.svg";
    };

    services.oauth2-proxy.nginx.virtualHosts."${c.domain}" = {
      allowed_groups = [ "notes" ];
    };
    services.nginx.virtualHosts = {
      "${c.domain}" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations = {
          "/" = {
            proxyWebsockets = true;
            proxyPass = "http://127.0.0.1:${toString c.port}";
          };
        };
      };
      "${c.blogDomain}" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations = {
          "/share" = {
            proxyWebsockets = true;
            proxyPass = "http://127.0.0.1:${toString c.port}";
            extraConfig = ''
              auth_request off;
            '';
          };
          "/assets" = {
            proxyPass = "http://127.0.0.1:${toString c.port}";
            extraConfig = ''
              auth_request off;
            '';
          };
        };
      };
      # TODO revisit, am I going to use the native app or web version
      # this is only needed for the app that can't handle the oauth flow
      "trilium_overlay" = {
        serverName = "h001.net.joshuabell.xyz";
        listen = [
          {
            port = c.overlayPort;
            addr = overlayIp;
          }
        ];
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:${toString c.port}";
          };
        };
      };
    };
  };
}
