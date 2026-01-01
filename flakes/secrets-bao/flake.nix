{
  description = "Runtime secrets via OpenBao + Zitadel machine key";

  inputs = { };

  outputs = { ... }:
    {
      nixosModules = {
        default = import ./nixos-module.nix;
      };
    };
}
