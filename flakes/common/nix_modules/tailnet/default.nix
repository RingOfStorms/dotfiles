{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Shared DNS records for h001 services - used for /etc/hosts fallback
  h001Dns = import ./h001_dns.nix;
  cfg = config.ringofstorms.tailnet;
in
{
  options.ringofstorms.tailnet = {
    h001DnsHosts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add /etc/hosts entries for h001 services as fallback for headscale MagicDNS. Disable on hosts where the chicken-and-egg with secrets bootstrap is a problem.";
    };
  };

  config = {

  environment.systemPackages = with pkgs; [ tailscale ];
  boot.kernelModules = [ "tun" ];

  # Add /etc/hosts entries for h001 services as fallback for headscale DNS
  networking.hosts = lib.mkIf cfg.h001DnsHosts {
    "${h001Dns.ip}" = map (name: "${name}.${h001Dns.baseDomain}") h001Dns.subdomains;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--login-server=https://headscale.joshuabell.xyz"
    ];
    extraDaemonFlags = [
      "--no-logs-no-support"
    ];
  };

  # Explicit oneshot to guarantee the tun module is loaded before tailscaled.
  # Using dev-net-tun.device directly is racy -- the udev device unit may not
  # be registered by the time tailscaled starts, causing a hard failure.
  # modprobe is idempotent so this is safe even when the module is already loaded.
  systemd.services.ensure-tun = {
    description = "Ensure tun module is loaded";
    wantedBy = [ "tailscaled.service" ];
    before = [ "tailscaled.service" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.kmod}/bin/modprobe tun";
    };
  };

  systemd.services.tailscaled = {
    after = [
      "systemd-modules-load.service"
      "ensure-tun.service"
    ];
    wants = [ "ensure-tun.service" ];
    requires = [ "ensure-tun.service" ];
  };

  networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
  networking.firewall.checkReversePath = "loose";
  };
}
