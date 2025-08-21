{
  config,
  lib,
  ...
}:
let
  name = "open-webui";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.4";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::4";
in
{
  options = { };
  config = {
    services.nginx.virtualHosts."chat.joshuabell.xyz" = {
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://${containerAddress}:8080";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };

    containers.${name} = {
      # ephemeral = true; # Trying out a non ephemeral container setup...
      autoStart = true;
      privateNetwork = true;
      hostAddress = hostAddress;
      localAddress = containerAddress;
      hostAddress6 = hostAddress6;
      localAddress6 = containerAddress6;
      config =
        { config, pkgs, ... }:
        {
          system.stateVersion = "25.05";

          networking = {
            firewall = {
              enable = true;
            };
            # Use systemd-resolved inside the container
            # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
            useHostResolvConf = lib.mkForce false;
          };
          services.resolved.enable = true;

          services.open-webui = {
            enable = true;
            port = 8080;
            host = "::";
            openFirewall = true;
            environment = {
              # Declarative config, we don't use admin panel for anything
              ENABLE_PERSISTENT_CONFIG = false;
              ENABLE_OAUTH_PERSISTENT_CONFIG = false;

              WEBUI_URL = "https://chat.joshuabell.xyz";
              CUSTOM_NAME = "Josh AI";
              ENV = "prod";

              ENABLE_SIGNUP = false;
              ENABLE_LOGIN_FORM = false;
              ENABLE_OAUTH_SIGNUP = true;
              WEBUI_SESSION_COOKIE_SAME_SITE = "lax";
              # OAUTH_SUB_CLAIM = "";
              # OAUTH_UPDATE_PICTURE_ON_LOGIN = true;
              # OAUTH_PICTURE_CLAIM = "";
              # WEBUI_AUTH_TRUSTED_EMAIL_HEADER
              OAUTH_CLIENT_ID = "334366065716953091";
              OAUTH_CLIENT_SECRET = "";
              OPENID_PROVIDER_URL = "https://sso.joshuabell.xyz/.well-known/openid-configuration";
              # OAUTH_PROVIDER_NAME = "";
              # OAUTH_SCOPES = "";
              # OPENID_REDIRECT_URI = "https://chat.joshuabell.xyz/oauth/oidc/callback";
            };
          };
        };
    };
  };
}
