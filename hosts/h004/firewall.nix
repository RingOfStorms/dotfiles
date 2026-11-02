# NFS is LAN-only to h001. LAN SSH remains a fallback when the tailnet is
# down, but must reject low-trust devices just like tailnet SSH.
{ fleet, lib, ... }:
let
  fleetLib = import ../../containers/lib.nix;
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "h004"
    ];
  };
  sshHighTrustIps6 = fleetLib.firewallHighTrustIps6 {
    hosts = fleet.hosts;
    exclude = [ "o002" "h004" ];
  };
in
{
  ringofstorms.tailnet.trustInterface = false;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    iifname "tailscale0" ip6 saddr { ${lib.concatStringsSep ", " sshHighTrustIps6} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2, v6)"
    ip saddr ${fleet.global.lanSubnet} tcp dport 22 accept comment "ssh from the home LAN (fallback when the tailnet is down)"
  '';
  networking.nftables.tables.low-trust-lan = fleetLib.lowTrustLanSshTable {
    hosts = fleet.hosts;
    host = "h004";
    inherit lib;
  };
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      ips6 = sshHighTrustIps6;
      hosts = fleet.hosts;
      host = "h004";
    })
  ];
}
