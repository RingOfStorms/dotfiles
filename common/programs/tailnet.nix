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
      enable = lib.mkEnableOption "enable tailnet";
      useHeadscale = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use headscale login server.";
      };
      enableExitNode = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable exit node.";
      };
    };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ tailscale ];
    services.tailscale = {
      enable = true;
      openFirewall = true;
      useRoutingFeatures = "client";
      authKeyFile = lib.mkIf (
        config ? age && config.age ? secrets && config.age.secrets ? headscale_auth
      ) config.age.secrets.headscale_auth.path;
      # https://tailscale.com/kb/1241/tailscale-up
      extraUpFlags =
        (lib.optionals cfg.useHeadscale [
          "--login-server=https://headscale.joshuabell.xyz"
          "--no-logs-support"
        ])
        ++ (lib.optionals cfg.enableExitNode [ "--advertise-exit-node" ]);

    };
    networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
    networking.firewall.checkReversePath = "loose";
  };

}
