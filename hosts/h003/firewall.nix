# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 22, 41641/udp, icmp and
# the `containers` temp-ports set stay open on every interface (global rules).
{ fleet, ... }:
let
  h005 = fleet.hosts.h005.overlayIp; # polls the containers status endpoint
in
{
  ringofstorms.tailnet.trustInterface = false;

  # Container vhosts (written by `containers deploy`) are served by the host
  # nginx; nginx is the gate, so the tailnet gets 80/443 and nothing else.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80
    443
  ];

  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr ${h005} tcp dport 9101 accept comment "containers status endpoint, polled by h005"
    iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::3 tcp dport 9101 accept comment "containers status endpoint (v6)"
  '';
}
