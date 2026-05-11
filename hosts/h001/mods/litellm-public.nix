{
  inputs,
  pkgs,
  lib,
  config,
  constants,
  ...
}:
# NOTE this won't work on its own without the main litellm.nix file this is sort of a side car
let
  nixpkgsLitellm = inputs.litellm-nixpkgs;
  pkgsLitellm = import nixpkgsLitellm {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.litellmPublic;

  # Reuse the model_list from the private litellm instance, filtering to
  # only copilot models (exclude air proxy, openrouter, ollama, local).
  allModels = config.services.litellm.settings.model_list;
  isCopilot = m: lib.hasPrefix "copilot-" m.model_name;
  publicModels = builtins.filter isCopilot allModels;
in
{
  options = { };
  config = {
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

    systemd.services.litellm-public = {
      description = "LiteLLM Exposed Proxy (limited model set)";
      # Listens on 0.0.0.0 (no specific address), but it's only reachable via
      # the firewall rule on tailscale0, so wait for the interface to be fully
      # up via tailscaled-autoconnect.service (Type=notify) instead of just the
      # daemon starting.
      wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
      after = [
        "network-online.target"
        "tailscaled-autoconnect.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        GITHUB_COPILOT_TOKEN_DIR = "${c.dataDir}/github_copilot";
        XDG_CONFIG_HOME = "${c.dataDir}/.config";
      };

      serviceConfig = {
        Type = "simple";
        User = "litellm-public";
        Group = "litellm-public";
        StateDirectory = "litellm-public";
        ExecStart = "${pkgsLitellm.litellm}/bin/litellm --config /etc/litellm-public/config.yaml --host 0.0.0.0 --port ${toString c.port}";
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
      model_list = publicModels;
    };
  };
}
