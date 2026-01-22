{
  inputs,
  pkgs,
  lib,
  ...
}:
# NOTE this won't work on its own without the main litellm.nix file this is sort of a side car
let
  nixpkgsLitellm = inputs.litellm-nixpkgs;
  pkgsLitellm = import nixpkgsLitellm {
    inherit (pkgs) system;
    config.allowUnfree = true;
  };
  port = 8095;

  azureModels = [
    "gpt-5.2-2025-12-11"
    "gpt-5.1-2025-11-13"
    "gpt-4o-2024-05-13"
    "gpt-4.1-2025-04-14"
    "gpt-4.1-mini-2025-04-14"
    "gpt-5-nano-2025-08-07"
    "gpt-5-mini-2025-08-07"
    "gpt-5-2025-08-07"
  ];
in
{
  options = { };
  config = {
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

    systemd.services.litellm-public = {
      description = "LiteLLM Public Proxy (Azure models only)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        # Sharing login with main instance
        GITHUB_COPILOT_TOKEN_DIR = "/var/lib/litellm/github_copilot";
        XDG_CONFIG_HOME = "/var/lib/litellm-public/.config";
      };

      serviceConfig = {
        Type = "simple";
        User = "litellm-public";
        Group = "litellm-public";
        StateDirectory = "litellm-public";
        ExecStart = "${pkgsLitellm.litellm}/bin/litellm --config /etc/litellm-public/config.yaml --host 0.0.0.0 --port ${toString port}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    users.users.litellm-public = {
      isSystemUser = true;
      group = "litellm-public";
    };
    users.groups.litellm-public = { };

    environment.etc."litellm-public/config.yaml".text = lib.generators.toYAML { } {
      litellm_settings = {
        check_provider_endpoints = true;
        drop_params = true;
        modify_params = true;
      };
      model_list =
        (builtins.map (m: {
          model_name = "azure-${m}";
          litellm_params = {
            model = "azure/${m}";
            api_base = "http://100.64.0.8:9010/azure";
            api_version = "2025-04-01-preview";
            api_key = "na";
          };
        }) azureModels)
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
        # Copilot (note: need to check logs so it can log in)
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
            "claude-opus-4.5"
            "claude-sonnet-3.5"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-haiku-4.5"
            "gemini-2.5-pro"
            "openai-gpt-5"
            "openai-gpt-5-mini"
            "grok-code-fast-1"
          ]
        );
    };
  };
}
