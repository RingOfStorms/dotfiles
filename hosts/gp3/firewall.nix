# gp3 does not trust tailscale0 (ROUTING-PLAN §5.1). Laptop: serves nothing to
# the tailnet beyond the global allows (22, kdeconnect, 41641/udp, icmp,
# temp-ports). No beszel agent. Written while gp3 was offline: config
# ready, not deployed (applies on its next rebuild).
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
