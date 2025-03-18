{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "tailnet"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "rust development tools";
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

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ tailscale ];
    services.tailscale = {
      enable = true;
      openFirewall = true;
      useRoutingFeatures = "client";
      authKeyFile = lib.mkIf cfg.useSecretsAuth config.age.secrets.headscale_auth.path;
      # https://tailscale.com/kb/1241/tailscale-up
      extraUpFlags = lib.mkIf cfg.useHeadscale [
        "--login-server=https://headscale.joshuabell.xyz"
        "--no-logs-support"
      ];
    };
    networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
    networking.firewall.checkReversePath = "loose";
  };

}
