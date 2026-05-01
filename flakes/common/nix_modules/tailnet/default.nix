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

    omitCaptivePortal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build tailscale with the upstream `ts_omit_captiveportal` build tag,
        compiling out the captive-portal detector entirely. This eliminates the
        periodic DNS lookups / HTTP probes to controlplane.tailscale.com and
        login.tailscale.com that tailscaled hard-codes into its captive-portal
        endpoint list (see net/captivedetection/endpoints.go upstream), which
        fire every ~5 minutes regardless of `--login-server`.

        Default-on for this headscale-only fleet. Set to `false` on portable
        hosts (laptops) that need to detect captive portals on hotel/coffee-shop
        wifi.

        Triggers a local rebuild of the tailscale package.
      '';
    };
  };

  config = {

  nixpkgs.overlays = lib.mkIf cfg.omitCaptivePortal [
    (final: prev: {
      tailscale = prev.tailscale.overrideAttrs (old: {
        tags = (old.tags or []) ++ [ "ts_omit_captiveportal" ];
      });
    })
  ];

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
    # Idiomatic equivalent of `extraDaemonFlags = [ "--no-logs-no-support" ]`:
    # sets TS_NO_LOGS_NO_SUPPORT=true, suppressing log uploads / netlog phone-home.
    # (Does NOT affect captive-portal probes -- see omitCaptivePortal option.)
    disableUpstreamLogging = true;
    extraUpFlags = [
      "--login-server=https://headscale.joshuabell.xyz"
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
