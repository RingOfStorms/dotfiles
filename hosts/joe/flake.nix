{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager/master";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    opencode.url = "github:anomalyco/opencode/c6262f9d4002d86a1f1795c306aa329d45361d12";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
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

              inputs.de_plasma.nixosModules.default
              ({
                ringofstorms.dePlasma = {
                  enable = true;
                  gpu.nvidia = {
                    enable = true;
                    open = true; # RTX 3080 (Ampere) -- open kernel modules fully supported
                  };
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
              common.nixosModules.tailnet
              common.nixosModules.timezone_chi
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh
              common.nixosModules.more_filesystems

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

              beszel.nixosModules.agent
              ({
                beszelAgent = {
                  listen = "${overlayIp}:45876";
                  token = "TODO"; # Generate and assign a beszel agent token
                };
              })

              ./configuration.nix
              ./hardware-configuration.nix
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
                      home.stateVersion = "25.11";
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
                        "gamemode" # Allow user to request GameMode priority
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 TODO" # Generate and add SSH key after install
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    google-chrome
                    vlc
                    ffmpeg-full
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
