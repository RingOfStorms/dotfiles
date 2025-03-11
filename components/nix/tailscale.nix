{
  lib,
  pkgs,
  config,
  ...
}:
{
  options.components.tailscale = {
    useSecretsAuth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to use secrets authentication for Tailscale";
    };
    useHeadscale = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to use headscale login server.";
    };
  };

  config = {
    environment.systemPackages = with pkgs; [ tailscale ];
    services.tailscale = {
      enable = true;
      openFirewall = true;
      useRoutingFeatures = "client";
      authKeyFile = lib.mkIf config.components.tailscale.useSecretsAuth config.age.secrets.headscale_auth.path;
      # https://tailscale.com/kb/1241/tailscale-up
      extraUpFlags = lib.mkIf config.components.tailscale.useHeadscale [
        "--login-server=https://headscale.joshuabell.xyz"
        "--no-logs-support"
      ];
    };
    networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
    networking.firewall.checkReversePath = "loose";
  };
}
