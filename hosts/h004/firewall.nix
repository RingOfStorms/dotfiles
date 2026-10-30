# h004 does not trust tailscale0 (ROUTING-PLAN §5.1). NFS is mounted over the
# LAN (h001 autofs -> 10.12.14.184) and opened to h001 only by nfs-data.nix.
# SSH (ROUTING-PLAN §8 step 2): high-trust tailnet overlay IPs, o002
# excluded, plus a home LAN fallback that rejects low-trust devices. The
# global :22 from hardening.nix is replaced; 41641/udp and icmp stay global.
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
    host = "h004";
    inherit lib;
  };
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "h004";
    })
  ];
}
