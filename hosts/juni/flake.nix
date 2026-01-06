{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    impermanence.url = "github:nix-community/impermanence";

    # Use relative to get current version for testin
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    # NOTE: using an absolute path so this works before you commit/push.
    # After you add `flakes/secrets-bao` to the repo, switch to a git URL like your other flakes.
    secrets-bao.url = "path:../../flakes/secrets-bao";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    de_plasma.url = "path:../../flakes/de_plasma";
    # de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # opencode.url = "path:../../flakes/opencode";
    opencode.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/opencode";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      configuration_name = "juni";
      stateVersion = "25.11";
      primaryUser = "josh";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
           lib.nixosSystem {
             specialArgs = { inherit inputs; };
             modules = [
              inputs.nixos-hardware.nixosModules.framework-12-13th-gen-intel
              inputs.impermanence.nixosModules.impermanence
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
                  gpu.intel.enable = true;
                  sddm.autologinUser = "josh";
                };
              })
              inputs.common.nixosModules.jetbrains_font

               inputs.secrets-bao.nixosModules.default
              inputs.ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })
              inputs.opencode.nixosModules.default

              inputs.flatpaks.nixosModules.default

              inputs.common.nixosModules.boot_systemd
              inputs.common.nixosModules.essentials
              inputs.common.nixosModules.git
              inputs.common.nixosModules.tmux
              inputs.common.nixosModules.hardening
              inputs.common.nixosModules.nix_options
              inputs.common.nixosModules.timezone_auto
              inputs.common.nixosModules.tty_caps_esc
              inputs.common.nixosModules.zsh
              inputs.common.nixosModules.tailnet
              inputs.common.nixosModules.remote_lio_builds

               (
                 { inputs, lib, ... }:
                 let
                   secrets = {
                     headscale_auth = {
                       kvPath = "kv/data/machines/home_roaming/headscale_auth";
                       dependencies = [ "tailscaled" ];
                       configChanges = {
                         services.tailscale.authKeyFile = "$SECRET_PATH";
                       };
                     };
                     nix2github = {
                       owner = "josh";
                       group = "users";
                       kvPath = "kv/data/machines/home_roaming/nix2github";
                     };
                     nix2bitbucket = {
                       owner = "josh";
                       group = "users";
                       kvPath = "kv/data/machines/home_roaming/nix2bitbucket";
                     };
                     nix2gitforgejo = {
                       owner = "josh";
                       group = "users";
                       kvPath = "kv/data/machines/home_roaming/nix2gitforgejo";
                     };
                     nix2lio = {
                       owner = "josh";
                       group = "users";
                       kvPath = "kv/data/machines/home_roaming/nix2lio";
                     };
                   };
                 in
                 lib.mkMerge [
                   {
                     ringofstorms.secretsBao = {
                       enable = true;
                       zitadelKeyPath = "/machine-key.json";
                       openBaoAddr = "https://sec.joshuabell.xyz";
                       jwtAuthMountPath = "auth/zitadel-jwt";
                       openBaoRole = "machines";
                       zitadelIssuer = "https://sso.joshuabell.xyz";
                       zitadelProjectId = "344379162166820867";
                       inherit secrets;
                     };
                   }
                   (inputs.secrets-bao.lib.applyConfigChanges secrets)
                 ]
               )

              # inputs.beszel.nixosModules.agent
              # ({
              #     beszelAgent = {
              #       token = "2fb5f0a0-24aa-4044-a893-6d0f916cd063";
              #     };
              #   }
              # )

              ./hardware-configuration.nix
              ./hardware-mounts.nix
              ./impermanence-tools.nix
              (import ./impermanence.nix { inherit primaryUser; })
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
                      inputs.common.homeManagerModules.tmux
                      inputs.common.homeManagerModules.atuin
                      inputs.common.homeManagerModules.direnv
                      inputs.common.homeManagerModules.kitty
                      inputs.common.homeManagerModules.git
                      inputs.common.homeManagerModules.postgres_cli_options
                      inputs.common.homeManagerModules.starship
                      inputs.common.homeManagerModules.zoxide
                      inputs.common.homeManagerModules.zsh
                      # inputs.common.homeManagerModules.ssh
                      (
                        { ... }:
                        {
                          programs.tmux.package = pkgs.unstable.tmux;
                        }
                      )
                    ];
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
                      hashedPassword = "$y$j9T$b66ZAxtTo75paZx.mnXyK.$ej0eKS3Wx4488qDfjUJSP0nsUe5TBzw31VbXR19XrQ4";
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    vlc
                    google-chrome
                  ];

                  services.flatpak.packages = [
                    "dev.vencord.Vesktop"
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
