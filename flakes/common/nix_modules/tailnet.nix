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
  boot.kernelModules = [ "tun" ];

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

  # Route joshuabell.xyz DNS queries through Tailscale for extra_records defined in headscale
  # This adds ~joshuabell.xyz as a routing domain alongside the MagicDNS domain
  systemd.services.tailscale-dns-routes = {
    description = "Configure DNS routing for Tailscale extra_records";
    after = [ "tailscaled.service" "systemd-resolved.service" ];
    requires = [ "tailscaled.service" "systemd-resolved.service" ];
    wantedBy = [ "multi-user.target" ];
    # Wait for tailscale0 interface to be up and have DNS configured
    script = ''
      # Wait for tailscale to be connected and DNS configured
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ip link show tailscale0 &>/dev/null && \
           ${pkgs.systemd}/bin/resolvectl status tailscale0 2>/dev/null | grep -q "DNS Servers"; then
          break
        fi
        sleep 1
      done
      # Add joshuabell.xyz to the routing domains (keeping existing ones)
      current_domains=$(${pkgs.systemd}/bin/resolvectl domain tailscale0 2>/dev/null | grep -oP '(?<=tailscale0: ).*' || echo "")
      if ! echo "$current_domains" | grep -q "joshuabell.xyz"; then
        ${pkgs.systemd}/bin/resolvectl domain tailscale0 $current_domains ~joshuabell.xyz
        echo "Added ~joshuabell.xyz to tailscale0 DNS routing domains"
      else
        echo "joshuabell.xyz already in routing domains"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
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
