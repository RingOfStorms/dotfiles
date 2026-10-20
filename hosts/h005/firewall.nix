# h005 does not trust tailscale0 (ROUTING-PLAN §5.1). Only tailscale0 input is
# affected: LAN/VLAN/WAN rules (mods/networking.nix, adguardhome.nix), the
# router forward/NAT tables and fail2ban are untouched. 22 and 41641/udp stay
# global; 443 on tailscale0 comes from private-zone.nix.
{ ... }:
{
  ringofstorms.tailnet.trustInterface = false;

  networking.firewall.interfaces.tailscale0 = {
    # Tailnet split-DNS (dnsmasq on 100.64.0.3:53): every tailnet client.
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [
      53
      80 # nginx on the overlay IP: fleet-edge dashboard / private-zone redirects
    ];
  };
}
