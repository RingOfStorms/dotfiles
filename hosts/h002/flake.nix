{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      ros_neovim,
      ...
    }@inputs:
    let
      configurationName = "h002";
      primaryUser = "luser";
      configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
      stateAndHomeVersion = "25.11";
      overlayIp = "100.64.0.3";
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
              inputs.home-manager.nixosModules.default

              inputs.secrets.nixosModules.default
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
                  boot.loader.grub.device = lib.mkForce "/dev/disk/by-id/ata-KINGSTON_SV300S37A120G_50026B773C00F8F4";
                }
              )
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.no_sleep
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh
              inputs.common.nixosModules.tailnet
              inputs.beszel.nixosModules.agent
              ({
                beszelAgent = {
                  listen = "${overlayIp}:45876";
                  token = "11714da6-fd2e-436a-8b83-e0e07ba33a95";
                };
                services.beszel.agent.environment = {
                  EXTRA_FILESYSTEMS = "sdb__Data";
                };
              })

              ./hardware-configuration.nix
              ./nfs-data.nix
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
                      inputs.common.homeManagerModules.ssh
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
