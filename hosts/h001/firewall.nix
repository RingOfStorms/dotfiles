# h001 does not trust tailscale0 (ROUTING-PLAN §5.1): the tailnet gets exactly
# the ports below. Global allows (22/80/443, 41641/udp, icmp, temp-ports from
# `containers` ports files) still apply on every interface, LAN included.
{ fleet, ... }:
let
  lio = fleet.hosts.lio.overlayIp; # immich_manager (~/projects/immich_manager)
  h005 = fleet.hosts.h005.overlayIp; # fleet-edge / containers-status poller
  # tailnet v6 addresses of the same hosts (headscale-assigned, stable).
  lio6 = "fd7a:115c:a1e0::1";
  h005_6 = "fd7a:115c:a1e0::3";
in
{
  ringofstorms.tailnet.trustInterface = false;

  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      # 22, 80, 443 and the temp-ports set (3032 forgejo ssh, 8090 beszel hub,
      # arr's 6336/8087/9292/51820) are already open on every interface.
      9112 # trilium desktop-sync listener on the overlay IP (containers/trilium)
      # arr UIs the fleet-edge start page (h005) links to directly (h001.net.joshuabell.xyz:<port>);
      # drop each once it is a route behind nginx.
      7878 # radarr
      8989 # sonarr
      6767 # bazarr
      9696 # prowlarr
      9091 # transmission RPC/UI (host nginx -> wg netns)
      8096 # jellyfin direct (apps configured with h001:8096)
    ];
  };

  # Source-limited: nothing else on the tailnet reaches these.
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr ${lio} tcp dport { 5432, 3003 } accept comment "immich pg (immich_ro) + ML for immich_manager on lio"
    iifname "tailscale0" ip6 saddr ${lio6} tcp dport { 5432, 3003 } accept comment "immich pg + ML for lio (v6)"
    iifname "tailscale0" ip saddr ${h005} tcp dport 9101 accept comment "containers status endpoint, polled by h005"
    iifname "tailscale0" ip6 saddr ${h005_6} tcp dport 9101 accept comment "containers status endpoint (v6)"
  '';
}
