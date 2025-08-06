{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    # Use relative to get current version for testing
    # common.url = "path:../../common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      ...
    }:
    let
      configuration_name = "h003";
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
              # ./networking.nix
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
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3riAQ8RP5JXj2eO87JpjbM/9SrfFHcN5pEJwQpRcOl nix2h003"
                          ];
                          shell = pkgs.zsh;
                        };
                        luser = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3riAQ8RP5JXj2eO87JpjbM/9SrfFHcN5pEJwQpRcOl nix2h003"
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
