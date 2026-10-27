# h003 does not trust tailscale0 (ROUTING-PLAN §5.1). 80/443 are generated
# by the containers host module (ROUTING-PLAN §8 step 2: high-trust overlay
# IPs only, o002 excluded; LAN interface too once/if a service.nix declares
# host = "h003" with a lan/public route -- h003 has none today).
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
  '';

  assertions = [
    (fleetLib.sshGuardAssertion {
      ips = sshHighTrustIps;
      hosts = fleet.hosts;
      host = "h003";
    })
  ];
}
