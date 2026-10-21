# joe does not trust tailscale0 (ROUTING-PLAN §5.1). Global allows (22,
# kdeconnect, steam, 41641/udp, icmp, temp-ports) are unchanged.
{ fleet, ... }:
let
  h005 = fleet.hosts.h005; # private-zone proxy (*.ts.joshuabell.xyz)
in
{
  ringofstorms.tailnet.trustInterface = false;

  # LocalAI (containers/localai, podman publish 100.64.0.12:8080) is reached
  # only through h005's private-zone vhost localai.ts.joshuabell.xyz. The port
  # is DNATed by netavark, so input rules can't filter it; this filters in
  # prerouting before the DNAT (containers host-module).
  ringofstorms.containers.publishedPorts = [
    {
      address = fleet.hosts.joe.overlayIp;
      port = 8080;
      from = [
        h005.overlayIp
        "fd7a:115c:a1e0::3"
      ];
      comment = "localai, only via h005 private-zone proxy";
    }
  ];
}
