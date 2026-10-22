# h001 does not trust tailscale0 (ROUTING-PLAN §5.1): the tailnet gets exactly
# the ports below. Global allows (22/80/443, 41641/udp, icmp, temp-ports from
# `containers` ports files) still apply on every interface, LAN included.
# The arr UIs are tailnet http routes (containers/arr/service.nix).
# net.private tcp/udp routes (forgejo ssh, beszel hub, immich pg/ML for lio)
# are DNATed by the containers host module (fleet-net-nat), not here.
# jellyfin's old :8096 direct DNAT was removed 2026-10-22.
{ fleet, ... }:
let
  h005 = fleet.hosts.h005.overlayIp; # fleet-edge / containers-status poller
  # tailnet v6 addresses of the same hosts (headscale-assigned, stable).
  h005_6 = "fd7a:115c:a1e0::3";
in
{
  ringofstorms.tailnet.trustInterface = false;

  # Source-limited: nothing else on the tailnet reaches these.
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr ${h005} tcp dport 9101 accept comment "containers status endpoint, polled by h005"
    iifname "tailscale0" ip6 saddr ${h005_6} tcp dport 9101 accept comment "containers status endpoint (v6)"
  '';
}
