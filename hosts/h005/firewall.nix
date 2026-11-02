# The router keeps LAN management access, but tailscale0 is untrusted.
# Every tailnet client needs split DNS; management and HTTP exclude the edge
# and low-trust nodes. Low-trust LAN devices need DNS/DHCP/NTP, not SSH or
# the AdGuard admin UI.
#
# The low-trust drop needs a separate input chain at priority -10: NixOS
# appends extraInputRules after its port accepts, where a drop is too late.
# A drop in any base chain is final; policy accept continues into nixos-fw.
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

  # Exclusions precede the broad HTTP accept so low-trust peers cannot
  # inherit access intended for tailnet clients, including unlisted phones.
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
