{
  inputs,
  config,
  pkgs,
  lib,
  constants,
  fleet,
  ...
}:
let
  declaration = "services/misc/open-webui.nix";
  nixpkgsOpenWebui = inputs.open-webui-nixpkgs;
  pkgsOpenWebui = import nixpkgsOpenWebui {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
    overlays = [
      (_: prev: {
        python314Packages = prev.python314Packages.overrideScope (
          _: pythonPrev: {
            # frictionless 5.18.1's upstream suite is incompatible with the
            # current pandas/NumPy/charset-normalizer combination in unstable.
            # Its runtime dependencies still build; omit only its failing tests.
            frictionless = pythonPrev.frictionless.overridePythonAttrs (_: {
              doCheck = false;
            });
          }
        );
      })
    ];
  };
  hasOpenwebuiEnv = true;
  openwebuiEnvPath = "${fleet.global.secretsDir}/openwebui_env_2026-03-15";
  c = constants.services.openWebui;
  litellm = constants.services.litellm;
  searx = constants.services.searx;
  penpot = constants.services.penpot;
  zitadel = constants.services.zitadel;
  openaiBaseUrl = "http://127.0.0.1:${toString litellm.port}/v1";
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsOpenWebui}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    services.nginx.virtualHosts."${c.domain}" = {
      addSSL = true;
      sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
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

    systemd.services.open-webui = {
      after = [ "litellm.service" "searx.service" ];
      wants = [ "litellm.service" "searx.service" ];
    };

    services.open-webui = {
      enable = true;
      port = c.port;
      host = "127.0.0.1";
      openFirewall = false;
      package = pkgsOpenWebui.open-webui;
      environmentFile = openwebuiEnvPath;
      environment = {
        # Keep all ConfigVar settings below declarative; admin-UI changes vanish
        # after restart instead of overriding this configuration.
        ENABLE_PERSISTENT_CONFIG = "False";
        ENABLE_OAUTH_PERSISTENT_CONFIG = "False";

        WEBUI_URL = "https://${c.domain}";
        WEBUI_NAME = "Josh AI";
        ENV = "prod";

        # NLTK, newly imported through LangChain, requires a usable home
        # directory even before it downloads any data. DynamicUser has none.
        HOME = "/var/lib/open-webui";

        # Connect to LiteLLM proxy for all OpenAI-compatible APIs.
        OPENAI_API_BASE_URL = openaiBaseUrl;
        OPENAI_API_KEY = "na";
        # Disable Ollama (not running on this host).
        OLLAMA_BASE_URL = "";
        ENABLE_OLLAMA_API = "False";

        # SSO is the only password-capable authentication path.
        ENABLE_SIGNUP = "False";
        ENABLE_LOGIN_FORM = "False";
        ENABLE_PASSWORD_AUTH = "False";
        ENABLE_PASSWORD_CHANGE_FORM = "False";
        ENABLE_OAUTH_SIGNUP = "True";
        WEBUI_SESSION_COOKIE_SAME_SITE = "lax";

        # OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET are in the OpenBao env file.
        OPENID_PROVIDER_URL = "https://${zitadel.domain}/.well-known/openid-configuration";
        OAUTH_PROVIDER_NAME = "SSO";
        OPENID_REDIRECT_URI = "https://${c.domain}/oauth/oidc/callback";
        OAUTH_SCOPES = "openid email profile";
        ENABLE_OAUTH_ROLE_MANAGEMENT = "True";
        OAUTH_ROLES_CLAIM = "flatRolesClaim";
        OAUTH_ALLOWED_ROLES = "openwebui_user";
        OAUTH_ADMIN_ROLES = "admin";

        # All SSO-authorized users can select every model.
        BYPASS_MODEL_ACCESS_CONTROL = "True";

        # Use the loopback-only SearXNG instance for web search.
        ENABLE_WEB_SEARCH = "True";
        ENABLE_WEB_SEARCH_CONFIRMATION = "True";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://127.0.0.1:${toString searx.port}/search?q=<query>&format=json";
        WEB_SEARCH_RESULT_COUNT = "5";
        WEB_SEARCH_CONCURRENT_REQUESTS = "2";
        WEB_LOADER_CONCURRENT_REQUESTS = "2";
        WEB_LOADER_TIMEOUT = "15";

        # Route OpenAI-compatible image generation through LiteLLM.
        ENABLE_IMAGE_GENERATION = "True";
        IMAGE_GENERATION_ENGINE = "openai";
        IMAGE_GENERATION_MODEL = "air-gemini-2.5-flash-image";
        IMAGES_OPENAI_API_BASE_URL = openaiBaseUrl;
        IMAGES_OPENAI_API_KEY = "na";
        IMAGE_SIZE = "1024x1024";

        # Seed Penpot's private Streamable HTTP MCP server. In multi-user mode,
        # tool calls require a matching Penpot browser plugin session.
        TOOL_SERVER_CONNECTIONS = builtins.toJSON [
          {
            type = "mcp";
            url = "http://${constants.host.overlayIp}:${toString penpot.mcpServerPort}/mcp";
            path = "";
            auth_type = "none";
            key = "";
            config = {
              enable = true;
              function_name_filter_list = "";
              access_grants = [ ];
            };
            info = {
              id = "penpot";
              name = "Penpot";
              description = "Penpot design tools";
            };
          }
        ];
        MCP_INITIALIZE_TIMEOUT = "30";

        CHAT_STREAM_RESPONSE_CHUNK_MAX_BUFFER_SIZE = "20971520";
        REPLACE_IMAGE_URLS_IN_CHAT_RESPONSE = "True";
      };
    };
  };
}
