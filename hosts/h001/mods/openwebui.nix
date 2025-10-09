{
  inputs,
  config,
  ...
}:
let
  declaration = "services/misc/open-webui.nix";
  nixpkgs = inputs.open-webui-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    services.nginx.virtualHosts."chat.joshuabell.xyz" = {
      # enableACME = true;
      # forceSSL = true;
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:8084";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };

    services.open-webui = {
      enable = true;
      port = 8084;
      host = "127.0.0.1";
      openFirewall = false;
      package = pkgs.open-webui;
      environmentFile = config.age.secrets.openwebui_env.path;
      environment = {
        # Declarative config, we don't use admin panel for anything
        # ENABLE_PERSISTENT_CONFIG = "False";
        # ENABLE_OAUTH_PERSISTENT_CONFIG = "False";

        WEBUI_URL = "https://chat.joshuabell.xyz";
        CUSTOM_NAME = "Josh AI";
        ENV = "prod";

        ENABLE_SIGNUP = "False";
        ENABLE_LOGIN_FORM = "False";
        ENABLE_OAUTH_SIGNUP = "True";
        WEBUI_SESSION_COOKIE_SAME_SITE = "lax";
        # OAUTH_SUB_CLAIM = "";
        # WEBUI_AUTH_TRUSTED_EMAIL_HEADER

        # https://self-hosted.tools/p/openwebui-with-zitadel-oidc/
        # OAUTH_CLIENT_ID = ""; provided in the secret file
        # OAUTH_CLIENT_SECRET = "";
        OPENID_PROVIDER_URL = "https://sso.joshuabell.xyz/.well-known/openid-configuration";
        OAUTH_PROVIDER_NAME = "SSO";
        OPENID_REDIRECT_URI = "https://chat.joshuabell.xyz/oauth/oidc/callback";
        OAUTH_SCOPES = "openid email profiles";
        ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
        OAUTH_ROLES_CLAIM = "flatRolesClaim";
        OAUTH_ALLOWED_ROLES = "openwebui_user";
        OAUTH_ADMIN_ROLES = "admin";
        # OAUTH_PICTURE_CLAIM = "picture";
        # OAUTH_UPDATE_PICTURE_ON_LOGIN = "True";
      };
    };
  };
}
