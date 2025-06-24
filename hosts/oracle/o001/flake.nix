{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    deploy-rs.url = "github:serokell/deploy-rs";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
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
      configuration_name = "o001";
      lib = nixpkgs.lib;
    in
    {
      deploy = {
        sshUser = "root";
        sshOpts = [
          "-i"
          "/run/agenix/nix2oracle"
        ];
        nodes.${configuration_name} = {
          hostname = "64.181.210.7";
          targetPlatform = "aarch64-linux";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.${configuration_name};
          };
        };
      };

      nixosConfigurations = {
        nixos = self.nixosConfigurations.${configuration_name};
        "${configuration_name}" = lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            common.nixosModules.default
            ros_neovim.nixosModules.default
            ./configuration.nix
            ./hardware-configuration.nix
            ./nginx.nix
            ./containers/vaultwarden.nix
            ./mods/postgresql.nix
            ./mods/atuin.nix
            ./mods/rustdesk-server.nix
            (
              { pkgs, ... }:
              {
                environment.systemPackages = with pkgs; [
                  bitwarden
                  vaultwarden
                ];

                ringofstorms_common = {
                  systemName = configuration_name;
                  general = {
                    disableRemoteBuildsOnLio = true;
                    readWindowsDrives = false;
                    jetbrainsMonoFont = false;
                    ttyCapsEscape = false;
                    reporting.enable = true;
                  };
                  programs = {
                    tailnet.enable = true;
                    ssh.enable = true;
                    docker.enable = true;
                  };
                  users = {
                    users = {
                      root = {
                        openssh.authorizedKeys.keys = [
                          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle"
                        ];
                        shell = pkgs.zsh;
                      };
                    };
                  };
                  homeManager = {
                    users = {
                      root = {
                        programs.atuin.settings.sync_address = "http://localhost:8888";
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
        };
      };
    };
}
