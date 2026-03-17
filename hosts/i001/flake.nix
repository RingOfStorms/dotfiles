{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # common.url = "path:../../../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
  };

  # NIX_SSHOPTS="-i /var/lib/openbao-secrets/nix2nix_2026-03-15" nixos-rebuild --flake ".#i001" --target-host luser@10.12.14.119 switch
  outputs =
    {
      ...
    }@inputs:
    let
      constants = import ./_constants.nix;
      configurationName = constants.host.name;
      primaryUser = constants.host.primaryUser;
      configLocation = "/home/${primaryUser}/.config/nixos-config/hosts/${configurationName}";
      stateVersion = constants.host.stateVersion;
      lib = inputs.nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configurationName}" = (
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
                    boot = "/dev/disk/by-uuid/635D-F0DA";
                    primary = "/dev/disk/by-uuid/82cb11a7-097a-4e95-b9f0-47dad95de9df";
                    swap = "/dev/disk/by-uuid/29c89516-e6ed-4f91-adf7-646451a8e26f";
                  };
                  encrypted = true;
                  usbKey = true;
                };
              })
              inputs.home-manager.nixosModules.default

              inputs.ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })

              inputs.de_plasma.nixosModules.default
              ({
                ringofstorms.dePlasma = {
                  enable = true;
                  gpu.intel.enable = true;
                  sddm.autologinUser = "luser";
                  disableKeyd = true;
                };
              })

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
              inputs.common.nixosModules.tailnet

              inputs.secrets-bao.nixosModules.default
              (
                let
                  autoSecrets = inputs.secrets-bao.lib.mkAutoSecrets {
                    role = "machines-lowtrust";
                    primaryUser = constants.host.primaryUser;
                  };
                in
                { lib, ... }:
                lib.mkMerge [
                  {
                    ringofstorms.secretsBao = {
                      enable = true;
                      openBaoRole = "machines-lowtrust";
                      secrets = autoSecrets;
                    };
                  }
                  (inputs.secrets-bao.lib.applyChanges autoSecrets)
                ]
              )

              ./hardware-configuration.nix
              ./impermanence.nix
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                rec {
                  system.stateVersion = stateVersion;
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
                      home.stateVersion = stateVersion;
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
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
                      ];
                    };
                    root.openssh.authorizedKeys.keys = [
                      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
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
