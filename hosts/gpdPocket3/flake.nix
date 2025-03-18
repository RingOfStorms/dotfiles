{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    # for local testing.
    # common.url = "path:../../common
    common.url = "git+https://git.joshuabell.xyz/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      ...
    }:
    let
      configuration_name = "gpdPocket3";
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
              (
                { config, pkgs, ... }:
                {
                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    desktopEnvironment.gnome.enable = true;
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
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
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDa0MUnXwRzHPTDakjzLTmye2GTFbRno+KVs0DSeIPb7 nix2gpdpocket3"
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
                            vlc
                          ];
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        josh = {
                          imports = with common.homeManagerModules; [
                            tmux
                            atuin
                            kitty
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
