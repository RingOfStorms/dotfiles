# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 22, 41641/udp, icmp and
# the `containers` temp-ports set stay open on every interface (global rules).
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;

  # Container vhosts (written by `containers deploy`) are served by the host
  # nginx; nginx is the gate, so the tailnet gets 80/443 and nothing else.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80
    443
  ];

  # Port 9101 (fleet-agent) is opened for h005 by ringofstorms.fleetAgent.
}
