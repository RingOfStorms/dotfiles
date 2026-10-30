# joe does not trust tailscale0 (ROUTING-PLAN §5.1). joe is itself low-trust
# (hosts/fleet.nix), so the global :22 (hardening.nix) is replaced here: ssh
# on tailscale0 only from high-trust overlay IPs (ROUTING-PLAN §8 step 2),
# o002 excluded, plus a low-trust-filtered home LAN fallback. kdeconnect,
# steam, 41641/udp, icmp and temp-ports stay global (unrelated to this step).
#
# LocalAI (containers/localai) publishes on 127.0.0.1:8080 only; clients
# reach it through joe's own nginx on :443 (containers host module, opened
# by the generated per-host rule below: joe has one tailnet http route),
# whose vhost applies the route's allow list.
{ fleet, lib, ... }:
let
  fleetLib = import ../../containers/lib.nix;
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "joe"
    ];
  };
in
{
  ringofstorms.tailnet.trustInterface = false;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    ip saddr ${fleet.global.lanSubnet} tcp dport 22 accept comment "ssh from the home LAN (fallback when the tailnet is down)"
  '';
  networking.nftables.tables.low-trust-lan = fleetLib.lowTrustLanSshTable {
    hosts = fleet.hosts;
    host = "joe";
    inherit lib;
  };
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "joe";
    })
  ];
}
