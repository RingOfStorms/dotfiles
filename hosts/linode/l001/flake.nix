{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    home-manager.url = "github:rycee/home-manager/release-24.11";
    deploy-rs.url = "github:serokell/deploy-rs";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?rev=39edfefa5871d07c9f88ce92a55995eb347d9b09";
    common.inputs.home-manager.follows = "home-manager";
  };

  outputs =
    {
      self,
      nixpkgs,
      common,
      deploy-rs,
      ...
    }:
    let
      configuration_name = "l001";
      lib = nixpkgs.lib;
    in
    {
      deploy = {
        sshUser = "root";
        sshOpts = [
          "-i"
          "/run/agenix/nix2linode"
        ];
        nodes.${configuration_name} = {
          hostname = "172.236.111.33";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${configuration_name};
          };
        };
      };

      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            modules = [
              common.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              ./linode.nix
              ./nginx.nix
              ./headscale.nix
              (
                { config, pkgs, ... }:
                {
                  ringofstorms_common = {
                    systemName = configuration_name;
                    general = {
                      disableRemoteBuildsOnLio = true;
                      readWindowsDrives = false;
                      jetbrainsMonoFont = false;
                      ttyCapsEscape = false;
                    };
                    programs = {
                      ssh.enable = true;
                    };
                    users = {
                      users = {
                        root = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuo6L6V52AzdQIK6fWW9s0aX1yKUUTXbPd8v8IU9p2o nix2linode"
                          ];
                          shell = pkgs.zsh;
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        root = {
                          imports = with common.homeManagerModules; [
                            tmux
                            atuin
                            git
                            postgres
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
