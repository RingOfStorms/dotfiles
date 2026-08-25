{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.tailnet;

  # Keep the resolver cache aligned with link/address/route changes. Tailscale
  # installs its split-DNS route asynchronously, and NetworkManager/DHCP can
  # replace the active DNS link while the machine remains up.
  flushResolvedDnsMonitor = pkgs.writeShellScript "tailscale-resolved-dns-monitor" ''
    set -euo pipefail

    flush_caches() {
      ${pkgs.systemd}/bin/resolvectl flush-caches
    }

    # Cover the initial Tailscale DNS setup and any later daemon restart.
    flush_caches

    # Coalesce a burst of netlink events and flush once after two quiet seconds.
    # The monitor exits if iproute2 stops; systemd then restarts this service.
    while IFS= read -r _event; do
      while IFS= read -r -t 2 _event; do
        :
      done
      flush_caches
    done < <(${pkgs.iproute2}/bin/ip monitor link address route)
  '';
in
{
  options.ringofstorms.tailnet = {
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

  # NOTE: h001 service names (*.joshuabell.xyz) are resolved on the tailnet via a
  # headscale split-DNS nameserver pointing at h003's tailnet dnsmasq listener
  # (see hosts/oracle/o002/headscale.nix + hosts/h003/mods/networking.nix).
  # The old `h001DnsHosts` /etc/hosts fallback option was removed: it was
  # dangerous as a default (static pins break off-tailnet) and unused by any host.

  # Headscale split DNS needs a resolver that supports per-link routing domains.
  # Tailscale integrates those routes (including ~joshuabell.xyz) with
  # systemd-resolved; without it, the system resolver can retain or prefer a
  # public answer instead of the Tailnet DNS view.
  services.resolved.enable = true;

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

  # Headscale's split DNS is delivered asynchronously after tailscaled connects.
  # `systemd-resolved` retains answers obtained before that route exists (including
  # public answers for *.joshuabell.xyz), even after tailscale0 receives the
  # ~joshuabell.xyz route. Clear that stale cache after autoconnect so subsequent
  # lookups use the Tailnet DNS view. This is harmless on explicit DNS opt-out
  # hosts: they have no Tailnet route and continue using their normal resolver.
  systemd.services.tailscale-flush-resolved-dns = {
    description = "Clear systemd-resolved cache after Tailscale DNS setup";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "systemd-resolved.service"
    ];
    partOf = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/resolvectl flush-caches";
    };
  };

  # Keep flushing after the initial setup: Tailscale and DHCP changes can
  # invalidate resolved's cached answer without restarting the host. The
  # iproute2 monitor covers link, address, and route changes on every host,
  # including tailscale0; the helper coalesces event bursts before flushing.
  systemd.services.tailscale-resolved-dns-monitor = {
    description = "Flush systemd-resolved cache after network state changes";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "tailscale-flush-resolved-dns.service"
    ];
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "tailscale-flush-resolved-dns.service"
      "systemd-resolved.service"
    ];
    partOf = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = flushResolvedDnsMonitor;
      Restart = "always";
      RestartSec = "2s";
    };
  };

  networking.firewall.trustedInterfaces = [ config.services.tailscale.interfaceName ];
  networking.firewall.checkReversePath = "loose";
  };
}
