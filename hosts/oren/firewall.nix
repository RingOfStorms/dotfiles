# oren does not trust tailscale0 (ROUTING-PLAN §5.1). Laptop: serves nothing to
# the tailnet beyond the global allows (22, kdeconnect, 41641/udp, icmp,
# temp-ports, plus the global 9991). The beszel agent connects out to the hub, so
# 45876 stays closed, as on h003. Written while oren was offline: config
# ready, not deployed (applies on its next rebuild).
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
