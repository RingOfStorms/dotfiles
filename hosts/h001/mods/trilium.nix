{
  inputs,
  ...
}:
let
  declaration = "services/web-apps/trilium.nix";
  nixpkgs = inputs.trilium-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  config = {
    services.trilium-server = {
      enable = true;
      package = pkgs.trilium-server;
      port = 9111;
      host = "127.0.0.1";
      dataDir = "/var/lib/trilium";
      # NOTE using oauth2-proxy for auth, ensure that is not removed below while keeping this on
      noAuthentication = true;
      instanceName = "joshuabell";
    };

    systemd.services.trilium-server.environment = {
      TRILIUM_NO_UPLOAD_LIMIT = "true";

      # TRILIUM_PUBLIC_URL = "https://notes.joshuabell.xyz";

      # TODO this did not work... sad we use oauth2-proxy instead
      # TRILIUM_OAUTH_BASE_URL = "https://notes.joshuabell.xyz";
      # TRILIUM_OAUTH_CLIENT_ID = "REPLACE";
      # TRILIUM_OAUTH_CLIENT_SECRET = "REPLACE";
      # TRILIUM_OAUTH_ISSUER_BASE_URL = "https://sso.joshuabell.xyz/.well-known/openid-configuration";
      # TRILIUM_OAUTH_ISSUER_NAME = "SSO";
      # TRILIUM_OAUTH_ISSUER_ICON = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/zitadel.svg";
    };

    services.oauth2-proxy.nginx.virtualHosts."notes.joshuabell.xyz" = {
      allowed_groups = [ "notes" ];
    };
    services.nginx.virtualHosts = {
      "notes.joshuabell.xyz" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:9111";
          };
        };
      };
      # TODO revisit, am I going to use the native app or web version
      # this is only needed for the app that can't handle the oauth flow
      "trilium_overlay" = {
        serverName = "h001.net.joshuabell.xyz";
        listen = [
          {
            port = 9112;
            addr = "100.64.0.13";
          }
        ];
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:9111";
          };
        };
      };
    };
  };
}
