{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager/master";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    # beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      flatpaks,
      # beszel,
      ros_neovim,
      ...
    }@inputs:
    let
      constants = import ./_constants.nix;
      configuration_name = constants.host.name;
      primaryUser = constants.host.primaryUser;
      stateVersion = constants.host.stateVersion;
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
              inputs.impermanence_mod.nixosModules.default
              ({
                ringofstorms.impermanence = {
                  enable = true;
                  disk = {
                    boot = "/dev/disk/by-uuid/989B-F1AB";
                    primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                    swap = "/dev/disk/by-uuid/ee0ae363-e28c-47ec-8224-6aae026f586f";
                  };
                  encrypted = true;
                  usbKey = true;
                  usbKeyPassword = "Unbiased-Blissful2-Fretted";
                };
              })

              home-manager.nixosModules.default

              inputs.de_plasma.nixosModules.default
              ({
                ringofstorms.dePlasma = {
                  enable = true;
                  gpu.nvidia = {
                    enable = true;
                    open = false; # Proprietary -- open modules caused device creation failures in DXVK/VKD3D-Proton
                  };
                  sddm.autologinUser = primaryUser;
                  wallpapers = [
                    ../../hosts/_shared_assets/wallpapers/pixel_cat_garage.png
                    ../../hosts/_shared_assets/wallpapers/pixel_cats_v.png
                  ];
                };
              })

              ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.jetbrains_font
              common.nixosModules.nix_options
              common.nixosModules.no_sleep
              common.nixosModules.timezone_chi
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh
              common.nixosModules.more_filesystems

              # TODO once tailscale is added in low trust we can start pushing these
              # beszel.nixosModules.agent
              # ({
              #   beszelAgent = {
              #     listen = "${overlayIp}:45876";
              #     token = "TODO"; # Generate and assign a beszel agent token
              #   };
              # })

              flatpaks.nixosModules.default

              ./configuration.nix
              ./hardware-configuration.nix
              (import ./impermanence.nix { inherit primaryUser; })
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
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
                      common.homeManagerModules.foot
                      common.homeManagerModules.git
                      common.homeManagerModules.kitty
                      common.homeManagerModules.launcher_rofi
                      common.homeManagerModules.postgres_cli_options
                      common.homeManagerModules.slicer
                      common.homeManagerModules.ssh
                      common.homeManagerModules.starship
                      common.homeManagerModules.zoxide
                      common.homeManagerModules.zsh
                    ];

                    extraSpecialArgs = {
                      inherit inputs;
                    };
                  };

                  # System configuration
                  system.stateVersion = stateVersion;
                  networking.hostName = configuration_name;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${config.networking.hostName}";
                  nixpkgs.config.allowUnfree = true;
                  users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      hashedPassword = "$y$j9T$HcgOlwo3O7syvUsSQsuyi.$DSe1Cvg.3mtufGxDCmMiJ80uQpAwxjRmdA4EXi9GoF6"; # Generate with: mkpasswd -m yescrypt
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                        "gamemode" # Allow user to request GameMode priority
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    google-chrome
                    vlc
                    jellyfin-media-player
                    ffmpeg-full
                    ttyd
                  ];

                  services.flatpak.packages = [
                    "com.spotify.Client"
                    "com.bitwarden.desktop"
                    "dev.vencord.Vesktop"
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
