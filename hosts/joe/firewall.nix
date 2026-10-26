# joe does not trust tailscale0 (ROUTING-PLAN §5.1). Global allows (22,
# kdeconnect, steam, 41641/udp, icmp, temp-ports) are unchanged.
#
# LocalAI (containers/localai) publishes on 127.0.0.1:8080 only; clients
# reach it through joe's own nginx on :443 (containers host module, opened
# by nginx.openFirewall), whose vhost applies the route's allow list.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;
}
