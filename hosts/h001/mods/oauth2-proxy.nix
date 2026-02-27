{
  inputs,
  config,
  pkgs,
  lib,
  ...
}:
let
  declaration = "services/security/oauth2-proxy.nix";
  nixpkgsOauth2Proxy = inputs.oauth2-proxy-nixpkgs;
  pkgsOauth2Proxy = import nixpkgsOauth2Proxy {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsOauth2Proxy}/nixos/modules/${declaration}" ];
  config = lib.mkIf (hasSecret "oauth2_proxy_key_file") {
    services.oauth2-proxy = {
      enable = true;
      httpAddress = "http://127.0.0.1:4180";
      package = pkgsOauth2Proxy.oauth2-proxy;
      provider = "oidc";
      reverseProxy = true;
      redirectURL = "https://sso-proxy.joshuabell.xyz/oauth2/callback";
      validateURL = "https://sso.joshuabell.xyz/oauth2/";
      oidcIssuerUrl = "https://sso.joshuabell.xyz";
      keyFile = config.age.secrets.oauth2_proxy_key_file.path;
      nginx.domain = "sso-proxy.joshuabell.xyz";
      email.domains = [ "*" ];
      extraConfig = {
        whitelist-domain = "*.joshuabell.xyz";
        cookie-domain = ".joshuabell.xyz";
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

    services.nginx.virtualHosts."sso-proxy.joshuabell.xyz" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          proxyPass = "http://127.0.0.1:4180";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };
  };
}
