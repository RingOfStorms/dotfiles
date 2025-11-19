{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:rycee/home-manager/release-25.05";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    open-webui-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    litellm-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    trilium-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    oauth2-proxy-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    pinchflat-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zitadel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    beszel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      secrets,
      beszel,
      ros_neovim,
      nixarr,
      ...
    }@inputs:
    let
      configuration_name = "h001";
      system = "x86_64-linux";
      stateVersion = "24.11";
      primaryUser = "luser";
      overlayIp = "100.64.0.13";
      lib = nixpkgs.lib;
    in
    {
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
              ros_neovim.nixosModules.default
              (
                { ... }:
                {
                  ringofstorms-nvim.includeAllRuntimeDependencies = true;
                }
              )

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.nix_options
              common.nixosModules.podman
              common.nixosModules.tailnet
              common.nixosModules.timezone_auto
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh

              beszel.nixosModules.agent
              (
                { ... }:
                {
                  beszelAgent = {
                    listen = "${overlayIp}:45876";
                    token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
                  };
                }
              )

              nixarr.nixosModules.default
              ./hardware-configuration.nix
              ./mods
              ./nginx.nix
              ./containers
              (
                { config, pkgs, ... }:
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
                    }) (lib.filterAttrs (name: user: user.isNormalUser or false) users.users);

                    sharedModules = [
                      common.homeManagerModules.tmux
                      common.homeManagerModules.atuin
                      common.homeManagerModules.direnv
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
                      isNormalUser = true;
                      initialPassword = "password1";
                      shell = pkgs.zsh;
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                      ];
                    };
                    root = {
                      shell = pkgs.zsh;
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    sqlite
                    ttyd
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
