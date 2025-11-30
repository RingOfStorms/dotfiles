{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:rycee/home-manager/release-25.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      ros_neovim,
      ...
    }@inputs:
    let
      configurationName = "testbed";
      system = "x86_64-linux";
      primaryUser = "luser";
      configLocation = "/home/${primaryUser}/.config/nixos-config";
      # configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
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
              inputs.impermanence.nixosModules.impermanence
              inputs.home-manager.nixosModules.default

              ros_neovim.nixosModules.default
              (
                { ... }:
                {
                  ringofstorms-nvim.includeAllRuntimeDependencies = true;
                }
              )

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.jetbrains_font
              common.nixosModules.nix_options
              common.nixosModules.no_sleep
              common.nixosModules.timezone_auto
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh

              ./hardware-configuration.nix
              ./impermanence.nix
              ./plasma.nix
              (
                {
                  config,
                  pkgs,
                  upkgs,
                  lib,
                  ...
                }:
                rec {
                  system.stateVersion = "25.05";
                  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

                  myPlasma = {
                    enable = true;
                    gpu.intel.enable = true;
                    sddm.autologinUser = "luser";
                  };

                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = "25.05";
                      programs.home-manager.enable = true;
                    }) (lib.filterAttrs (name: user: user.isNormalUser or false) users.users);

                    sharedModules = [
                      common.homeManagerModules.tmux
                      common.homeManagerModules.atuin
                      common.homeManagerModules.direnv
                      common.homeManagerModules.git
                      common.homeManagerModules.postgres_cli_options
                      common.homeManagerModules.starship
                      common.homeManagerModules.zoxide
                      common.homeManagerModules.zsh
                    ];

                    extraSpecialArgs = {
                      inherit inputs;
                      inherit upkgs;
                    };
                  };

                  # System configuration
                  networking.hostName = configurationName;
                  programs.nh.flake = configLocation;
                  nixpkgs.config.allowUnfree = true;
                  users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      hashedPassword = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6"; # "test" password
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                      ];
                      openssh.authorizedKeys.keys = [
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
