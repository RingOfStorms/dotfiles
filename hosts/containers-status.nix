# Read-only status endpoint for fleet-edge (containers/ROUTING-PLAN.md §5.4).
# Imported by every floating-container host (inventory `containerHosts`);
# listens on the host's overlay IP from fleet.nix, port 9101.
{ config, fleet, ... }:
{
  ringofstorms.containers.statusEndpoint = {
    enable = true;
    listen = "${fleet.hosts.${config.networking.hostName}.overlayIp}:9101";
  };
}
