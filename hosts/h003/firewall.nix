# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 22, 41641/udp, icmp and
# the `containers` temp-ports set stay open on every interface (global rules).
#
# 80/443 are opened on every interface by the containers host module
# (ringofstorms.containers.nginx.openFirewall, default with nginx.enable):
# nginx is the gate -- generated vhosts enforce the tailnet/lan exposure ACLs
# (nginx.acl) and drop edge peers on the internal listener.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;

  # Port 9101 (fleet-agent) is opened for h005 by ringofstorms.fleetAgent.
}
