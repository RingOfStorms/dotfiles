{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    open-webui-nixpkgs.url = "github:nixos/nixpkgs/e9f00bd893984bc8ce46c895c3bf7cac95331127";
    litellm-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    trilium-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    oauth2-proxy-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    common.url = "path:../../common";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      nixarr,
      ...
    }@inputs:
    let
      configuration_name = "h001";
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
              common.nixosModules.default
              ros_neovim.nixosModules.default
              nixarr.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              ./mods
              ./nginx.nix
              ./containers
              (
                { config, pkgs, ... }:
                {
                  environment.systemPackages = with pkgs; [
                    lua
                    sqlite
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    secrets.enable = true;
                    general = {
                      reporting.enable = true;
                    };
                    programs = {
                      tailnet.enable = true;
                      ssh.enable = true;
                      podman.enable = true;
                    };
                    users = {
                      admins = [ "luser" ]; # First admin is also the primary user owning nix config
                      users = {
                        root = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                          ];
                          shell = pkgs.zsh;
                        };
                        luser = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                          ];
                          extraGroups = [
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        luser = {
                          imports = with common.homeManagerModules; [
                            kitty
                            tmux
                            atuin
                            direnv
                            git
                            nix_deprecations
                            postgres
                            ssh
                            starship
                            zoxide
                            zsh
                          ];
                        };
                      };
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
