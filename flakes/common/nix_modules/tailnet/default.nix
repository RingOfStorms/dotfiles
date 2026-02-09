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

  # Shared DNS records for h001 services - used for /etc/hosts fallback
  h001Dns = import ./h001_dns.nix;
in
{
  environment.systemPackages = with pkgs; [ tailscale ];
  boot.kernelModules = [ "tun" ];

  # Add /etc/hosts entries for h001 services as fallback for headscale DNS
  networking.hosts = {
    "${h001Dns.ip}" = map (name: "${name}.${h001Dns.baseDomain}") h001Dns.subdomains;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    authKeyFile = lib.mkIf (hasSecret "headscale_auth") config.age.secrets.headscale_auth.path;
    extraUpFlags = [
      "--login-server=https://headscale.joshuabell.xyz"
    ];
    extraDaemonFlags = [
      "--no-logs-no-support"
    ];
  };

  systemd.services.tailscaled = {
    after = [
      "systemd-modules-load.service"
      "dev-net-tun.device"
    ];
    wants = [ "dev-net-tun.device" ];
    requires = [ "dev-net-tun.device" ];
  };

  networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
  networking.firewall.checkReversePath = "loose";
}
