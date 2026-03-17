{
  constants,
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "chat-ui";
  c = constants.services.chatUi;
  litellm = constants.services.litellm;
  zitadel = constants.services.zitadel;
  hostDataDir = c.dataDir;

  v_port = c.port;

  # chat-ui-db image bundles MongoDB inside the container
  image = "ghcr.io/huggingface/chat-ui-db:latest";

  baoSecrets = config.ringofstorms.secretsBao.secrets or {};
  hasChatUiEnv = baoSecrets ? "chatui_env_2026-03-17";

  # ── Model capability overrides for chat-ui ──────────────────────────
  # chat-ui auto-discovers models from LiteLLM's /models endpoint but
  # that response doesn't include tool/multimodal capability metadata.
  # The MODELS env var (JSON5 array) merges overrides by id.
  #
  # Rather than listing every model, we define capability groups and
  # generate the JSON from Nix.

  # Models that support both tool calling and multimodal (vision)
  toolsAndMultimodal = [
    # Copilot
    "copilot-claude-sonnet-4" "copilot-claude-sonnet-4.5" "copilot-claude-sonnet-4.6"
    "copilot-claude-opus-4.5" "copilot-claude-opus-4.6"
    "copilot-claude-haiku-4.5"
    "copilot-gemini-2.5-pro"
    "copilot-openai-gpt-5.4" "copilot-openai-gpt-5.2" "copilot-openai-gpt-5.1"
    "copilot-openai-gpt-5-mini"
    # Azure
    "azure-gpt-4o-2024-08-06" "azure-gpt-4o-mini-2024-07-18"
    "azure-gpt-4.1-2025-04-14" "azure-gpt-4.1-mini-2025-04-14"
    "azure-gpt-5-2025-08-07" "azure-gpt-5-mini-2025-08-07" "azure-gpt-5-nano-2025-08-07"
    "azure-gpt-5.1-2025-11-13" "azure-gpt-5.2-2025-12-11" "azure-gpt-5.4-2026-03-05"
    "azure-gpt-5.2-low" "azure-gpt-5.2-medium" "azure-gpt-5.2-high"
    "azure-o4-mini-2025-04-16"
    # Air
    "air-gpt-5" "air-gpt-5-mini" "air-gpt-5-nano"
    "air-gpt-5.1" "air-gpt-5.2" "air-gpt-5.4"
    "air-gpt-4.1" "air-gpt-4.1-mini"
    "air-gpt-4o" "air-gpt-4o-mini"
    "air-gemini-2.5-pro" "air-gemini-2.5-pro-passthrough"
    "air-gemini-2.0-flash" "air-gemini-2.5-flash"
    "air-gemini-2.5-flash-image"
    "air-claude-sonnet-4" "air-claude-sonnet-4.5" "air-claude-sonnet-4.6"
    "air-claude-opus-4" "air-claude-opus-4.1" "air-claude-opus-4.5" "air-claude-opus-4.6"
    "air-claude-haiku-4.5"
    "air-claude-3.7-sonnet"
  ];

  # Models that support tools only (no vision)
  toolsOnly = [
    "copilot-claude-sonnet-3.5"
    "azure-o3-mini-2025-01-31"
    "azure-gpt-4o-2024-05-13"
    "air-o3-mini" "air-o4-mini"
    "air-gpt-4o-applied-ai"
    "copilot-openai-gpt-5.2-codex" "copilot-openai-gpt-5.3-codex"
    "copilot-openai-gpt-5.1-codex" "copilot-openai-gpt-5.1-codex-max"
  ];

  # Models that support multimodal only (no tool calling)
  multimodalOnly = [
    "air-gemini-2.0-flash-lite" "air-gemini-2.5-flash-lite"
  ];

  # Models hidden from the UI (not useful for chat)
  unlisted = [
    # Embedding models
    "air-text-embedding-3-small" "air-text-embedding-3-large"
    "air-text-embedding-ada-002"
    "air-text-embedding-large-exp-03-07" "air-text-embedding-005"
    # OpenRouter wildcard (use specific models via other providers instead)
    "openrouter/*"
    # Image generation model — LiteLLM returns images in non-standard `images`
    # field instead of `content` array, so chat-ui can't display them.
    # TODO: revisit when LiteLLM fixes image response format
    "air-gemini-2.5-flash-image"
  ];

  mkOverride = { id, tools ? false, multimodal ? false, unlisted ? false }: {
    inherit id multimodal unlisted;
    supportsTools = tools;
  };

  modelOverrides =
    (map (id: mkOverride { inherit id; tools = true; multimodal = true; }) toolsAndMultimodal)
    ++ (map (id: mkOverride { inherit id; tools = true; multimodal = false; }) toolsOnly)
    ++ (map (id: mkOverride { inherit id; tools = false; multimodal = true; }) multimodalOnly)
    # Hide non-chat models from the UI
    ++ (map (id: mkOverride { inherit id; unlisted = true; }) unlisted);

  modelsJson = builtins.toJSON modelOverrides;
in
{
  virtualisation.oci-containers.containers = {
    "${name}" = {
      inherit image;
      # With --network=host, port mapping is not used.
      # The container listens directly on host port ${toString v_port} via PORT env var.
      # ports = [ "127.0.0.1:${toString v_port}:${toString v_port}" ];
      volumes = [
        "${hostDataDir}/db:/data/db"
      ];
      environment = {
        # Connect to litellm proxy on the host (using localhost since --network=host)
        OPENAI_BASE_URL = "http://127.0.0.1:${toString litellm.port}/v1";
        OPENAI_API_KEY = "na";

        # App settings
        PUBLIC_APP_NAME = "Josh AI";
        PUBLIC_APP_DESCRIPTION = "Chat with AI models";

        # SvelteKit adapter-node port
        PORT = toString v_port;

        # SvelteKit origin — used for OIDC redirect URIs and server-side fetches
        ORIGIN = "https://${c.domain}";
        PUBLIC_ORIGIN = "https://${c.domain}";

        # Body size limit for file uploads (2GB)
        BODY_SIZE_LIMIT = "2147483648";

        # Require authentication on all routes
        AUTOMATIC_LOGIN = "true";

        # Model capability overrides (generated from Nix)
        # Tells chat-ui which models support tool calling and/or multimodal
        MODELS = modelsJson;
      };
      extraOptions = [
        "--network=host"
      ]
      # Inject OIDC secrets env file when available from OpenBao
      # Secret should contain: OPENID_CONFIG, OPENID_CLIENT_ID, OPENID_CLIENT_SECRET, OPENID_SCOPES
      ++ lib.optionals hasChatUiEnv [
        "--env-file=${baoSecrets."chatui_env_2026-03-17".path}"
      ];
    };
  };

  system.activationScripts."${name}_directories" = ''
    mkdir -p ${hostDataDir}/db
    chown 1000:1000 ${hostDataDir}/db
    chmod 755 ${hostDataDir}/db
  '';

  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${toString v_port}";
        extraConfig = ''
          proxy_set_header X-Forwarded-Proto https;
        '';
      };
    };
  };
}
