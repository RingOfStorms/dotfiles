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
        };
        litellm_settings = {
          check_provider_endpoints = true;
        };
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
          # {
          #   model_name = "GPT-5-codex";
          #   litellm_params = {
          #     model = "azure/gpt-5-codex-2025-09-15";
          #     api_base = "http://100.64.0.8:9010/azure";
          #     api_version = "2025-04-01-preview";
          #     api_key = "na";
          #   };
          # }
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
          # {
          #   model_name = "dall-e-3-3.0";
          #   litellm_params = {
          #     model = "azure/dall-e-3-3.0";
          #     api_base = "http://100.64.0.8:9010/azure";
          #     api_version = "2025-04-01-preview";
          #     api_key = "na";
          #   };
          # }

          # Copilot
          {
            model_name = "copilot-claude-sonnet-4.5";
            litellm_params = {
              model = "github_copilot/claude-sonnet-4.5";
              extra_headers = {
                editor-version = "vscode/${pkgs.vscode.version}";
                editor-plugin-version = "copilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
                Copilot-Integration-Id = "vscode-chat";
                Copilot-Vision-Request = "true";
                user-agent = "GithubCopilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
              };
            };
          }
          {
            model_name = "copilot-claude-sonnet-4";
            litellm_params = {
              model = "github_copilot/claude-sonnet-4";
              extra_headers = {
                editor-version = "vscode/${pkgs.vscode.version}";
                editor-plugin-version = "copilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
                Copilot-Integration-Id = "vscode-chat";
                Copilot-Vision-Request = "true";
                user-agent = "GithubCopilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
              };
            };
          }
          {
            model_name = "copilot-google-gemini-2.5-pro";
            litellm_params = {
              model = "github_copilot/gemini-2.5-pro";
              extra_headers = {
                editor-version = "vscode/${pkgs.vscode.version}";
                editor-plugin-version = "copilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
                Copilot-Integration-Id = "vscode-chat";
                Copilot-Vision-Request = "true";
                user-agent = "GithubCopilot/${pkgs.vscode-marketplace-release.github.copilot.version}";
              };
            };
          }
          # {
          #   model_name = "copilot-google-gemini-2.0-flash";
          #   litellm_params = {
          #     model = "github_copilot/gemini-2.0-flash";
          #     extra_headers = {
          #       "editor-version" = "vscode/1.85.1";
          #       "Copilot-Integration-Id" = "vscode-chat";
          #       "user-agent" = "GithubCopilot/1.155.0";
          #       "editor-plugin-version" = "copilot/1.155.0";
          #     };
          #   };
          # }

          # 宙 Proxy
          # {
          #   model_name = "litellm_proxy/*";
          #   litellm_params = {
          #     model = "litellm_proxy/*";
          #     api_base = "http://100.64.0.8:9010/air_key";
          #     api_key = "os.environ/LITELLM_PROXY_API_KEY";
          #   };
          # }
        ];
      };
    };
  };
}
