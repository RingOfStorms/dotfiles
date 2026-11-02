# configuration.nix scopes SSH to tailscale0 and the LAN. The container
# module admits o002 to the edge listener; internal HTTP has no blanket
# tailnet allow. Taildrop's random peerapi port is deliberately closed.
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
