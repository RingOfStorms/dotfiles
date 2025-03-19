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
    }:
    let
      configuration_name = "h002";
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
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.grub.enable = true;
                    general = {
                      disableRemoteBuildsOnLio = true;
                    };
                    secrets.enable = true;
                    desktopEnvironment.gnome.enable = true;
                    programs = {
                      rustDev.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      docker.enable = true;
                    };
                    users = {
                      admins = [ "josh" ]; # First admin is also the primary user owning nix config
                      users = {
                        josh = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2h002"
                          ];
                          extraGroups = [
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                          packages = with pkgs; [
                            bitwarden
                            vaultwarden
                          ];
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        josh = {
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
