{
  upkgs,
  inputs,
  config,
  ...
}:
{
  # Use unstable services
  disabledModules = [
    "services/misc/open-webui.nix"
    "services/misc/litellm.nix"
  ];
  imports = [
    "${inputs.nixpkgs-unstable}/nixos/modules/services/misc/open-webui.nix"
    "${inputs.nixpkgs-unstable}/nixos/modules/services/misc/litellm.nix"
  ];

  options = { };
  config = {
    services.nginx.virtualHosts."chat.joshuabell.xyz" = {
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
      package = upkgs.open-webui;
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

    services.litellm = {
      enable = true;
      port = 8094;
      openFirewall = false;
      package = upkgs.litellm;
      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        GITHUB_COPILOT_TOKEN_DIR = "/var/lib/litellm/github_copilot";
        XDG_CONFIG_HOME = "/var/lib/litellm/.config";
      };
      settings = {
        model_list = [
          # existing
          {
            model_name = "GPT-5";
            litellm_params = {
              model = "azure/gpt-5-2025-08-07";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-5-mini";
            litellm_params = {
              model = "azure/gpt-5-mini-2025-08-07";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-5-nano";
            litellm_params = {
              model = "azure/gpt-5-nano-2025-08-07";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-5-codex";
            litellm_params = {
              model = "azure/gpt-5-codex-2025-09-15";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-4.1";
            litellm_params = {
              model = "azure/gpt-4.1-2025-04-14";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-4.1-mini";
            litellm_params = {
              model = "azure/gpt-4.1-mini-2025-04-14";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "GPT-4o";
            litellm_params = {
              model = "azure/gpt-4o-2024-05-13";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }
          {
            model_name = "dall-e-3-3.0";
            litellm_params = {
              model = "azure/dall-e-3-3.0";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          }

          # Copilot
          {
            model_name = "copilot-claude-sonnet-4";
            litellm_params = {
              model = "github_copilot/claude-sonnet-4";
              extra_headers = {
                "editor-version" = "vscode/1.85.1";
                "Copilot-Integration-Id" = "vscode-chat";
                "user-agent" = "GithubCopilot/1.155.0";
                "editor-plugin-version" = "copilot/1.155.0";
              };
            };
          }
        ];
      };
    };
  };
}
