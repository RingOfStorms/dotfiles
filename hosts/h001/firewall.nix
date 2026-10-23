# h001 does not trust tailscale0 (ROUTING-PLAN §5.1): the tailnet gets exactly
# the ports below. Global allows (22/80/443, 41641/udp, icmp, temp-ports from
# `containers` ports files) still apply on every interface, LAN included.
# The arr UIs are tailnet http routes (containers/arr/service.nix).
# net.private tcp/udp routes (forgejo ssh, immich pg/ML for lio)
# are DNATed by the containers host module (fleet-net-nat), not here.
# jellyfin's old :8096 direct DNAT was removed 2026-10-22.
#
# M3: joe/i001 are low-trust LAN devices (hosts/fleet.nix, trust = "low").
# They still need DNS/DHCP/NTP and h001's public 80/443 routes, but must
# never SSH into h001 management.
#
# Why not networking.firewall.extraInputRules: NixOS appends those at the END
# of nixos-fw's input-allow chain, after the allowedTCPPorts accepts (global
# :22 from hardening.nix). `accept` ends nixos-fw evaluation, so a drop there
# never fired (verified live 2026-10-22). Instead a separate inet table with an
# input base chain at priority -10 runs BEFORE nixos-fw (priority filter = 0;
# cf. fleet-net at -5). A drop in any base chain is final; policy accept hands
# everything else to nixos-fw unchanged.
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

  # Source-limited: nothing else on the tailnet reaches these.
  # Port 9101 (fleet-agent) is opened for h005 by ringofstorms.fleetAgent.

  networking.nftables.tables.low-trust-lan = lib.mkIf (lowTrustLanIps != [ ]) {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority -10; policy accept;
        ip saddr { ${lib.concatStringsSep ", " lowTrustLanIps} } tcp dport 22 counter drop comment "M3: low-trust LAN devices must not reach h001 SSH"
      }
    '';
  };
}
