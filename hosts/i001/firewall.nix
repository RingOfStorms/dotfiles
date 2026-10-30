# i001 does not trust tailscale0 (ROUTING-PLAN §5.1). i001 is itself
# low-trust (hosts/fleet.nix), so the global :22 (hardening.nix) is replaced
# here: ssh on tailscale0 only from high-trust overlay IPs (ROUTING-PLAN §8
# step 2), o002 excluded, plus a low-trust-filtered home LAN fallback. It
# serves nothing else to the tailnet (no container host module). kdeconnect,
# steam, 41641/udp, icmp and temp-ports stay global (unrelated to this step).
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
    host = "i001";
    inherit lib;
  };
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "i001";
    })
  ];
}
