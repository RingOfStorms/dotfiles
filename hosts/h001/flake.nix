{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    open-webui-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    litellm-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    trilium-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    oauth2-proxy-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    pinchflat-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zitadel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    beszel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    forgejo-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    n8n-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    secrets-bao.url = "path:../../flakes/secrets-bao";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    puzzles.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/puzzles.git";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      secrets,
      beszel,
      ros_neovim,
      nixarr,
      ...
    }@inputs:
    let
      configuration_name = "h001";
      stateVersion = "24.11";
      primaryUser = "luser";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs;
            };
            modules = [
              home-manager.nixosModules.default

              secrets.nixosModules.default
              ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              common.nixosModules.hardening
              common.nixosModules.nix_options
              common.nixosModules.podman
              common.nixosModules.tailnet
              common.nixosModules.timezone_chi
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh

              beszel.nixosModules.agent
              ({
                beszelAgent = {
                  token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
                  extraFilesystems = "sda__Media";
                };
              })

              inputs.secrets-bao.nixosModules.default
              (
                { inputs, lib, ... }:
                let
                  secrets = {
                    litellm-env = {
                      owner = "root";
                      group = "root";
                      mode = "0400";
                      # Uses default: /var/lib/openbao-secrets/litellm-env
                      softDepend = [ "litellm" ];
                      template = ''
                        {{- with secret "kv/data/machines/home/openrouter" -}}
                        OPENROUTER_API_KEY={{ index .Data.data "api-key" }}
                        {{ end -}}
                        {{- with secret "kv/data/machines/home/anthropic-claude" -}}
                        ANTHROPIC_API_KEY={{ index .Data.data "api-key" }}
                        {{- end -}}
                      '';
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

              inputs.puzzles.nixosModules.default
              (
                { pkgs, ... }:
                {
                  services.puzzles-server = {
                    enable = true;
                    package = inputs.puzzles.packages.${pkgs.system}.default;
                    settings = {
                      http = "0.0.0.0:8093";
                    };
                  };
                }
              )

              nixarr.nixosModules.default
              ./hardware-configuration.nix
              ./mods
              ./nginx.nix
              ./containers
              ./autofs.nix
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
                      common.homeManagerModules.ssh
                      common.homeManagerModules.starship
                      common.homeManagerModules.zoxide
                      common.homeManagerModules.zsh
                    ];
                  };

                  # System configuration
                  system.stateVersion = stateVersion;
                  networking.hostName = configuration_name;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${configuration_name}";
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
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                      ];
                    };
                    root = {
                      shell = pkgs.zsh;
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZigrRMF/HHMhjBIwiOnS2pqbOz8Az19tch680BGvmu nix2h001"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    sqlite
                    ttyd
                    rclone
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
