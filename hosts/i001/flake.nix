{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # common.url = "path:../../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        secretsRole = "machines-lowtrust";
        authMethod = "initialHashedPassword";
        authValue = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6";
        extraGroups = [ "wheel" "networkmanager" ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.impermanence_mod.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/635D-F0DA";
                primary = "/dev/disk/by-uuid/82cb11a7-097a-4e95-b9f0-47dad95de9df";
                swap = "/dev/disk/by-uuid/29c89516-e6ed-4f91-adf7-646451a8e26f";
              };
              encrypted = true;
              usbKey = true;
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = "luser";
              disableKeyd = true;
            };
          })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_auto
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.tailnet

          ./hardware-configuration.nix
          ./impermanence.nix

          # Host-specific config
          ({ pkgs, lib, ... }: {
            # TODO allowing password auth for now
            services.openssh.settings.PasswordAuthentication = lib.mkForce true;
            networking.networkmanager.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [ fleet.global.sshPubKey ];
            environment.systemPackages = with pkgs; [
              qdirstat google-chrome
            ];
          })
        ];
      };
    };
}
