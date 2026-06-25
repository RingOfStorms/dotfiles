{
  description = "o002: Oracle Ampere (aarch64) gateway rebuild. Clean bcachefs + secrets-bao NixOS, installed via nixos-anywhere. Impermanence is toggleable for debugging (enableImpermanence below).";

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

      # ── Impermanence toggle ──────────────────────────────────────────────
      # The first install attempt with impermanence failed to boot (the
      # bcachefs-reset-root service runs in initrd before pivot; untested on
      # Oracle's kernel/firmware). We are debugging it with serial console +
      # initrd-ssh. Flip this to false to fall back to the known-good plain
      # persistent bcachefs root.
      enableImpermanence = true;

      # When impermanence is on, IT owns the runtime fileSystems, so disko
      # must run partition-only (enableConfig = false). When off, disko emits
      # the fileSystems itself.
      diskoModule =
        { lib, ... }:
        {
          imports = [
            inputs.disko.nixosModules.disko
            (import "${inputs.impermanence}/disko-bcachefs.nix" {
              disk = "/dev/sda";
              swapSize = "8G";
              encrypted = false;
            })
          ];
          disko.enableConfig = lib.mkForce (!enableImpermanence);
        };

      impermanenceModules =
        if enableImpermanence then [
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              encrypted = false;
              disk = {
                boot = "/dev/disk/by-partlabel/disk-main-ESP";
                primary = "/dev/disk/by-partlabel/disk-main-primary";
                swap = "/dev/disk/by-partlabel/disk-main-swap";
              };
            };
          })
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence;
          })
          # Debug aids: serial console output + initrd ssh so we can SEE and
          # RECOVER if the impermanence root-reset hangs in initrd.
          ./debug-boot.nix
        ] else [ ];
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

          diskoModule
          ./hardware-configuration.nix
        ] ++ impermanenceModules;
      };
    };
}
