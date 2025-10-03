{ config, ... }:
{
  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://127.0.0.1:4180";
    # package = pkgsUnstable.oauth2-proxy;
    provider = "oidc";
    reverseProxy = true;
    redirectURL = "https://sso-proxy.joshuabell.xyz/oauth2/callback";
    validateURL = "https://sso.joshuabell.xyz/oauth2/";
    oidcIssuerUrl = "https://sso.joshuabell.xyz:443";
    keyFile = config.age.secrets.oauth2_key_file.path;
    nginx.domain = "sso-proxy.joshuabell.xyz";
    email.domains = [ "*" ];
    # extraConfig = {
    #   whitelist-domain = ".joshuabell.xyz";
    #   cookie-domain = ".joshuabell.xyz";
    # };
  };

  services.nginx.virtualHosts."sso-proxy.joshuabell.xyz" = {
    locations = {
      "/" = {
        proxyWebsockets = true;
        recommendedProxySettings = true;
        proxyPass = "http://127.0.0.1:4180";
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto https;
        '';
      };
    };
  };

}
