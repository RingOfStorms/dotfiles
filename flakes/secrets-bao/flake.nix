{
  description = "Runtime secrets via OpenBao + Zitadel machine key";

  inputs = { };

  outputs = { ... }:
    {
      nixosModules = {
        default = {
          imports = [
            (import ./nixos-module.nix)
            (import ./nixos-configchanges.nix)
          ];
        };
      };
    };
}
