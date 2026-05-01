{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Use relative to get current version for testing
    # impermanence.url = "path:../../flakes/impermanence";
    impermanence.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # ports.url = "path:../../flakes/ports";
    ports.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/ports";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
    # mva.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/mva.git";

    opencode.url = "github:anomalyco/opencode/375444a149780c7121bd8964685c4bfe8edd1870";
    nono.url = "github:always-further/nono";
    nono.flake = false;
  };

  outputs =
    { nixpkgs-unstable, ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      overlayIp = constants.host.overlayIp;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        nixpkgsUnstable = nixpkgs-unstable;
        secretsRole = "machines-hightrust";
        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
          "input"
        ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.nixos-hardware.nixosModules.framework-16-7040-amd

          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                # TODO: fill in after fresh bcachefs install. Capture from
                # `lsblk -o name,uuid` after partitioning per
                # utilities/nixos-installers/install_bcachefs.md.
                boot = "/dev/disk/by-uuid/1902-AB03";
                primary = "/dev/disk/by-uuid/19d6c8c3-7438-42a9-b0d1-bbd95ce040d6";
                swap = "/dev/disk/by-uuid/4936a8d2-94a5-4de8-8fec-e2872d1fb39a";
              };
              encrypted = true;
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.amd.enable = true;
              sddm.autologinUser = primaryUser;
            };
          })

          inputs.ports.nixosModules.default
          ({ ringofstorms.ports.enable = true; })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          (
            { pkgs, ... }:
            {
              environment.systemPackages = [
                inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.default
                # inputs.mva.packages.${pkgs.stdenv.hostPlatform.system}.default
              ];
              environment.shellAliases = {
                # open code
                "oc" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile oc -- opencode";
                "occ" = "oc -c";
                "a" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile mva -- mva";
              };
            }
          )

          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.plymouth
          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_auto
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.more_filesystems
          inputs.common.nixosModules.remote_lio_builds

          inputs.common.nixosModules.atuin
          ({
            ringofstorms.atuin = {
              enable = true;
              autologin = {
                enable = true;
                user = primaryUser;
                secretFile = "/var/lib/openbao-secrets/atuin-key-josh_2026-03-15";
              };
            };
          })

          inputs.common.nixosModules.rustdesk
          ({
            ringofstorms.rustdesk = {
              enable = true;
              server = "o001";
              serverKeyFile = "/var/lib/openbao-secrets/rustdesk_server_key";
              passwordFile = "/var/lib/openbao-secrets/rustdesk_password";
              user = primaryUser;
            };
          })

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "f8a54c41-486b-487a-a78d-a087385c317b";
            };
          })

          ./hardware-configuration.nix
          ./nono.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence;
          })

          # Host-specific config
          (
            { pkgs, ... }:
            {
              environment.systemPackages = with pkgs; [
                # Dev/CLI
                lua
                qdirstat
                ffmpeg-full
                nodejs_24
                ttyd
                appimage-run

                # Browsers
                google-chrome
                firefox

                # Media
                vlc

                # signal-desktop
                # vesktop
                # bitwarden-desktop
                # spotify
                # element-desktop
              ];

              services.devmon.enable = true;
              services.gvfs.enable = true;
              services.udisks2.enable = true;
              networking.firewall.allowedTCPPorts = [ 9991 ];
            }
          )
        ];
      };
    };
}
