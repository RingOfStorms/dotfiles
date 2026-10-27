# h004 does not trust tailscale0 (ROUTING-PLAN §5.1). NFS is mounted over the
# LAN (h001 autofs -> 10.12.14.184) and opened to h001 only by nfs-data.nix.
# SSH (ROUTING-PLAN §8 step 2): high-trust tailnet overlay IPs only, o002
# excluded; no LAN ssh need here, so the global :22 from hardening.nix is
# replaced, not kept. 41641/udp and icmp stay global.
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
  '';
  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "h004";
    })
  ];
}
