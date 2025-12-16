{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      ...
    }@inputs:
    let
      configurationName = "MACHINE_HOST_NAME";
      primaryUser = "luser";
      configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
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
              ({
                nixpkgs.overlays = [
                  (final: prev: {
                    unstable = import inputs.nixpkgs-unstable {
                      inherit (final) system config;
                    };
                  })
                ];
              })

              # Bcachefs test, #TODO move to a module
              (
                { pkgs, ... }:
                {
                  boot.supportedFilesystems = [ "bcachefs" ];
                  environment.systemPackages = with pkgs; [
                    keyutils
                  ];
                }
              )

              # inputs.impermanence.nixosModules.impermanence
              inputs.home-manager.nixosModules.default

              inputs.ros_neovim.nixosModules.default
              (
                { ... }:
                {
                  ringofstorms-nvim.includeAllRuntimeDependencies = true;
                }
              )

              inputs.common.nixosModules.essentials
              inputs.common.nixosModules.git
              inputs.common.nixosModules.tmux
              # TODO PICK ONE
              # inputs.common.nixosModules.boot_systemd
              # inputs.common.nixosModules.boot_grub
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.jetbrains_font
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.no_sleep
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh

              ./hardware-configuration.nix
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                rec {
                  # TODO ensure matches configuration.nix, and add anything else from there that is needed
                  system.stateVersion = "25.11";
                  # TODO get latest or use linuxPackages_latest
                  # not sure what I should
                  # boot.kernelPackages = pkgs.linuxPackages_6_18;

                  # No ssh pub keys setup yet, allow password login, TODO remove
                  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = "25.11";
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
                  networking.hostName = configurationName;
                  programs.nh.flake = configLocation;
                  nixpkgs.config.allowUnfree = true;
                  users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      hashedPassword = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6"; # "test" password
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                      ];
                      openssh.authorizedKeys.keys = [
                        # TODO setup public keys
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                  };
                }
              )
            ];
          }
        );
      };
    };
}
