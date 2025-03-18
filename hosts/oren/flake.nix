{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../common";
    common.url = "git+https://git.joshuabell.xyz/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      ...
    }@inputs:
    let
      configuration_name = "oren";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            modules = [
              common.nixosModules.default
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              (import ./containers.nix { inherit inputs; })
              (
                { config, pkgs, ... }:
                {
                  programs = {
                    steam.enable = true;
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    general = {
                      disableRemoteBuildsOnLio = true;
                    };
                    desktopEnvironment.gnome.enable = true;
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      docker.enable = true;
                    };
                    users = {
                      # Users are all normal users and default password is password1
                      admins = [ "josh" ]; # First admin is also the primary user owning nix config
                      users = {
                        josh = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMzgAe4od9K4EsvH2g7xjNU7hGoJiFJlYcvB0BoDCvn nix2oren"
                          ];
                          extraGroups = [
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                          packages = with pkgs; [
                            google-chrome
                            discordo
                            discord
                            spotify
                            vlc
                            vaultwarden
                            bitwarden
                          ];
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        josh = {
                          imports = with common.homeManagerModules; [
                            zsh
                            ssh
                            starship
                            zoxide
                            tmux
                            atuin
                            kitty
                            direnv
                            git
                            nix_deprecations
                            obs
                            postgres
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
