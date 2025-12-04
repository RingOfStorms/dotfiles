{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:rycee/home-manager/release-25.05";

    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      ...
    }@inputs:
    let
      configurationName = "MACHINE_HOST_NAME";
      primaryUser = "luser";
      configLocation = "/etc/nixos";
      # configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
      lib = inputs.nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configurationName}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs;
            };
            modules = [
              # inputs.impermanence.nixosModules.impermanence
              inputs.home-manager.nixosModules.default

              inputs.ros_neovim.nixosModules.default
              (
                { ... }:
                {
                  ringofstorms-nvim.includeAllRuntimeDependencies = true;
                }
              )

              inputs.common.nixosModules.essentials
              inputs.common.nixosModules.git
              inputs.common.nixosModules.tmux
              # TODO PICK ONE
              # inputs.common.nixosModules.boot_systemd
              # inputs.common.nixosModules.boot_grub
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.jetbrains_font
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.no_sleep
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh

              ./hardware-configuration.nix
              (
                {
                  config,
                  pkgs,
                  upkgs,
                  lib,
                  ...
                }:
                rec {
                  # TODO ensure matches configuration.nix, and add anything else from there that is needed
                  system.stateVersion = "25.05";
                  # No ssh pub keys setup yet, allow password login, TODO remove
                  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

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
                      inputs.common.homeManagerModules.tmux
                      inputs.common.homeManagerModules.atuin
                      inputs.common.homeManagerModules.direnv
                      inputs.common.homeManagerModules.git
                      inputs.common.homeManagerModules.postgres_cli_options
                      inputs.common.homeManagerModules.starship
                      inputs.common.homeManagerModules.zoxide
                      inputs.common.homeManagerModules.zsh
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
                        # TODO set a public key for access
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
