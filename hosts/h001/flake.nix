{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    # nixpkgs-unstable.url = "github:wrvsrx/nixpkgs/fix-open-webui";
    open-webui-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    litellm-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    trilium-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    oauth2-proxy-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zitadel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    beszel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    forgejo-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    n8n-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    dawarich-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    immich-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    paperless-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    matrix-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    puzzles.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/puzzles.git";

    nixarr.url = "github:rasmus-kirk/nixarr";

    # LLM gateway bake-off
    bifrost.url = "github:maximhq/bifrost";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix { inherit fleet; };
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        secretsRole = "machines-hightrust";

        nixosModules = [
          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
              extraFilesystems = "sda__Media";
            };
          })

          inputs.puzzles.nixosModules.default
          inputs.nixarr.nixosModules.default
          inputs.bifrost.nixosModules.bifrost
          ./hardware-configuration.nix
          ./mods
          ./nginx.nix
          ./containers
          ./autofs.nix

          # Host-specific config
          ({ pkgs, ... }: {
            users.users.root = {
              shell = pkgs.zsh;
              openssh.authorizedKeys.keys = [ fleet.global.sshPubKey ];
            };
            environment.systemPackages = with pkgs; [
              lua sqlite ttyd rclone
            ];
          })
        ];
      };
    };
}
