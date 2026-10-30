# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 80/443 are generated
# by the containers host module (ROUTING-PLAN §8 step 2): the build-time
# sources are the http routes declared with host = "h003" in the inventory
# (containers/lib.nix webSourcesByHost) plus nginx.extraWebSources. The
# runtime half is written per service by `containers deploy` from that
# service's own routes, so a service moved here is admitted without h003
# declaring it. LAN clients on 80/443 arrive through the runtime `@src_lan`
# rule: h003 has no lanIp, so the build-time LAN accept the host module emits
# for hosts with one is not generated here, and the runtime set covers it.
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
