{
  inputs,
  pkgs,
  constants,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
  nixpkgsLitellm = inputs.litellm-nixpkgs;
  # Replace "claude" with "cl4ude" in model names to avoid special handling in other apps
  sanitizeModelName = s: builtins.replaceStrings [ "claude" ] [ "cl4ude" ] s;
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

    services.litellm = {
      enable = true;
      port = c.port;
      host = "0.0.0.0";
      openFirewall = false;
      package = pkgsLitellm.litellm;
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
        };
        model_list = [
          # Anthropic (direct)
          {
            model_name = "anthropic/*";
            litellm_params = {
              model = "anthropic/*";
            };
          }
          # OpenRouter
          {
            model_name = "openrouter/*";
            litellm_params = {
              model = "openrouter/*";
            };
          }
        ]
        # Copilot
        ++ (builtins.map
          (m: {
            model_name = "copilot-${m}";
            litellm_params = {
              model = "github_copilot/${m}";
              extra_headers = {
                editor-version = "vscode/${pkgsLitellm.vscode.version}";
                editor-plugin-version = "copilot/${pkgsLitellm.vscode-extensions.github.copilot.version}";
                Copilot-Integration-Id = "vscode-chat";
                Copilot-Vision-Request = "true";
                user-agent = "GithubCopilot/${pkgsLitellm.vscode-extensions.github.copilot.version}";
              };
            };

          })
          # List from https://github.com/settings/copilot/features enabled models
          [
            "claude-opus-4.6"
            "claude-opus-4.5"
            "claude-sonnet-3.5"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-haiku-4.5"
            "gemini-2.5-pro"
            "openai-gpt-5"
            "openai-gpt-5-mini"
            "openai-gpt-5.1-mini"
            "openai-gpt-5.1"
            "openai-gpt-5.1-codex"
            "openai-gpt-5.1-codex-max"
            "openai-gpt-5.2"
            "openai-gpt-5.2-codex"
            "grok-code-fast-1"
          ]
        )
        # Azure
        ++ (builtins.map
          (m: {
            model_name = "azure-${m}";
            litellm_params = {
              model = "azure/${m}";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
            };
          })
          # curl -L "http://100.64.0.8:9010/azure/openai/models?api-version=2025-04-01-preview" | jq '.data.[].id'
          [
            "gpt-5.2-2025-12-11"
            "gpt-5.1-2025-11-13"
            "gpt-4o-2024-05-13"
            "gpt-4.1-2025-04-14"
            "gpt-4.1-mini-2025-04-14"
            "gpt-5-nano-2025-08-07"
            "gpt-5-mini-2025-08-07"
            "gpt-5-2025-08-07"
          ]
          #curl "http://100.64.0.8:9010/azure/openai/deployments/gpt-5.2-2025-12-11/chat/completions?api-version=2025-04-01-preview" \
          # -H "Content-Type: application/json" \
          # -H "api-key: na" \
          # -d '{
          #   "messages": [
          #     {"role": "system", "content": "You are a helpful assistant."},
          #     {"role": "user", "content": "write a haiku?"}
          #   ],
          #   "temperature": 0.7
          # }' | jq
        )
        # Azure reasoning aliases
        ++ [
          {
            model_name = "azure-gpt-5.2-low";
            litellm_params = {
              model = "azure/gpt-5.2-2025-12-11";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
              extra_body = {
                reasoning_effort = "low";
              };
            };
          }
          {
            model_name = "azure-gpt-5.2-medium";
            litellm_params = {
              model = "azure/gpt-5.2-2025-12-11";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
              extra_body = {
                reasoning_effort = "medium";
              };
            };
          }
          {
            model_name = "azure-gpt-5.2-high";
            litellm_params = {
              model = "azure/gpt-5.2-2025-12-11";
              api_base = "http://100.64.0.8:9010/azure";
              api_version = "2025-04-01-preview";
              api_key = "na";
              extra_body = {
                reasoning_effort = "high";
              };
            };
          }
        ]
        # 宙 Proxy
        ++ (builtins.map
          (m: {
            model_name = "air-${sanitizeModelName m}";
            litellm_params = {
              model = "litellm_proxy/${m}";
              api_base = "http://100.64.0.8:9010/air_prd";
              api_key = "na";
              drop_params = true;
              # TODO try this instead of sanitized name
              # additional_drop_params = if [ "messages[*].cacheControl" ];
            };
          })
          # curl -L t.net.joshuabell.xyz:9010/air_prd/models | jq '.data.[].id'
          [
            "gpt-5-mini"
            "gpt-5-nano"
            "gpt-5.1"
            "gpt-5.2"
            "gpt-5"
            "gpt-4.1"
            "gpt-4.1-mini"
            "gpt-4o"
            "gpt-4o-applied-ai"
            "gpt-4o-mini"
            "o3-mini"
            "o4-mini"
            "gemini-2.5-pro"
            "gemini-2.0-flash"
            "gemini-2.5-flash"
            "gemini-2.0-flash-lite"
            "gemini-2.5-flash-lite"
            "gemini-2.5-flash-image"
            "claude-haiku-4.5"
            "claude-opus-4.6"
            "claude-opus-4.5"
            "claude-opus-4.1"
            "claude-opus-4"
            "claude-sonnet-4.6"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-3.7-sonnet"
            "text-embedding-3-small"
            "text-embedding-3-large"
            "text-embedding-ada-002"
            "text-embedding-large-exp-03-07"
            "text-embedding-005"
          ]
        )
        # ++ (builtins.map
        #   (m: {
        #     model_name = "air_dev-${sanitizeModelName m}";
        #     litellm_params = {
        #       model = "litellm_proxy/${m}";
        #       api_base = "http://100.64.0.8:9010/air_alp";
        #       api_key = "na";
        #       drop_params = true;
        #     };
        #   })
        #   # curl -L t.net.joshuabell.xyz:9010/air_alp/models | jq '.data.[].id'
        #   [
        #     "claude-opus-4.5"
        #     "claude-sonnet-4.5"
        #     "gemini-3-pro-preview"
        #   ]
        # )
        ;
      };
    };
  };
}
