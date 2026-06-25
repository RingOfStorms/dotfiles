{
  description = "o002: Oracle Ampere (aarch64) gateway rebuild. Clean bcachefs (persistent root, no impermanence yet) + secrets-bao NixOS, installed via nixos-anywhere.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # impermanence flake is referenced ONLY for its shared disko-bcachefs.nix
    # layout file (disko.nix). The impermanence boot-time root-reset is NOT
    # enabled here yet — see hardware-configuration.nix notes. We start with a
    # plain persistent bcachefs root to de-risk the first boot, then can layer
    # impermanence on as a validated second step.
    # impermanence.url = "path:../../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # common.url = "path:../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # beszel.url = "path:../../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
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
        secretsRole = "machines-hightrust";
        authMethod = "cloudUser";

        nixosModules = [
          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.backup

          # disko: partitions AND emits the runtime fileSystems for the
          # bcachefs subvolumes (enableConfig = true, set in disko.nix). No
          # impermanence => disko owns the mounts. Plain persistent root.
          (import ./disko.nix {
            inherit (inputs) disko impermanence;
          })

          ./hardware-configuration.nix
        ];
      };
    };
}
