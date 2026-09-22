{
  description = "Paseo daemon wrapper with local NixOS defaults and sandbox policy hooks";

  inputs = {
    paseo = {
      url = "github:getpaseo/paseo/135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, paseo, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system: {
        default = paseo.packages.${system}.default;
        paseo = paseo.packages.${system}.paseo;
        desktop = paseo.packages.${system}.desktop;
      });

      nixosModules = {
        # Preserve the upstream module as the baseline. This is deliberately
        # separate from the local policy module so upstream option behavior is
        # easy to compare during upgrades.
        upstream = paseo.nixosModules.default;
        paseo = import ./module.nix { inherit paseo; };
        default = self.nixosModules.paseo;
      };

      overlays.default = final: prev: {
        paseo = self.packages.${final.stdenv.hostPlatform.system}.paseo;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
