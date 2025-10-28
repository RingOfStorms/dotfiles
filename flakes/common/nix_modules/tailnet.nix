{
  config,
  pkgs,
  lib,
  ...
}:
let
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  environment.systemPackages = with pkgs; [ tailscale ];
  services.tailscale = lib.mkIf (hasSecret "headscale_auth") {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    authKeyFile = config.age.secrets.headscale_auth.path;
    extraUpFlags = [
      "--login-server=https://headscale.joshuabell.xyz"
    ];
    extraDaemonFlags = [
      "--no-logs-no-support"
    ];
  };
  networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
  networking.firewall.checkReversePath = "loose";
}
