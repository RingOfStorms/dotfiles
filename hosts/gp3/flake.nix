{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager/master";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";

    opencode.url = "github:anomalyco/opencode/c6262f9d4002d86a1f1795c306aa329d45361d12";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      flatpaks,
      ros_neovim,
      ...
    }@inputs:
    let
      constants = import ./_constants.nix;
      configuration_name = constants.host.name;
      stateVersion = constants.host.stateVersion;
      primaryUser = constants.host.primaryUser;
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
              inputs.nixos-hardware.nixosModules.gpd-pocket-3
              inputs.impermanence_mod.nixosModules.default
              ({
                ringofstorms.impermanence = {
                  enable = true;
                  disk = {
                    boot = "/dev/disk/by-uuid/D1C3-B6B2";
                    primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                    swap = "/dev/disk/by-uuid/4b56d370-63e8-4613-bf46-c3fc4ad2aa70";
                  };
                  encrypted = true;
                  usbKey = true;
                  usbKeyPassword = "brought-upside-twentieth";
                };
              })

              home-manager.nixosModules.default

              inputs.de_plasma.nixosModules.default
              ({
                ringofstorms.dePlasma = {
                  enable = true;
                  gpu.intel.enable = true;
                  sddm.autologinUser = primaryUser; # Media box, auto-login
                  wallpapers = [
                    ../../hosts/_shared_assets/wallpapers/pixel_rain.png
                  ];
                };
              })

              ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })
              flatpaks.nixosModules.default

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.jetbrains_font
              common.nixosModules.nix_options
              common.nixosModules.timezone_chi
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh
              common.nixosModules.more_filesystems
              common.nixosModules.tailnet

              inputs.secrets-bao.nixosModules.default
              (
                { inputs, lib, ... }:
                lib.mkMerge [
                  {
                    ringofstorms.secretsBao = {
                      enable = true;
                      openBaoRole = "machines-lowtrust";
                      inherit (constants) secrets;
                    };
                  }
                  (inputs.secrets-bao.lib.applyChanges constants.secrets)
                ]
              )

              (
                { pkgs, ... }:
                {
                  environment.systemPackages = [
                    inputs.opencode.packages.${pkgs.system}.default
                  ];
                  environment.shellAliases = {
                    "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
                    "occ" = "oc -c";
                  };
                }
              )

              ./hardware-configuration.nix
              (import ./impermanence.nix { inherit primaryUser; })
              ./configuration.nix
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
                      common.homeManagerModules.kitty
                      common.homeManagerModules.launcher_rofi
                      common.homeManagerModules.postgres_cli_options
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
                      hashedPassword = "$y$j9T$XLpiC8tE5WjaeAQ.qIvoe0$2UXH2k8FtLvP7mIVdVuab103EA6LEOXB8XEWdPeX0y3"; # Generate with: mkpasswd -m yescrypt
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                        "gamemode"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    vlc
                    google-chrome
                    jellyfin-media-player
                    ffmpeg-full
                  ];

                  services.flatpak.packages = [
                    "com.spotify.Client"
                    "com.bitwarden.desktop"
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
