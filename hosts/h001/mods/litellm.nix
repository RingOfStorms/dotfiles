{
  inputs,
  pkgs,
  constants,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
  nixpkgsLitellm = inputs.litellm-nixpkgs;
  pkgsLitellm = import nixpkgsLitellm {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.litellm;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsLitellm}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    networking.firewall.enable = true;
    # Expose litellm to my overlay network as well
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

    # Ensure litellm starts after DNS / network-online is up.
    # (copilot models need to reach github; air/azure models reach the t
    # machine on the LAN — no overlay dep anymore.)
    systemd.services.litellm = {
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ];
    };

    services.litellm = {
      enable = true;
      port = c.port;
      host = "0.0.0.0";
      openFirewall = false;
      package = pkgsLitellm.litellm;
      # gives openrouter key
      environmentFile = "/var/lib/openbao-secrets/litellm-env";
      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        GITHUB_COPILOT_TOKEN_DIR = "${c.dataDir}/github_copilot";
        XDG_CONFIG_HOME = "${c.dataDir}/.config";
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
          # OpenRouter
          {
            model_name = "openrouter/*";
            litellm_params = {
              model = "openrouter/*";
            };
          }
        ]
        # Copilot
        # Probed with: ./scripts/probe-copilot-models.sh --nix
        #
        # Claude / Gemini / Grok models on Copilot Business do NOT support the
        # /responses endpoint — only /chat/completions. Tagging them with
        # `mode = "chat"` tells litellm to bridge MVA's /v1/responses requests
        # down to /chat/completions upstream instead of forwarding 1:1 (which
        # gets a 400 "unsupported_api_for_model" from githubcopilot).
        ++ (builtins.map
          (m: let
            # responses-only: codex variants and gpt-5.4+
            isResponsesOnly =
              (builtins.match ".*codex.*" m != null)
              || (builtins.match "gpt-5\\.4.*" m != null);
            # chat-only on Copilot: claude-*, gemini-*, grok-*, embeddings
            isChatOnly =
              (builtins.match "claude-.*" m != null)
              || (builtins.match "gemini-.*" m != null)
              || (builtins.match "grok-.*" m != null)
              || (builtins.match "text-embedding-.*" m != null);
          in {
            model_name = "copilot-${m}";
            litellm_params = {
              model = "github_copilot/${m}";
              # NB: do NOT set extra_headers here. Recent litellm
              # (get_copilot_default_headers + GithubCopilotResponsesAPIConfig)
              # already injects copilot-integration-id, editor-version,
              # editor-plugin-version, user-agent, x-github-api-version, etc.
              # Adding our own with different casing (Copilot-Integration-Id vs
              # copilot-integration-id) causes httpx to emit BOTH header
              # lines, which GitHub concatenates and rejects as
              # "unknown Copilot-Integration-Id". Copilot-Vision-Request and
              # X-Initiator are also computed per-request automatically.
            };
          } // (
            if isResponsesOnly then { model_info.mode = "responses"; }
            else if isChatOnly then { model_info.mode = "chat"; }
            else {}
          ))
          [
            "claude-haiku-4.5"
            "claude-opus-4.5"
            "claude-opus-4.6"
            "claude-opus-4.7"
            "claude-sonnet-4.5"
            "claude-sonnet-4.6"
            "gemini-2.5-pro"
            "gpt-3.5-turbo"
            "gpt-3.5-turbo-0613"
            "gpt-4"
            "gpt-4-0125-preview"
            "gpt-4-0613"
            "gpt-4-o-preview"
            "gpt-4.1"
            "gpt-4.1-2025-04-14"
            "gpt-41-copilot"
            "gpt-4o"
            "gpt-4o-2024-05-13"
            "gpt-4o-2024-08-06"
            "gpt-4o-2024-11-20"
            "gpt-4o-mini"
            "gpt-4o-mini-2024-07-18"
            "gpt-5-mini"
            "gpt-5.2"
            "gpt-5.2-codex"
            "gpt-5.3-codex"
            "gpt-5.4"
            "gpt-5.4-mini"
            "gpt-5.5"
            "text-embedding-3-small"
            "text-embedding-3-small-inference"
            "text-embedding-ada-002"
          ]
        )
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
            "claude-3.7-sonnet"
            "claude-haiku-4.5"
            "claude-opus-4"
            "claude-opus-4.1"
            "claude-opus-4.5"
            "claude-opus-4.6"
            "claude-opus-4.7"
            "claude-opus-4-7"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-sonnet-4.6"
            "deepseek-3.1"
            "gemini-2.0-flash"
            "gemini-2.0-flash-lite"
            "gemini-2.5-flash"
            "gemini-2.5-flash-image"
            "gemini-2.5-flash-lite"
            "gemini-2.5-pro"
            "gemini-2.5-pro-batch"
            "gemini-2.5-pro-passthrough"
            "glm-4.7"
            "glm-5"
            "gpt-4.1"
            "gpt-4.1-mini"
            "gpt-4o"
            "gpt-4o-applied-ai"
            "gpt-4o-mini"
            "gpt-5"
            "gpt-5-batch"
            "gpt-5-mini"
            "gpt-5-nano"
            "gpt-5.1"
            "gpt-5.2"
            "gpt-5.4"
            "gpt-5.5"
            "kimi-2.5"
            "minimax-2.5"
            "o3-mini"
            "o4-mini"
            "text-embedding-005"
            "text-embedding-3-large"
            "text-embedding-3-small"
            "text-embedding-ada-002"
            "text-embedding-large-exp-03-07"
          ]
        )
        # llama.cpp router on joe (3090) — models are configured in
        # hosts/joe/llama-cpp.nix (modelsPreset) and downloaded from
        # Hugging Face on first request. The router loads/unloads as
        # needed (max 1 resident model). OpenAI-compatible API at /v1.
        ++ (builtins.map
          (m: {
            model_name = "local-${m}";
            litellm_params = {
              model = "openai/${m}";
              api_base = "http://100.64.0.12:11434/v1";
              api_key = "na";
            };
            # llama.cpp / llama-server only speaks /v1/chat/completions.
            # Without this, litellm forwards MVA's /v1/responses calls 1:1
            # upstream and the local server rejects them with a schema
            # validation error (e.g. "'type' must be one of 'output_text'
            # or 'refusal'"). `mode = "chat"` makes litellm bridge
            # /responses → /chat/completions, same as the Copilot
            # claude-/gemini-/grok- block above.
            model_info.mode = "chat";
          })
          [
            "qwen3.6-35b-a3b"
            "qwen3-coder-30b-a3b"
          ]
        );
      };
    };
  };
}
