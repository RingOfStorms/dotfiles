{
  pkgs,
  constants,
  ...
}:
# Bifrost AI Gateway (https://github.com/maximhq/bifrost) — bake-off candidate
# alongside litellm. Uses the upstream flake's NixOS module.
#
# Persistence: SQLite under stateDir (default config_store + logs_store
# backends). Required for cost tracking + the Web UI. Cost data is sourced
# from the same LiteLLM-style community pricing JSON litellm uses.
#
# Auth: none on UI/API. Tailscale-only exposure is the safety boundary.
# Smoke-test scope: 1 OpenRouter wildcard provider + 1 upstream-litellm
# (work air_prd) provider. No Copilot — Bifrost has no Copilot provider
# (no PR open as of 2026-04). Copilot stays on litellm.
let
  c = constants.services.bifrost;
in
{
  config = {
    # Tailnet exposure mirrors litellm.nix.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

    # Wait for tailscale (air_prd reachable via 100.64.0.8) and DNS, same
    # rationale as litellm.nix.
    systemd.services.bifrost = {
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
    };

    services.bifrost = {
      enable = true;
      host = "0.0.0.0";
      port = c.port;
      stateDir = c.dataDir;
      openFirewall = false;
      logStyle = "pretty";
      logLevel = "info";

      # Reuse litellm's env file for OPENROUTER_API_KEY. systemd reads
      # EnvironmentFile= as root before dropping to DynamicUser, so the
      # 0400/root file is readable here.
      environmentFile = "/var/lib/openbao-secrets/litellm-env";

      settings = {
        "$schema" = "https://www.getbifrost.ai/schema";

        # SQLite-backed config & logs (default backends). Enables Web UI,
        # cost tracking, request log history.
        config_store = { enabled = true; };
        logs_store = { enabled = true; };

        client = {
          # Inference endpoints unauth'd (tailnet-only). Management UI
          # likewise — match litellm posture.
          enforce_auth_on_inference = false;
        };

        providers = {
          # OpenRouter — wildcard model passthrough.
          openrouter = {
            keys = [
              {
                name = "main";
                value = "env.OPENROUTER_API_KEY";
                models = [ "*" ];
                weight = 1.0;
              }
            ];
          };

          # Upstream LiteLLM at work (air_prd) via openai-compatible
          # custom_provider_config. Reachable on tailnet.
          air-prd = {
            keys = [
              {
                name = "k1";
                value = "na";
                models = [ "*" ];
                weight = 1.0;
              }
            ];
            network_config = {
              base_url = "http://100.64.0.8:9010/air_prd";
              default_request_timeout_in_seconds = 120;
            };
            custom_provider_config = {
              base_provider_type = "openai";
              allowed_requests = {
                chat_completion = true;
                chat_completion_stream = true;
                embedding = true;
              };
            };
          };
        };
      };
    };
  };
}
