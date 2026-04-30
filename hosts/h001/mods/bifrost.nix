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
# from the same LiteLLM-style community pricing JSON litellm uses (fetched
# from https://getbifrost.ai/datasheet, schema-identical to LiteLLM's
# model_prices_and_context_window.json).
#
# Auth: none on UI/API. Tailscale-only exposure is the safety boundary.
# Smoke-test scope: 1 OpenRouter wildcard provider + 1 upstream-litellm
# (work air_prd) provider. No Copilot — Bifrost has no Copilot provider
# (no PR open as of 2026-04). Copilot stays on litellm.
#
# Cost tracking for the `air` custom provider: Bifrost's cost lookup is
# keyed on `model|provider|mode`. With a custom provider name (`air`),
# the catalog has no matching entry (entries use canonical provider names
# like `openai`), so the UI shows "—" / N/A. Bifrost has no path to read
# the upstream `X-Litellm-Response-Cost` header, and stock LiteLLM does
# not embed cost into the response body's `usage.cost` field — so the
# only fix is `governance.pricing_overrides`, which lets us pin a price
# for `(provider=air, model=X)` via the same per-token fields as the
# datasheet.
#
# Override rows live in ./bifrost_models.nix (auto-generated). Regenerate
# with `nix develop` then `bifrost-models`. The script fetches the live
# /models lists from upstream air_prd + OpenRouter, fuzzy-matches air
# models against models.dev for pricing, and emits per-model overrides
# scoped to `provider=air` / `provider=openrouter`. See
# scripts/bifrost_models/ for the source.
let
  c = constants.services.bifrost;

  # Auto-generated pricing override list. See file header for regen flow.
  bifrostModels = import ./bifrost_models.nix;

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

        # SQLite-backed config & logs. Enables Web UI, cost tracking,
        # request log history. Both DBs land under stateDir.
        # Per upstream `examples/configs/withconfigstorelogsstoresqlite/`,
        # `type` and `config.path` are required (no defaults).
        config_store = {
          enabled = true;
          type = "sqlite";
          config = { path = "${c.dataDir}/config.db"; };
        };
        logs_store = {
          enabled = true;
          type = "sqlite";
          config = { path = "${c.dataDir}/logs.db"; };
        };

        client = {
          # Inference endpoints unauth'd (tailnet-only). Management UI
          # likewise — match litellm posture.
          enforce_auth_on_inference = false;
        };

        providers = {
          # OpenRouter — wired as an openai-compatible CUSTOM provider
          # (rather than the built-in `openrouter` standard provider) so
          # it does NOT populate Bifrost's model catalog. Bifrost has no
          # `require_provider_prefix` flag; when a request omits the
          # `provider/` prefix it auto-resolves via the catalog and picks
          # the alphabetically-first match. With OpenRouter as a standard
          # provider, every bare model name silently routed through it.
          # Custom providers fail the `parsedProvider != provider` filter
          # in framework/modelcatalog/models.go, so their pool stays
          # empty → bare-name requests now error with "provider is
          # required in model field". See agent report 2026-04-30.
          #
          # base_url has NO trailing /v1 — Bifrost's openai provider
          # hardcodes `/v1/chat/completions` and appends to base_url
          # (core/providers/openai/openai.go:64-94, :747).
          openrouter = {
            keys = [
              {
                name = "main";
                value = "env.OPENROUTER_API_KEY";
                models = [ "*" ];
                weight = 1.0;
              }
            ];
            network_config = {
              base_url = "https://openrouter.ai/api";
              default_request_timeout_in_seconds = 120;
            };
            custom_provider_config = {
              base_provider_type = "openai";
              allowed_requests = {
                chat_completion = true;
                chat_completion_stream = true;
                embedding = true;
                # Lets Bifrost's /v1/models proxy upstream's /v1/models
                # (https://openrouter.ai/api/v1/models) so the model list
                # is auto-populated rather than hand-maintained. With
                # keys[].models = ["*"] the upstream response is returned
                # unfiltered, prefixed `openrouter/<id>`.
                list_models = true;
              };
            };
          };

          # Upstream LiteLLM at work (air_prd) via openai-compatible
          # custom_provider_config. Reachable on tailnet.
          #
          # Slug is `air` (not `air-prd`). The "prd" was stage-leakage
          # from the upstream litellm proxy path — clients address this
          # as `air/<model>` and it's the only air-* env we proxy.
          # Renaming is safe (no validation regex on custom provider
          # names; only constraint is "must not collide with a standard
          # provider", which `air` doesn't). Caveat: the old `air-prd`
          # row stays in ${c.dataDir}/config.db after rebuild — delete
          # it via the Bifrost UI Providers tab.
          air = {
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
                # Proxy upstream LiteLLM's /v1/models. See openrouter
                # block above for the rationale.
                list_models = true;
              };
            };
          };

          # llama.cpp router on joe (3090) — models configured in
          # hosts/joe/llama-cpp.nix (modelsPreset), downloaded from HF on
          # first request. Router loads/unloads as needed (max 1 resident).
          # OpenAI-compatible API at /v1. Mirrors litellm.nix `local-*`
          # entries; addressed here as `local/<model>`.
          #
          # base_url has NO trailing /v1 — Bifrost's openai provider
          # hardcodes the `/v1/...` segment (see openrouter note above).
          local = {
            keys = [
              {
                name = "k1";
                value = "na";
                models = [ "*" ];
                weight = 1.0;
              }
            ];
            network_config = {
              base_url = "http://100.64.0.12:11434";
              default_request_timeout_in_seconds = 120;
            };
            custom_provider_config = {
              base_provider_type = "openai";
              allowed_requests = {
                chat_completion = true;
                chat_completion_stream = true;
                embedding = true;
                # Proxy llama.cpp's /v1/models. See openrouter block
                # above for the rationale.
                list_models = true;
              };
            };
          };
        };

        # Pricing overrides come from ./bifrost_models.nix (generated by
        # `bifrost-models`). `pricing_patch` is a JSON-encoded *string* —
        # that's the schema Bifrost expects (see
        # framework/configstore/tables/pricingoverride.go: PricingPatchJSON).
        # Per-model `scope_kind=provider` so air/<model> and openrouter/<model>
        # don't accidentally cross-pollinate prices.
        governance = {
          pricing_overrides =
            bifrostModels.airPricingOverrides
            ++ bifrostModels.openrouterPricingOverrides;
        };
      };
    };
  };
}
