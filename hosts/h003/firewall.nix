# Container HTTP admission follows runtime sets. With no lanIp, h003 uses
# @src_lan rather than a static LAN accept. Vhost ACLs remain the final gate
# and reject edge peers on the internal listener.
{ fleet, lib, ... }:
let
  fleetLib = import ../../containers/lib.nix;
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "h003"
    ];
  };
in
{
  ringofstorms.tailnet.trustInterface = false;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];

  # Port 9101 (fleet-agent) is opened for h005 by ringofstorms.fleetAgent.
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    ip saddr ${fleet.global.lanSubnet} tcp dport 22 accept comment "ssh from the home LAN (fallback when the tailnet is down)"
  '';

  networking.nftables.tables.low-trust-lan = fleetLib.lowTrustLanSshTable {
    hosts = fleet.hosts;
    host = "h003";
    inherit lib;
  };

  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "h003";
    })
  ];
}
