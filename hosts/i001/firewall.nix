# i001 does not trust tailscale0 (ROUTING-PLAN §5.1). It serves nothing to the
# tailnet beyond the global allows (22, kdeconnect, steam, 41641/udp, icmp,
# temp-ports), so no tailscale0-specific rules are needed.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
