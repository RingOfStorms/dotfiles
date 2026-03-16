{
  inputs,
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  declaration = "services/security/oauth2-proxy.nix";
  nixpkgsOauth2Proxy = inputs.oauth2-proxy-nixpkgs;
  pkgsOauth2Proxy = import nixpkgsOauth2Proxy {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.oauth2Proxy;
  zitadel = constants.services.zitadel;
  domain = constants.host.domain;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsOauth2Proxy}/nixos/modules/${declaration}" ];
  config = {
    services.oauth2-proxy = {
      enable = true;
      httpAddress = "http://127.0.0.1:${toString c.port}";
      package = pkgsOauth2Proxy.oauth2-proxy;
      provider = "oidc";
      reverseProxy = true;
      redirectURL = "https://${c.domain}/oauth2/callback";
      validateURL = "https://${zitadel.domain}/oauth2/";
      oidcIssuerUrl = "https://${zitadel.domain}";
      # keyFile injected via secrets-bao configChanges
      nginx.domain = c.domain;
      email.domains = [ "*" ];
      extraConfig = {
        whitelist-domain = "*.${domain}";
        cookie-domain = ".${domain}";
        oidc-groups-claim = "flatRolesClaim";
        # scope = "openid email profiles";

        # pass-access-token = "true";
        # set-authorization-header = "true";
        # pass-user-headers = "true";

        # show-debug-on-error = "true";
        # errors-to-info-log = "true";
      };
      cookie.refresh = "12h";
      # setXauthrequest = true;
    };

    services.nginx.virtualHosts."${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          proxyPass = "http://127.0.0.1:${toString c.port}";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };
  };
}
