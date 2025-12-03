{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # impermanence.url = "github:nix-community/impermanence";

    # hyprland.url = "path:../../flakes/hyprland";
    hyprland.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/hyprland";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      common,
      ros_neovim,
      disko,
      hyprland,
      # impermanence,
      ...
    }:
    let
      configurationName = "testbed";
      stateVersion = "25.05";
      primaryUser = "luser";
      lib = nixpkgs.lib;
    in
    {
      packages = {
        x86_64-linux.vm = self.nixosConfigurations.${configurationName}.config.system.build.vmWithDisko;
      };
      nixosConfigurations = {
        "${configurationName}" = (
          lib.nixosSystem {
            modules = [
              home-manager.nixosModules.default

              disko.nixosModules.disko
              ros_neovim.nixosModules.default
              hyprland.nixosModules.default
              # impermanence.nixosModules.impermanence

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.nix_options
              common.nixosModules.podman
              common.nixosModules.timezone_auto
              common.nixosModules.zsh

              ./hardware-configuration.nix
              ./disko-config.nix
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
                      ];
                    };
                    root = {
                      shell = pkgs.zsh;
                      openssh.authorizedKeys.keys = [
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    cowsay
                    lolcat
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
