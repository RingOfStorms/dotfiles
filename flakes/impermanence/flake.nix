{
  description = "Reusable bcachefs impermanence module with encrypted subvolume layout, boot-time root reset, and snapshot management tools.";

  inputs = {
    impermanence.url = "github:nix-community/impermanence";
    disko.url = "github:nix-community/disko/latest";
  };

  outputs = { impermanence, disko, ... }: {
    nixosModules = {
      default =
        { config, lib, pkgs, ... }:
        {
          imports = [
            impermanence.nixosModules.impermanence
            ./bcachefs-impermanence.nix
          ];
        };
    };

    # Standalone disko config for partitioning at install time.
    # Usage from a NixOS live ISO:
    #   sudo nix --experimental-features "nix-command flakes" run \
    #     github:nix-community/disko/latest -- \
    #     --mode destroy,format,mount ./disko-bcachefs.nix \
    #     --arg disk '"/dev/nvme0n1"' \
    #     --arg swapSize '"16G"' \
    #     --arg encrypted true
    #
    # Or reference from a flake:
    #   sudo nix run github:nix-community/disko/latest -- \
    #     --mode destroy,format,mount \
    #     --flake "path:../../flakes/impermanence#bcachefs-impermanence" \
    #     --arg disk '"/dev/nvme0n1"' --arg swapSize '"16G"' --arg encrypted true
    diskoConfigurations.bcachefs-impermanence = import ./disko-bcachefs.nix;
  };
}
