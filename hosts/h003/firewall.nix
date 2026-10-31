# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 80/443 are generated
# by the containers host module (ROUTING-PLAN §8 step 2), using runtime sets
# filled per service by cnt deploy. Only explicit nginx.extraWebSources
# remain build-time literals. LAN clients use @src_lan; h003 has no lanIp
# and therefore no static LAN accept.
# SSH is explicit below, not the global hardening.nix allow: 41641/udp, icmp
# and the `containers` temp-ports set stay open on every interface (global
# rules unrelated to this step).
#
# nginx is still the real gate: generated vhosts enforce the tailnet/lan
# exposure ACLs (nginx.acl) and drop edge peers on the internal listener.
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
