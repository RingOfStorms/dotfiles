{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      common,
      ...
    }@inputs:
    let
      configuration_name = "l001";
      stateVersion = "24.11";
      primaryUser = "root";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs;
            };
            modules = [
              home-manager.nixosModules.default

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.hardening
              common.nixosModules.nix_options
              common.nixosModules.zsh

              ./hardware-configuration.nix
              ./linode.nix
              ./nginx.nix
              ./headscale.nix
              (
                { config, pkgs, ... }:
                rec {
                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = stateVersion;
                      programs.home-manager.enable = true;
                    }) (lib.filterAttrs (name: user: name == "root" || (user.isNormalUser or false)) users.users);

                    sharedModules = [
                      common.homeManagerModules.tmux
                      common.homeManagerModules.atuin
                      common.homeManagerModules.git
                      common.homeManagerModules.postgres_cli_options
                      common.homeManagerModules.starship
                      common.homeManagerModules.zoxide
                      common.homeManagerModules.zsh
                    ];
                  };

                  # System configuration
                  system.stateVersion = stateVersion;
                  networking.hostName = configuration_name;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${configuration_name}";
                  nixpkgs.config.allowUnfree = true;
                  users.users = {
                    "${primaryUser}" = {
                      shell = pkgs.zsh;
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuo6L6V52AzdQIK6fWW9s0aX1yKUUTXbPd8v8IU9p2o nix2linode"
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
