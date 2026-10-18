# Guest config: settings copied verbatim from hosts/h001/mods/litellm.nix.
{
  config,
  lib,
  pkgs,
  litellmpkgs,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
  pkgsLitellm = import litellmpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  dataDir = "/var/lib/litellm";
  copilotModel =
    mode: m:
    {
      model_name = "copilot-${m}";
      litellm_params.model = "github_copilot/${m}";
    }
    // (if mode == null then { } else { model_info.mode = mode; });
  # Static config as JSON (a YAML subset, which LiteLLM loads fine).
  baseConfig = pkgs.writeText "litellm-base-config.json" (builtins.toJSON config.services.litellm.settings);
  runtimeConfig = "/run/litellm/config.yaml";
  # LiteLLM cannot enumerate OpenRouter models: OpenRouter has no discovery
  # hook, and the remote cost map it relies on currently has no openrouter
  # entries. Fetch the full catalog at start instead and add explicit
  # aliases so every model shows up in /v1/models. If the fetch fails, the
  # proxy still starts; the wildcard keeps routing working.
  renderConfig = pkgs.writeShellScript "litellm-render-config" ''
    set -u
    models=$(${lib.getExe pkgs.curl} -sfL --max-time 30 --retry 3 \
      https://openrouter.ai/api/v1/models \
      | ${lib.getExe pkgs.jq} -c '[.data[].id]') || models='[]'
    ${lib.getExe pkgs.jq} --argjson ids "$models" '
      .model_list += [$ids[] | {
        model_name: "openrouter/\(.)",
        litellm_params: { model: "openrouter/\(.)" }
      }]
    ' ${baseConfig} > ${runtimeConfig}.tmp
    mv ${runtimeConfig}.tmp ${runtimeConfig}
    echo "litellm: added $(${lib.getExe pkgs.jq} length <<<"$models") OpenRouter models"
  '';
in
{
  disabledModules = [ declaration ];
  imports = [ "${litellmpkgs}/nixos/modules/${declaration}" ];
  system.stateVersion = "24.11";

  # The upstream module's tmpfiles `d ${dataDir}/ui` rules would otherwise create
  # dataDir as a real directory on the (tmpfs) container root at boot, and
  # DynamicUser then refuses to start (STATE_DIRECTORY: File exists) because it
  # needs dataDir to be its own symlink into /var/lib/private.
  systemd.tmpfiles.rules = [ "L ${dataDir} - - - - private/litellm" ];

  # copilot models need to reach github; air models reach t on the LAN;
  # the OpenRouter catalog is fetched at start.
  systemd.services.litellm = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStartPre = lib.mkAfter [ renderConfig ];
      ExecStart = lib.mkForce "${lib.getExe config.services.litellm.package} --host \"${config.services.litellm.host}\" --port ${toString config.services.litellm.port} --config ${runtimeConfig}";
    };
  };

  services.litellm = {
    enable = true;
    port = 8094;
    host = "0.0.0.0";
    openFirewall = false;
    package = pkgsLitellm.litellm;
    # gives openrouter key
    environmentFile = "/var/secrets/litellm.env";
    environment = {
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";
      GITHUB_COPILOT_TOKEN_DIR = "${dataDir}/github_copilot";
      XDG_CONFIG_HOME = "${dataDir}/.config";
      # DynamicUser has no $HOME; prisma needs Path.home() at import time.
      HOME = dataDir;
    };
    settings = {
      environment_variables = {
        LITELLM_PROXY_API_KEY = "na";
      };
      litellm_settings = {
        check_provider_endpoints = true;
        drop_params = true;
        modify_params = true;
        max_request_size_mb = 4000;
        max_response_size_mb = 4000;
      };
      model_list = [
        # OpenRouter wildcard: routes any `openrouter/<slug>`. Explicit
        # aliases (so models appear in /v1/models) are generated at start
        # from OpenRouter's catalog; see renderConfig above.
        {
          model_name = "openrouter/*";
          litellm_params = {
            model = "openrouter/*";
          };
        }
      ]
      # Copilot models from ./scripts/probe-copilot-models.sh --nix.
      # Classify from upstream /models supported_endpoints. Chat-only models
      # bridge responses requests; responses-only models bypass chat; models
      # supporting both APIs use LiteLLM's native routing. Embeddings use the
      # /v1/embeddings endpoint.
      ++ (builtins.map (copilotModel "chat") [
        "claude-haiku-4.5"
        "claude-haiku-5.5"
        "claude-opus-4.8"
        "claude-opus-5"
        "claude-opus-5.5"
        "claude-sonnet-5"
        "claude-sonnet-5.5"
        "gemini-3.7-flash"
        "gemini-3.8-flash"
        "gemini-4-argon"
        "kimi-k3"
      ])
      ++ (builtins.map (copilotModel null) [
        "gpt-5-mini"
        "gpt-5.4"
      ])
      ++ (builtins.map (copilotModel "responses") [
        "gpt-5.3-codex"
        "gpt-5.4-mini"
        "gpt-5.5"
        "gpt-5.6-luna"
        "gpt-5.6-sol"
        "gpt-5.6-terra"
        "gpt-6-astra"
        "gpt-6-luna"
        "gpt-6-sol"
        "gpt-6.1-sol"
        "mai-code-1.1-flash"
      ])
      ++ (builtins.map (copilotModel "embedding") [
        "text-embedding-3-small"
        "text-embedding-3-small-inference"
        "text-embedding-ada-002"
      ])
      # 宙 Proxy
      ++ (builtins.map
        (m: {
          model_name = "air-${m}";
          litellm_params = {
            model = "litellm_proxy/${m}";
            api_base = "http://10.12.14.181:9010/air_prd";
            api_key = "na";
            drop_params = true;
            # TODO try this instead of sanitized name
            # additional_drop_params = if [ "messages[*].cacheControl" ];
          };
        })
        # curl -L t:9010/air_prd/models | jq '.data.[].id'
        [
          "BGE-small-en-v1.5-BEI"
          "claude-haiku-4.5"
          "claude-haiku-4-5-20251001"
          "claude-opus-4"
          "claude-opus-4.1"
          "claude-opus-4-1-20250805"
          "claude-opus-4-20250514"
          "claude-opus-4.5"
          "claude-opus-4-5-20251101"
          "claude-opus-4-6"
          "claude-opus-4.6"
          "claude-opus-4-7"
          "claude-opus-4.7"
          "claude-opus-4-8"
          "claude-opus-4.8"
          "claude-opus-5"
          "claude-opus-5-5"
          "claude-opus-5.5"
          "claude-sonnet-4"
          "claude-sonnet-4-20250514"
          "claude-sonnet-4.5"
          "claude-sonnet-4-5-20250929"
          "claude-sonnet-4-6"
          "claude-sonnet-4.6"
          "claude-sonnet-5"
          "claude-sonnet-5-5"
          "claude-sonnet-5.5"
          "deepseek-3.1"
          "deepseek-4.1-flash"
          "deepseek-4-flash-0731"
          "deepseek-4-pro"
          "deepseek-4-pro-0813"
          "gemini-2.5-flash"
          "gemini-2.5-flash-batch"
          "gemini-2.5-flash-image"
          "gemini-2.5-flash-lite"
          "gemini-2.5-pro"
          "gemini-2.5-pro-batch"
          "gemini-2.5-pro-passthrough"
          "gemini-3.1-flash-lite"
          "gemini-3.1-flash-lite-passthrough"
          "gemini-3.5-flash"
          "gemini-3.5-flash-lite"
          "gemini-3.5-flash-passthrough"
          "gemini-3.7-flash"
          "gemini-3.8-flash"
          "gemini-3.8-live"
          "gemini-embedding-001"
          "gemini-embedding-2"
          "gemini-live-2.5-flash-native-audio"
          "glm-4.7"
          "glm-5"
          "glm-5.1"
          "glm-5.2"
          "glm-5.3"
          "glm-5.3-flash"
          "gpt-4.1"
          "gpt-4.1-mini"
          "gpt-4o"
          "gpt-4o-applied-ai"
          "gpt-4o-mini"
          "gpt-5"
          "gpt-5.1"
          "gpt-5.2"
          "gpt-5.4"
          "gpt-5.4-mini"
          "gpt-5.4-nano"
          "gpt-5.5"
          "gpt-5.6-luna"
          "gpt-5.6-luna-oai"
          "gpt-5.6-sol"
          "gpt-5.6-terra"
          "gpt-5-batch"
          "gpt-5-mini"
          "gpt-5-nano"
          "gpt-6.1-sol"
          "gpt-6-astra"
          "gpt-6-luna"
          "gpt-6-sol"
          "gpt-oss-120b"
          "kimi-2.5"
          "kimi-k2.6"
          "kimi-k2.7-code"
          "kimi-k3"
          "minimax-2.5"
          "o3-mini"
          "o4-mini"
          "qwen3-6-35b-a3b-fp8-fm"
          "qwen3-8-2-4t-a95b-fp8-fm"
          "text-embedding-005"
          "text-embedding-3-large"
          "text-embedding-3-small"
          "text-embedding-ada-002"
          "text-embedding-large-exp-03-07"
        ]
      );
    };
  };
}
