{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testin
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # hyprland.url = "path:../../flakes/hyprland";
    # hyprland.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/hyprland";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      secrets,
      flatpaks,
      beszel,
      ros_neovim,
    nixpkgs-unstable,
      ...
    }@inputs:
    let
      configuration_name = "oren";
      stateVersion = "25.05";
      primaryUser = "josh";
      overlayIp = "100.64.0.5";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            modules = [
              ({
                nixpkgs.overlays = [
                  (final: prev: {
                    unstable = import nixpkgs-unstable {
                      inherit (final) system config;
                    };
                  })
                ];
              })
              home-manager.nixosModules.default

              inputs.de_plasma.nixosModules.default
              ({
                ringofstorms.dePlasma = {
                  enable = true;
                  gpu.amd.enable = true;
                  # TODO once encrypted boot?
                  # sddm.autologinUser = "josh";
                };
              })

              secrets.nixosModules.default
              ros_neovim.nixosModules.default
              (
                {
                  ringofstorms-nvim.includeAllRuntimeDependencies = true;
                }
              )

              flatpaks.nixosModules.default
              # hyprland.nixosModules.default

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.jetbrains_font
              common.nixosModules.nix_options
              common.nixosModules.podman
              common.nixosModules.tailnet
              common.nixosModules.timezone_auto
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh

              beszel.nixosModules.agent
              ({
                  beszelAgent = {
                    listen = "${overlayIp}:45876";
                    token = "f8a54c41-486b-487a-a78d-a087385c317b";
                  };
                }
              )

              ./configuration.nix
              ./hardware-configuration.nix
              # ./sway_customizations.nix
              # ./hyprland_customizations.nix
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
                      common.homeManagerModules.kitty
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
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${config.networking.hostName}";
                  nixpkgs.config.allowUnfree = true;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      initialPassword = "password1";
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMzgAe4od9K4EsvH2g7xjNU7hGoJiFJlYcvB0BoDCvn nix2oren"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                    ffmpeg-full
                    vlc
                    google-chrome
                    ladybird

                    nodejs_24
                    ttyd
                    appimage-run

                    unstable.opencode
                  ];

                  services.flatpak.packages = [
                    "org.signal.Signal"
                    "dev.vencord.Vesktop"
                    "md.obsidian.Obsidian"
                    "com.spotify.Client"
                    "com.bitwarden.desktop"
                    "org.openscad.OpenSCAD"
                    "im.riot.Riot"
                    "com.rustdesk.RustDesk"
                  ];

                  services.devmon.enable = true;
                  services.gvfs.enable = true;
                  services.udisks2.enable = true;

                  networking = {
                    firewall = {
                      allowedTCPPorts = [
                        9991
                      ];
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
