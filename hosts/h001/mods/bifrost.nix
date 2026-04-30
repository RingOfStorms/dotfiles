{
  pkgs,
  inputs,
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

  # Upstream's flake hardcodes an npmDepsHash for bifrost-ui that
  # doesn't match what npm actually produces in our build environment
  # (likely a node-version / npm-prefetch difference). Override both
  # bifrost-ui and bifrost-http with a corrected hash. Bump the hash
  # below if upstream changes ui/package-lock.json again.
  bifrostSrc = inputs.bifrost;
  bifrostVersion = "1.4.9";

  # Override buildNpmPackage to swap npmDepsHash before the npm-deps FOD
  # is constructed. (overrideAttrs on the final ui derivation is too late
  # — npmDeps is a separate fixed-output derivation built from the hash
  # passed to buildNpmPackage.) If the hash drifts again, set to
  # pkgs.lib.fakeHash, rebuild, copy the "got:" hash from the error.
  npmDepsHashOverride = "sha256-qFpGbGfCCJ1AeYySPLirdte4NGHZPetWL/cOQcrNMWM=";

  # bifrost-ui.nix calls `pkgs.buildNpmPackage` directly, so we shadow
  # `pkgs` with one whose buildNpmPackage forces our npmDepsHash.
  pkgsWithFixedBuildNpm = pkgs // {
    buildNpmPackage =
      args: pkgs.buildNpmPackage (args // { npmDepsHash = npmDepsHashOverride; });
  };

  bifrost-ui-fixed = pkgs.callPackage "${bifrostSrc}/nix/packages/bifrost-ui.nix" {
    pkgs = pkgsWithFixedBuildNpm;
    src = bifrostSrc;
    version = bifrostVersion;
  };

  # bifrost-http.nix expects `inputs.nixpkgs` (it builds a custom
  # buildGoModule against that nixpkgs path). Pass through the bifrost
  # flake's own nixpkgs input, mirroring what the upstream flake does.
  # Also override vendorHash since upstream's pin doesn't match what
  # `go mod vendor` produces in our environment. If it drifts again,
  # set to pkgs.lib.fakeHash, rebuild, copy the "got:" hash.
  goVendorHashOverride = "sha256-odcos+b+G2mLeSyQ/1N8esHwskrgUlcquiVEATOu7WE=";

  bifrost-http-raw = pkgs.callPackage "${bifrostSrc}/nix/packages/bifrost-http.nix" {
    inputs = { nixpkgs = inputs.bifrost.inputs.nixpkgs; };
    src = bifrostSrc;
    version = bifrostVersion;
    bifrost-ui = bifrost-ui-fixed;
  };

  bifrost-http-fixed = bifrost-http-raw.overrideAttrs (_: {
    vendorHash = goVendorHashOverride;
  });
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
      package = bifrost-http-fixed;
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
