{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      ...
    }@inputs:
    let
      configurationName = "h002";
      primaryUser = "luser";
      configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
      stateAndHomeVersion = "25.11";
      # overlayIp = "100.64.0.14";
      lib = inputs.nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configurationName}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs;
            };
            modules = [
              inputs.impermanence.nixosModules.impermanence
              inputs.home-manager.nixosModules.default

              # TODO
              # secrets.nixosModules.default
              inputs.ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })

              inputs.common.nixosModules.essentials
              inputs.common.nixosModules.git
              inputs.common.nixosModules.tmux
              inputs.common.nixosModules.boot_grub
              (
                { lib, ... }:
                {
                  boot.loader.grub.device = lib.mkForce "/dev/disk/by-uuid/ca5d2b4d-8964-46c8-99cd-822ac62ac951";
                }
              )
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.no_sleep
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh
              # TODO
              # common.nixosModules.tailnet
              # beszel.nixosModules.agent
              # (
              #   { ... }:
              #   {
              #     beszelAgent = {
              #       listen = "${overlayIp}:45876";
              #       token = "f8a54c41-486b-487a-a78d-a087385c317b";
              #     };
              #   }
              # )

              ./hardware-configuration.nix
              ./hardware-mounts.nix
              ./impermanence.nix
              ./impermanence-tools.nix
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                rec {
                  system.stateVersion = stateAndHomeVersion;

                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = stateAndHomeVersion;
                      programs.home-manager.enable = true;
                    }) (lib.filterAttrs (name: user: user.isNormalUser or false) users.users);

                    sharedModules = [
                      inputs.common.homeManagerModules.tmux
                      inputs.common.homeManagerModules.atuin
                      inputs.common.homeManagerModules.direnv
                      inputs.common.homeManagerModules.git
                      inputs.common.homeManagerModules.postgres_cli_options
                      inputs.common.homeManagerModules.starship
                      inputs.common.homeManagerModules.zoxide
                      inputs.common.homeManagerModules.zsh
                    ];

                    extraSpecialArgs = {
                      inherit inputs;
                    };
                  };

                  # System configuration
                  networking.networkmanager.enable = true;
                  networking.hostName = configurationName;
                  programs.nh.flake = configLocation;
                  nixpkgs.config.allowUnfree = true;
                  # users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      # hashedPassword = ""; # Use if mutable users is false above
                      initialHashedPassword = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6"; # "test" password
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                    root.openssh.authorizedKeys.keys = [
                      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                    ];
                  };
                }
              )
            ];
          }
        );
      };
    };
}
