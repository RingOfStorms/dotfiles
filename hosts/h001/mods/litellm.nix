{
  inputs,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
  nixpkgs = inputs.litellm-nixpkgs;
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  port = 8094;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    networking.firewall.enable = true;
    # Expose litellm to my overlay network as well
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

    services.litellm = {
      enable = true;
      inherit port;
      host = "0.0.0.0";
      openFirewall = false;
      package = pkgs.litellm;
      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        GITHUB_COPILOT_TOKEN_DIR = "/var/lib/litellm/github_copilot";
        XDG_CONFIG_HOME = "/var/lib/litellm/.config";
      };
      settings = {
        environment_variables = {
          LITELLM_PROXY_API_KEY = "na";
          LITELLM_PROXY_API_BASE = "http://100.64.0.8:9010/air_key";
        };
        litellm_settings = {
          check_provider_endpoints = true;
          drop_params = true;
        };
        model_list = [
          # 宙 Proxy
          # { # NOTE model discovery not working yet? https://canary.discord.com/channels/1123360753068540065/1409974123987210350/1427864010241609752
          #   model_name = "litellm_proxy/*";
          #   litellm_params = {
          #     model = "litellm_proxy/*";
          #     api_base = "http://100.64.0.8:9010/air_key";
          #     api_key = "os.environ/LITELLM_PROXY_API_KEY";
          #   };
          # }
        ]
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
          [
            "gpt-4o-2024-05-13"
            "gpt-4.1-2025-04-14"
            "gpt-4.1-mini-2025-04-14"
            "gpt-5-nano-2025-08-07"
            "gpt-5-mini-2025-08-07"
            "gpt-5-2025-08-07"
            # "gpt-5-codex-2025-09-15"
          ]
        )
        # Copilot
        ++ (builtins.map
          (m: {
            model_name = "copilot-${m}";
            litellm_params = {
              model = "github_copilot/${m}";
              extra_headers = {
                editor-version = "vscode/${pkgs.vscode.version}";
                editor-plugin-version = "copilot/${pkgs.vscode-extensions.github.copilot.version}";
                Copilot-Integration-Id = "vscode-chat";
                Copilot-Vision-Request = "true";
                user-agent = "GithubCopilot/${pkgs.vscode-extensions.github.copilot.version}";
              };
            };

          })
          # List from https://github.com/settings/copilot/features enabled models
          [
            "claude-sonnet-4.5"
            "claude-sonnet-4"
            "gemini-2.5-pro"
          ]
        )
        # 宙 Proxy
        ++ (builtins.map
          (m: {
            model_name = "air-${m}";
            litellm_params = {
              model = "litellm_proxy/${m}";
              api_base = "http://100.64.0.8:9010/air_key";
              api_key = "os.environ/LITELLM_PROXY_API_KEY";
            };
          })
          # curl -L t.net.joshuabell.xyz:9010/air_key/models | jq '.data.[].id'
          [
            "gpt-5-mini"
            "gpt-5"
            "gpt-4.1"
            "gpt-4.1-mini"
            "gpt-4o"
            "gpt-4o-mini"
            "o3-mini"
            "o4-mini"
            "gemini-2.5-pro"
            "gemini-2.0-flash"
            "gemini-2.5-flash"
            "gemini-2.0-flash-lite"
            "gemini-2.5-flash-lite"
            "claude-opus-4.1"
            "claude-opus-4"
            "claude-sonnet-4"
            "claude-3.7-sonnet"
            "text-embedding-3-small"
            "text-embedding-3-large"
            "text-embedding-ada-002"
            "text-embedding-large-exp-03-07"
            "text-embedding-005"
            "llama7b"
            "medgemma-4b"
            "qwen3-instruct"
            "bge-small-en-v1.5"
          ]
        );
      };
    };
  };
}
