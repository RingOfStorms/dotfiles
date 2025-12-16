{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # common.url = "path:../../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      ...
    }@inputs:
    let
      configurationName = "i001";
      system = "x86_64-linux";
      primaryUser = "luser";
      configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
      stateAndHomeVersion = "25.11";
      lib = inputs.nixpkgs.lib;
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
              # inputs.impermanence.nixosModules.impermanence
              inputs.home-manager.nixosModules.default

              inputs.ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })

              # inputs.de_plasma.nixosModules.default
              # ({
              #   ringofstorms.dePlasma = {
              #     enable = true;
              #     gpu.intel.enable = true;
              #     sddm.autologinUser = "luser";
              #   };
              # })

              inputs.common.nixosModules.essentials
              inputs.common.nixosModules.git
              inputs.common.nixosModules.tmux
              inputs.common.nixosModules.boot_systemd
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.jetbrains_font
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.no_sleep
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh

              ./hardware-configuration.nix
              ./hardware-mounts.nix
              # ./impermanence.nix
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                rec {
                  system.stateVersion = stateAndHomeVersion;
                  # TODO allowing password auth for now
                  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
                  # TODO remove this for testbed
                  security.sudo.wheelNeedsPassword = false;

                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = stateAndHomeVersion;
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
                    };
                  };

                  # System configuration
                  networking.networkmanager.enable = true;
                  networking.hostName = configurationName;
                  programs.nh.flake = configLocation;
                  nixpkgs.config.allowUnfree = true;
                  # users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      # hashedPassword = ""; # Use if mutable users is false above
                      initialHashedPassword = "$y$j9T$v1QhXiZMRY1pFkPmkLkdp0$451GvQt.XFU2qCAi4EQNd1BEqjM/CH6awU8gjcULps6"; # "test" password
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                    root.openssh.authorizedKeys.keys = [
                      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                    ];
                  };

                  # Specifics for this machine
                  environment.systemPackages = with pkgs; [
                    qdirstat
                    google-chrome
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
