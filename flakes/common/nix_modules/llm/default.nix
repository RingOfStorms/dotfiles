{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.ringofstorms.llm;

  tierOptions = defaults: {
    model = mkOption {
      type = types.str;
      default = defaults.model;
      description = "LiteLLM model id for this tier.";
    };
    reasoning = mkOption {
      type = types.nullOr types.str;
      default = defaults.reasoning;
      description = "reasoning_effort sent with requests for this tier; null sends none.";
    };
  };
in
{
  # Stable key so the module is deduplicated when imported from both the git
  # and essentials modules, even via different store paths (e.g. lio imports
  # git/default.nix by relative path but essentials via the common flake).
  key = "ringofstorms-llm";

  # Single source of truth for the models used by shell utilities (gcpropose,
  # gpr, `.` command proposer, ...). Values are exported as environment
  # variables and read per call, so `export MODEL_FAST=...` overrides them for
  # a shell session.
  options.ringofstorms.llm = {
    baseUrl = mkOption {
      type = types.str;
      default = "http://h001.net.joshuabell.xyz:8094";
      description = "LiteLLM base URL.";
    };
    smart = tierOptions {
      model = "copilot-claude-opus-5.5";
      reasoning = "medium";
    };
    fast = tierOptions {
      model = "copilot-gemini-3.8-flash";
      reasoning = "high";
    };
  };

  config = {
    environment.variables = {
      LLM_BASE_URL = cfg.baseUrl;
      MODEL_SMART = cfg.smart.model;
      MODEL_SMART_REASONING = toString cfg.smart.reasoning;
      MODEL_FAST = cfg.fast.model;
      MODEL_FAST_REASONING = toString cfg.fast.reasoning;
    };

    environment.shellInit = builtins.readFile ./llm.func.sh;
  };
}
