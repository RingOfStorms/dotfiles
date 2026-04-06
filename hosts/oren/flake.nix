{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testin
    common.url = "path:../../flakes/common";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # ports.url = "path:../../flakes/ports";
    ports.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/ports";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
    # mva.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/mva.git";

    opencode.url = "github:anomalyco/opencode/527b51477da3d07107db71da71e339003d9481ca";
    nono.url = "github:always-further/nono";
    nono.flake = false;
  };

  outputs =
    { nixpkgs-unstable, ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      overlayIp = constants.host.overlayIp;
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
          "gamemode"
        ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.amd.enable = true;
              # TODO once encrypted boot?
              # sddm.autologinUser = "josh";
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

          inputs.flatpaks.nixosModules.default
          # hyprland.nixosModules.default

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
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

          inputs.common.nixosModules.rustdesk
          ({
            ringofstorms.rustdesk = {
              enable = true;
              server = "o001";
              serverKeyFile = "/var/lib/openbao-secrets/rustdesk_server_key";
              passwordFile = "/var/lib/openbao-secrets/rustdesk_password";
              user = constants.host.primaryUser;
            };
          })

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "f8a54c41-486b-487a-a78d-a087385c317b";
            };
          })

          ./configuration.nix
          ./hardware-configuration.nix
          ./nono.nix
          # ./sway_customizations.nix
          # ./hyprland_customizations.nix

          # Host-specific config
          (
            { pkgs, ... }:
            {
              environment.systemPackages = with pkgs; [
                lua
                qdirstat
                ffmpeg-full
                vlc
                google-chrome
                ladybird
                nodejs_24
                ttyd
                appimage-run
              ];
              services.flatpak.packages = [
                "org.signal.Signal"
                "dev.vencord.Vesktop"
                "md.obsidian.Obsidian"
                "com.spotify.Client"
                "com.bitwarden.desktop"
                "org.openscad.OpenSCAD"
                "im.riot.Riot"
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
