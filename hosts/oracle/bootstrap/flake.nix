{
  description = "Reusable Oracle Ampere (aarch64) bootstrap: clean bcachefs + impermanence + secrets-bao NixOS, installable via nixos-anywhere. Copy to hosts/oracle/<name>/ and layer services on top. See hosts/oracle/readme.md for the full onboarding runbook.";

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
      # bcachefs + impermanence (boot-time root reset) is the intended end
      # state and is proven working on o002. Set to false for a plain
      # persistent bcachefs root (e.g. to bisect a boot problem).
      #
      # IMPORTANT (fresh nixos-anywhere installs): the impermanence root-reset
      # wipes @root on first boot. On a brand-new install /persist is empty,
      # so the first reset destroys ssh host keys / machine-id with nothing to
      # restore => unreachable headless box. The reliable onboarding sequence
      # is documented in hosts/oracle/readme.md: install with
      # enableImpermanence = false first, let it boot + populate /persist via a
      # nixos-rebuild that flips this to true, THEN reboot. (Activation seeds
      # /persist BEFORE the first reset.)
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
              encrypted = false; # headless cloud box: no console/USB to unlock
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
              # disko's deterministic GPT partition labels (disk-main-<key>).
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
          # Serial console (ttyAMA0) + initrd ssh: recovery aids for this
          # headless impermanence box. Needs /persist/initrd/ssh_host_ed25519_key
          # on the target (see readme).
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
