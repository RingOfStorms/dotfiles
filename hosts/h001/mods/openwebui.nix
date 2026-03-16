{
  inputs,
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  declaration = "services/misc/open-webui.nix";
  nixpkgsOpenWebui = inputs.open-webui-nixpkgs;
  pkgsOpenWebui = import nixpkgsOpenWebui {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  baoSecrets = config.ringofstorms.secretsBao.secrets or {};
  hasOpenwebuiEnv = baoSecrets ? "openwebui_env_2026-03-15";
  c = constants.services.openWebui;
  zitadel = constants.services.zitadel;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsOpenWebui}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    services.nginx.virtualHosts."${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:${toString c.port}";
          extraConfig = ''
            proxy_set_header X-Forwarded-Proto https;
          '';
        };
      };
    };

    services.open-webui = {
      enable = true;
      port = c.port;
      host = "127.0.0.1";
      openFirewall = false;
      package = pkgsOpenWebui.open-webui;
      environmentFile = lib.mkIf hasOpenwebuiEnv baoSecrets."openwebui_env_2026-03-15".path;
      environment = {
        # Declarative config, we don't use admin panel for anything
        # ENABLE_PERSISTENT_CONFIG = "False";
        # ENABLE_OAUTH_PERSISTENT_CONFIG = "False";

        WEBUI_URL = "https://${c.domain}";
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
        OPENID_PROVIDER_URL = "https://${zitadel.domain}/.well-known/openid-configuration";
        OAUTH_PROVIDER_NAME = "SSO";
        OPENID_REDIRECT_URI = "https://${c.domain}/oauth/oidc/callback";
        OAUTH_SCOPES = "openid email profiles";
        ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
        OAUTH_ROLES_CLAIM = "flatRolesClaim";
        OAUTH_ALLOWED_ROLES = "openwebui_user";
        OAUTH_ADMIN_ROLES = "admin";
        # OAUTH_PICTURE_CLAIM = "picture";
        # OAUTH_UPDATE_PICTURE_ON_LOGIN = "True";

        BYPASS_MODEL_ACCESS_CONTROL = "True";

        # Other settings
        CHAT_STREAM_RESPONSE_CHUNK_MAX_BUFFER_SIZE = "10485760";
        REPLACE_IMAGE_URLS_IN_CHAT_RESPONSE = "True";
      };
    };
  };
}
