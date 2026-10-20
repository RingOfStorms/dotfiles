# DRAFT, not imported yet (see the note at the end). lio stops trusting
# tailscale0 (ROUTING-PLAN §5.1). configuration.nix already closes the global
# allow-list and opens 22 on tailscale0 + LAN; this adds only what other
# tailnet hosts need from lio.
#
# Fill the TODOs from the snapshot (as root on lio):
#   ss -ltunpH | grep -v -E '127\.0\.0\.|\[::1\]'      # who owns :80, :5000
#   conntrack -L -d 100.64.0.1 | grep -v 'dport=22 '   # tailnet inbound flows
#   nft list ruleset > /tmp/lio.nft
# then import ./firewall.nix in flake.nix and `nixos-rebuild test` first.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;

  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      # 22 is already opened in configuration.nix.
      # TODO 80   nginx (0.0.0.0:80): keep only if another host uses it
      # TODO 5000 (0.0.0.0:5000, owner unknown without root): keep only if used
    ];
    allowedUDPPorts = [
      # TODO: KDE Connect (1714-1764 tcp/udp) if phones pair over the tailnet
    ];
  };
}
