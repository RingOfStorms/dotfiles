{
  config,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [ tailscale ];
  services.tailscale = {
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
