{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:rycee/home-manager/release-25.05";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      secrets,
      beszel,
      ros_neovim,
      ...
    }@inputs:
    let
      configurationName = "h003";
      system = "x86_64-linux";
      stateVersion = "25.05";
      primaryUser = "luser";
      overlayIp = "100.64.0.14";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configurationName}" = (
          lib.nixosSystem {
            inherit system;
            specialArgs = {
              inherit inputs;
            };
            modules = [
              home-manager.nixosModules.default

              secrets.nixosModules.default
              ros_neovim.nixosModules.default

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
                    token = "f8a54c41-486b-487a-a78d-a087385c317b";
                  };
                }
              )

              ./hardware-configuration.nix
              ./mods
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
                  networking.hostName = configurationName;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
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
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3riAQ8RP5JXj2eO87JpjbM/9SrfFHcN5pEJwQpRcOl nix2h003"
                      ];
                    };
                    root = {
                      shell = pkgs.zsh;
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3riAQ8RP5JXj2eO87JpjbM/9SrfFHcN5pEJwQpRcOl nix2h003"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    sqlite
                    ttyd
                    tcpdump
                    dig
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
