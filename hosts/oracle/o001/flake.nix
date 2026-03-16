{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # Use relative to get current version for testing
    # common.url = "path:../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      common,
      beszel,
      ros_neovim,
      ...
    }@inputs:
    let
      constants = import ./_constants.nix;
      configuration_name = constants.host.name;
      stateVersion = constants.host.stateVersion;
      primaryUser = constants.host.primaryUser;
      overlayIp = constants.host.overlayIp;
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs constants;
            };
            modules = [
              home-manager.nixosModules.default

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

              inputs.secrets-bao.nixosModules.default
              (
                { inputs, lib, ... }:
                lib.mkMerge [
                  {
                    ringofstorms.secretsBao = {
                      enable = true;
                      openBaoRole = "machines-hightrust";
                      inherit (constants) secrets;
                    };
                  }
                  (inputs.secrets-bao.lib.applyChanges constants.secrets)
                ]
              )

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
                      common.homeManagerModules.ssh
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
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
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
