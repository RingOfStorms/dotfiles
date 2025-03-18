{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    deploy-rs.url = "github:serokell/deploy-rs";
    common.url = "git+https://git.joshuabell.xyz/dotfiles";
    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
  };

  outputs =
    {
      self,
      nixpkgs,
      common,
      ros_neovim,
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
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              ./linode.nix
              ./nginx.nix
              ./headscale.nix
              (
                { config, pkgs, ... }:
                {
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuo6L6V52AzdQIK6fWW9s0aX1yKUUTXbPd8v8IU9p2o nix2linode"
                  ];

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
                      # Users are all normal users and default password is password1
                      admins = [ "luser" ]; # First admin is also the primary user owning nix config
                      users = {
                        luser = {
                          extraGroups = [
                            "networkmanager"
                          ];
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuo6L6V52AzdQIK6fWW9s0aX1yKUUTXbPd8v8IU9p2o nix2linode"
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
                        luser = {
                          imports = with common.homeManagerModules; [
                            tmux
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
