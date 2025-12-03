{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";
    deploy-rs.url = "github:serokell/deploy-rs";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # Use relative to get current version for testing
    # common.url = "path:../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      common,
      secrets,
      beszel,
      ros_neovim,
      deploy-rs,
      ...
    }@inputs:
    let
      configuration_name = "o001";
      system = "aarch64-linux";
      stateVersion = "23.11";
      primaryUser = "root";
      overlayIp = "100.64.0.11";
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
          targetPlatform = system;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${configuration_name};
          };
        };
      };

      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            inherit system;
            specialArgs = {
              inherit inputs;
            };
            modules = [
              home-manager.nixosModules.default
              secrets.nixosModules.default

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.hardening
              common.nixosModules.nix_options
              common.nixosModules.docker
              common.nixosModules.tailnet
              common.nixosModules.zsh

              beszel.nixosModules.agent
              (
                { ... }:
                {
                  beszelAgent = {
                    listen = "${overlayIp}:45876";
                    token = "f8a54c41-486b-487a-a78d-a087385c317b";
                  };
                }
              )

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
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    vaultwarden
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
