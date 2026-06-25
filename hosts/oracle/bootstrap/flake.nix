{
  description = "Reusable Oracle Ampere (aarch64) bootstrap: clean bcachefs + impermanence + secrets-bao NixOS, installable via nixos-anywhere. Copy to hosts/oracle/<name>/ and layer services on top.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager.url = "github:rycee/home-manager/release-26.05";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

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
      primaryUser = constants.host.primaryUser;
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

          # bcachefs + impermanence (boot-time root reset). Disk UUIDs are
          # captured AFTER the disko partition step and filled in here.
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              encrypted = false;
              # Use disko's deterministic GPT partition labels (the
              # partition keys ESP/swap/primary in disko-bcachefs.nix), so
              # these paths exist immediately after partitioning without
              # needing to capture UUIDs first. Switch to by-uuid later if
              # desired (capture via `lsblk -o name,uuid`).
              disk = {
                boot = "/dev/disk/by-partlabel/ESP";
                primary = "/dev/disk/by-partlabel/primary";
                swap = "/dev/disk/by-partlabel/swap";
              };
            };
          })

          # disko partition config (partition-only; impermanence owns mounts)
          (import ./disko.nix {
            inherit (inputs) disko impermanence;
          })

          ./hardware-configuration.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence;
          })
        ];
      };
    };
}
