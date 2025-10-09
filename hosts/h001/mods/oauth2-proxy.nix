{
  inputs,
  config,
  ...
}:
let
  declaration = "services/security/oauth2-proxy.nix";
  nixpkgs = inputs.oauth2-proxy-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  config = {
    services.oauth2-proxy = {
      enable = true;
      httpAddress = "http://127.0.0.1:4180";
      package = pkgs.oauth2-proxy;
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
      # enableACME = true;
      # forceSSL = true;
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
