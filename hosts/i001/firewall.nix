# Being a low-trust node does not make its SSH public: management still
# requires a high-trust peer, with a low-trust-filtered LAN fallback.
{ fleet, lib, ... }:
let
  fleetLib = import ../../containers/lib.nix;
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "i001"
    ];
  };
  sshHighTrustIps6 = fleetLib.firewallHighTrustIps6 {
    hosts = fleet.hosts;
    exclude = [ "o002" "i001" ];
  };
in
{
  ringofstorms.tailnet.trustInterface = false;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only"
    iifname "tailscale0" ip6 saddr { ${lib.concatStringsSep ", " sshHighTrustIps6} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (v6)"
    ip saddr ${fleet.global.lanSubnet} tcp dport 22 accept comment "ssh from the home LAN (fallback when the tailnet is down)"
  '';
  networking.nftables.tables.low-trust-lan = fleetLib.lowTrustLanSshTable {
    hosts = fleet.hosts;
    host = "i001";
    inherit lib;
  };
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      ips6 = sshHighTrustIps6;
      hosts = fleet.hosts;
      host = "i001";
    })
  ];
}
