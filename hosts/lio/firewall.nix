# lio does not trust tailscale0 (ROUTING-PLAN §5.1). configuration.nix already
# empties the global TCP allow-list and opens 22 on tailscale0 + the LAN CIDR;
# this adds only what other tailnet hosts need from lio.
#
# Still reachable without rules here:
# - 8443 nginx edge listener: o002 only, added by the containers host module.
# - 1714-1764 tcp/udp KDE Connect: global range from programs.kdeconnect.
# - 41641/udp tailscale: global.
# Deliberately closed on tailscale0:
# - 80 nginx: lio serves only the default `_` vhost and no inventory route.
# - tailscaled peerapi (random port, taildrop): not used in this repo.
{ fleet, ... }:
let
  # nix-serve clients: hosts importing common.nixosModules.remote_lio_builds
  # (substituter http://lio:5000). v6 addresses are headscale-assigned, stable.
  juni = fleet.hosts.juni.overlayIp;
  juni6 = "fd7a:115c:a1e0::12";
  gp3 = fleet.hosts.gp3.overlayIp;
  gp3_6 = "fd7a:115c:a1e0::f";
  oren = fleet.hosts.oren.overlayIp;
  oren6 = "fd7a:115c:a1e0::2";
in
{
  ringofstorms.tailnet.trustInterface = false;

  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${juni}, ${gp3}, ${oren} } tcp dport 5000 accept comment "nix-serve for remote_lio_builds hosts"
    iifname "tailscale0" ip6 saddr { ${juni6}, ${gp3_6}, ${oren6} } tcp dport 5000 accept comment "nix-serve for remote_lio_builds hosts (v6)"
  '';
}
