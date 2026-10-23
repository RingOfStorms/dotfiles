# h005 does not trust tailscale0 (ROUTING-PLAN §5.1). Only tailscale0 input is
# affected: LAN/VLAN/WAN rules (mods/networking.nix, adguardhome.nix), the
# router forward/NAT tables and fail2ban are untouched. 22 and 41641/udp stay
# global; 443 on tailscale0 comes from private-zone.nix.
#
# M3: joe/i001 are low-trust LAN devices (hosts/fleet.nix, trust = "low").
# They still need DNS/DHCP/NTP on the lan VLAN, but must never reach h005
# SSH (:22) or the AdGuard Home admin UI (:3000, mods/adguardhome.nix).
#
# Why not networking.firewall.extraInputRules: NixOS appends those at the END
# of nixos-fw's input-allow chain, after the allowedTCPPorts accepts (global
# :22, and adguardhome.nix's iifname "lan" :3000). `accept` ends nixos-fw
# evaluation, so a drop there never fired (verified live 2026-10-22). Instead
# a separate inet table with an input base chain at priority -10 runs BEFORE
# nixos-fw (priority filter = 0; cf. fleet-net at -5). A drop in any base
# chain is final; policy accept hands everything else to nixos-fw unchanged.
{ fleet, lib, ... }:
let
  lowTrustLanIps = builtins.filter (ip: ip != null) (
    lib.mapAttrsToList (
      _name: h: if (h.trust or null) == "low" then h.lanIp or null else null
    ) fleet.hosts
  );
in
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
