{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager/master";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    stt_ime.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/stt_ime";
    # sec-agent replaces secrets-bao on this host.
    secrets_manager.url = "git+https://git.joshuabell.xyz/ringofstorms/secrets_manager.git";

    omp-flake.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/omp";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        authMethod = "hashedPassword";
        authValue = "$y$j9T$b66ZAxtTo75paZx.mnXyK.$ej0eKS3Wx4488qDfjUJSP0nsUe5TBzw31VbXR19XrQ4"; # same as juni
        mutableUsers = false;
        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
          "input"
        ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
          inputs.common.homeManagerModules.foot
          inputs.common.homeManagerModules.launcher_rofi
        ];

        nixosModules = [
          inputs.nixos-hardware.nixosModules.gpd-pocket-3
          inputs.impermanence_mod.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/0FC3-1534";
                primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                swap = "/dev/disk/by-partuuid/2b3d7b06-7c4f-4c5f-a203-4039a71c781f";
              };
              encrypted = true;
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = primaryUser; # disk is encrypted; passphrase gates boot
              defaultBrowser = "firefox.desktop";
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_rain.png
              ];
            };
          })
          # Speech-to-text IME. CPU-only (Iris Xe has no backend in the flake).
          # Benchmarked on gp3 (i7-1195G7, 8 threads, 11s clip): small.en 3.7s,
          # medium.en 13.8s, large-v3-turbo 23.8s. Only small.en is faster than
          # real time, so it is the largest model that stays responsive.
          inputs.stt_ime.nixosModules.default
          ({
            ringofstorms.sttIme = {
              enable = true;
              model = "small.en";
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.plymouth
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.ssh_root
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.timezone_auto
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.more_filesystems
          inputs.common.nixosModules.tailnet
          inputs.omp-flake.nixosModules.default
          inputs.common.nixosModules.remote_lio_builds

          inputs.common.nixosModules.atuin
          ({
            ringofstorms.atuin = {
              enable = true;
              autologin = {
                enable = true;
                user = primaryUser;
                secretFile = "/var/lib/secrets_manager_hydrated/atuin-key-josh_2026-03-15";
                afterUnits = [ "sec-secrets-ready.service" ];
              };
            };
          })

          (import ./sec-agent.nix { inherit inputs constants; })

          ./hardware-configuration.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence_mod;
          })
          ./configuration.nix

          # Host-specific config
          ({ pkgs, ... }: {
            nixpkgs.config.permittedInsecurePackages = [
              "electron-39.8.10"
            ];
            environment.systemPackages = with pkgs; [
              vlc
              google-chrome
              jellyfin-media-player
              spotify
              bitwarden-desktop
              firefox
            ];
          })
        ];
      };
    };
}
