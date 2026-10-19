# fleet-edge read-only dashboard (containers/ROUTING-PLAN.md §5.4).
# The inventory is generated at build time from the containers flake, so it
# only refreshes when h005 is redeployed (`nix flake update containers` first).
#
# Tailnet-only: nginx listens on h005's overlay IP alone (plain HTTP, no
# public DNS, not proxied by o002) and additionally allows only tailnet
# source ranges. URL: http://h005.net.joshuabell.xyz/ (MagicDNS).
{
  inputs,
  constants,
  pkgs,
  ...
}:
let
  overlayIp = constants.host.overlayIp;
in
{
  imports = [ inputs.fleet-edge.nixosModules.default ];

  services.fleet-edge = {
    enable = true;
    inventoryFile = pkgs.writeText "fleet-inventory.json" (builtins.toJSON inputs.containers.inventory);
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.fleet = {
      default = true;
      serverName = "h005.net.joshuabell.xyz";
      listen = [
        {
          addr = overlayIp;
          port = 80;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8099";
        extraConfig = ''
          allow 100.64.0.0/10;
          allow fd7a:115c:a1e0::/48;
          deny all;
        '';
      };
    };
  };

  # nginx listens on the overlay IP, which only exists once tailscaled has
  # brought the tailnet up and may not exist yet when nginx starts at boot.
  # Ordering after tailscaled is not enough (the address comes later), so
  # allow binding addresses not (yet) assigned to any interface.
  # (IPFreeBind is not a service directive; systemd ignores it.)
  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
  systemd.services.nginx = {
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
  };
}
