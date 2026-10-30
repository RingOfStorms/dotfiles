# The dynamic DNAT table is applied by fleet-edge forwards-apply.
# Both NixOS's firewall and router-isolation must admit DNAT traffic.
{ lib, constants, ... }:
let net = constants.network;
in {
  options.ringofstorms.router.forwardRules = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "nft rules for the router-isolation forward chain.";
  };
  config.ringofstorms.router.forwardRules =
    ''iifname "${net.wanInterface}" oifname "${net.vlans.lan.name}" ct status dnat accept'';
}
