# h005 does not trust tailscale0 (ROUTING-PLAN §5.1). Only tailscale0 input is
# affected: LAN/VLAN/WAN rules (mods/networking.nix, adguardhome.nix), the
# router forward/NAT tables and fail2ban are untouched. 22 and 41641/udp stay
# global on the LAN/management VLANs (mods/networking.nix, unchanged by this
# file): h005 is the router, so LAN ssh is a real admin need, kept as-is.
# tailscale0: ssh and 80/443 (fleet-edge dashboard, oauth2-proxy sso-proxy)
# are scoped below to high-trust overlay IPs only (ROUTING-PLAN §8 step 2),
# o002 and low-trust nodes excluded; 53 tcp/udp (tailnet split-DNS) stays for
# every tailnet client, since every tailnet host needs DNS to resolve.
#
# M3: joe/i001 are low-trust LAN devices (hosts/fleet.nix, trust = "low").
# They still need DNS/DHCP/NTP on the lan VLAN, but must never reach h005
# SSH (:22) or the AdGuard Home admin UI (:3000, mods/adguardhome.nix).
#
# Why not networking.firewall.extraInputRules for the low-trust drop below:
# NixOS appends those at the END of nixos-fw's input-allow chain, after the
# allowedTCPPorts/extraInputRules accepts (global :22 on LAN/mng, and
# adguardhome.nix's iifname "lan" :3000). `accept` ends nixos-fw evaluation,
# so a drop there never fired (verified live 2026-10-22). Instead a separate
# inet table with an input base chain at priority -10 runs BEFORE nixos-fw
# (priority filter = 0; cf. fleet-net at -5). A drop in any base chain is
# final; policy accept hands everything else to nixos-fw unchanged.
{ fleet, lib, ... }:
let
  lowTrustLanIps = builtins.filter (ip: ip != null) (
    lib.mapAttrsToList (
      _name: h: if (h.trust or null) == "low" then h.lanIp or null else null
    ) fleet.hosts
  );
  fleetLib = import ../../containers/lib.nix;
  highTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "h005"
    ];
  };
  excludedTailnetHttpIps = builtins.filter (ip: ip != (fleet.hosts.h005.overlayIp or null)) (
    fleetLib.tailnetExcludedOverlayIps fleet.hosts
  );
in
{
  ringofstorms.tailnet.trustInterface = false;

  networking.firewall.interfaces.tailscale0 = {
    # Tailnet split-DNS (dnsmasq on 100.64.0.3:53): every tailnet client.
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };

  # Generated (ROUTING-PLAN §8 step 2): ssh from high-trust overlay IPs
  # only; h005's own http (fleet-edge dashboard, oauth2-proxy sso-proxy)
  # from every tailnet peer (100.64.0.0/10, incl. phones/unlisted nodes),
  # minus o002 and low-trust nodes -- explicit drops first so they can't
  # be shadowed, then the broad accept.
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " highTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    ${lib.concatMapStrings (
      ip:
      ''iifname "tailscale0" ip saddr ${ip} tcp dport { 80, 443 } drop comment "generated: h005 own http, excluded (ROUTING-PLAN 8.2)"''
      + "\n"
    ) excludedTailnetHttpIps}
    iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport { 80, 443 } accept comment "generated: h005 own http, tailnet (ROUTING-PLAN 8.2)"
  '';

  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = highTrustIps;
      hosts = fleet.hosts;
      host = "h005";
    })
  ];

  networking.nftables.tables.low-trust-lan = lib.mkIf (lowTrustLanIps != [ ]) {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority -10; policy accept;
        ip saddr { ${lib.concatStringsSep ", " lowTrustLanIps} } tcp dport { 22, 3000 } counter drop comment "M3: low-trust LAN devices must not reach h005 SSH / AdGuard admin UI"
      }
    '';
  };
}
