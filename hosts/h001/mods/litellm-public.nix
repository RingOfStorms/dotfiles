{
  inputs,
  pkgs,
  lib,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
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
        # 宙 Proxy
        ++ (builtins.map
          (m: {
            model_name = "air-${m}";
            litellm_params = {
              model = "litellm_proxy/${m}";
              api_base = "http://100.64.0.8:9010/air_prd";
              api_key = "na";
              drop_params = true;
            };
          })
          # curl -L t.net.joshuabell.xyz:9010/air_prd/models | jq '.data.[].id'
          [
            "gemini-2.5-pro"
            "gemini-2.0-flash"
            "gemini-2.5-flash"
            "gemini-2.0-flash-lite"
            "gemini-2.5-flash-lite"
            "gemini-2.5-flash-image"
            "claude-opus-4.1"
            "claude-opus-4"
            "claude-opus-4.5"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-3.7-sonnet"
          ]
        )
      ;
    };
  };
}
