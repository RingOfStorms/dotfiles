{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    common.url = "path:../../common";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # impermanence.url = "github:nix-community/impermanence";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      self,
      nixpkgs,
      common,
      ros_neovim,
      disko,
      # impermanence,
      ...
    }:
    let
      configuration_name = "testbed";
      lib = nixpkgs.lib;
    in
    {
      packages = {
        x86_64-linux.vm = self.nixosConfigurations.${configuration_name}.config.system.build.vmWithDisko;
      };
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            modules = [
              disko.nixosModules.disko
              # impermanence.nixosModules.impermanence
              common.nixosModules.default
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              ./disko-config.nix
              (
                { config, pkgs, ... }:
                {
                  environment.systemPackages = with pkgs; [
                    cowsay
                    lolcat
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    programs = {
                      ssh.enable = true;
                      podman.enable = true;
                    };
                    users = {
                      admins = [ "luser" ]; # First admin is also the primary user owning nix config
                      users = {
                        root = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                          ];
                          shell = pkgs.zsh;
                        };
                        luser = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
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
