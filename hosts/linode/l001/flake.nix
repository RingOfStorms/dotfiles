{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../../fleet.nix;
      constants = import ./_constants.nix;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        authMethod = "cloudUser";

        nixosModules = [
          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.zsh

          ./hardware-configuration.nix
          ./linode.nix
          ./nginx.nix
          ./headscale.nix
        ];
      };
    };
}
