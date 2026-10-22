# h001 does not trust tailscale0 (ROUTING-PLAN §5.1): the tailnet gets exactly
# the ports below. Global allows (22/80/443, 41641/udp, icmp, temp-ports from
# `containers` ports files) still apply on every interface, LAN included.
# The arr UIs are tailnet http routes (containers/arr/service.nix).
# net.private tcp/udp routes (forgejo ssh, immich pg/ML for lio)
# are DNATed by the containers host module (fleet-net-nat), not here.
# jellyfin's old :8096 direct DNAT was removed 2026-10-22.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;

  # Source-limited: nothing else on the tailnet reaches these.
  # Port 9101 (fleet-agent) is opened for h005 by ringofstorms.fleetAgent.
}
