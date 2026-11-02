# Container HTTP admission follows runtime ports files; only hand-written
# vhosts use nginx.extraWebSources. Private raw routes use fleet-net-nat.
#
# Low-trust LAN devices may use public services but must not reach SSH.
# Their drop runs in a separate priority -10 input chain because NixOS
# extraInputRules follow port accepts. A drop in any base chain is final;
# policy accept continues into nixos-fw.
{ fleet, lib, ... }:
let
  fleetLib = import ../../containers/lib.nix;
  # LAN SSH is a fallback when the tailnet is down, not a low-trust bypass.
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "h001"
    ];
  };
  sshHighTrustIps6 = fleetLib.firewallHighTrustIps6 {
    hosts = fleet.hosts;
    exclude = [ "o002" "h001" ];
  };
in
{
  ringofstorms.tailnet.trustInterface = false;
  # Replaces the global :22 from hardening.nix: ssh is scoped below.
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];

  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    iifname "tailscale0" ip6 saddr { ${lib.concatStringsSep ", " sshHighTrustIps6} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2, v6)"
    ip saddr ${fleet.global.lanSubnet} tcp dport 22 accept comment "ssh from the home LAN (fallback when the tailnet is down)"
  '';

  # Lockout guard: fails eval (not just deploy) if sshHighTrustIps is empty
  # or would exclude lio.
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      ips6 = sshHighTrustIps6;
      hosts = fleet.hosts;
      host = "h001";
    })
  ];

  networking.nftables.tables.low-trust-lan = fleetLib.lowTrustLanSshTable {
    hosts = fleet.hosts;
    host = "h001";
    inherit lib;
  };
}
