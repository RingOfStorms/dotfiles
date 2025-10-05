{ upkgs, config, ... }:
{
  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://127.0.0.1:4180";
    package = upkgs.oauth2-proxy;
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
    cookie.refresh = "30m";
    # setXauthrequest = true;
  };

  services.nginx.virtualHosts."sso-proxy.joshuabell.xyz" = {
    locations = {
      "/" = {
        proxyWebsockets = true;
        recommendedProxySettings = true;
        proxyPass = "http://127.0.0.1:4180";
      };
    };
  };
}
