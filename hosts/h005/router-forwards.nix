# WAN port forwards for public `via = router` tcp/udp routes
# (containers/ROUTING-PLAN.md §2.4, §8 step 4). Generated from
# containers/*/service.nix (containers/lib.nix routerForwards) at build time,
# like dns-records.nix: a forward exists only while its service has a host.
# An empty list changes nothing in the ruleset.
#
# IPv4 only: DNAT from the WAN to the host's LAN IP via the NixOS nat module.
# Two forward chains must both accept a forwarded packet:
#   - nixos-fw forward: already accepts `ct status dnat` before its final drop;
#   - router-isolation (mods/networking.nix, policy drop): gets the
#     `forwardRules` below, narrowed to WAN -> LAN, exact target and port.
# No hairpin NAT: LAN clients get the LAN answer from h005's DNS
# (dns-records.nix), per §6 item 18.
{
  config,
  lib,
  constants,
  fleet,
  ...
}:
let
  net = constants.network;
  forwards = (import ../../containers/lib.nix).routerForwards {
    dir = ../../containers;
    inherit (fleet) hosts;
  };
in
{
  options.ringofstorms.router.forwardRules = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "nft rules for the router-isolation forward chain (generated forwards).";
  };

  config = {
    networking.nat.forwardPorts = map (f: {
      inherit (f) proto;
      sourcePort = f.port;
      destination = "${f.ip}:${toString f.port}";
    }) forwards;

    ringofstorms.router.forwardRules = lib.concatMapStringsSep "\n" (
      f:
      ''iifname "${net.wanInterface}" oifname "${net.vlans.lan.name}" ip daddr ${f.ip} ${f.proto} dport ${toString f.port} ct status dnat accept comment "${f.source}"''
    ) forwards;
  };
}
