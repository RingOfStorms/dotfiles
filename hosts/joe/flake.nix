{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:rycee/home-manager/master";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # beszel.url = "path:../../flakes/beszel";
    # beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";
    # impermanence_mod.url = "path:../../flakes/impermanence";
    impermanence_mod.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/impermanence";

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
        secretsRole = "machines-lowtrust";
        authMethod = "hashedPassword";
        authValue = "$y$j9T$HcgOlwo3O7syvUsSQsuyi.$DSe1Cvg.3mtufGxDCmMiJ80uQpAwxjRmdA4EXi9GoF6";
        mutableUsers = false;
        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
          "input"
          "gamemode"
        ];

        hmModules = [
          inputs.common.homeManagerModules.kitty
          inputs.common.homeManagerModules.foot
          inputs.common.homeManagerModules.launcher_rofi
          inputs.common.homeManagerModules.slicer
          # Autostart Steam minimized to tray on login
          (
            { ... }:
            {
              xdg.configFile."autostart/steam.desktop".text = ''
                [Desktop Entry]
                Type=Application
                Name=Steam
                Exec=steam -silent
                X-KDE-autostart-phase=2
              '';
            }
          )
        ];

        nixosModules = [
          inputs.impermanence_mod.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/989B-F1AB";
                primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                swap = "/dev/disk/by-uuid/ee0ae363-e28c-47ec-8224-6aae026f586f";
              };
              encrypted = true;
              usbKey = true;
              usbKeyPassword = "Unbiased-Blissful2-Fretted";
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.nvidia = {
                enable = true;
                open = false; # Proprietary -- open modules caused device creation failures in DXVK/VKD3D-Proton
              };
              noScreenOff = true;
              sddm.autologinUser = primaryUser;
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_cat_garage.png
                ../../hosts/_shared_assets/wallpapers/pixel_cats_v.png
              ];
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.more_filesystems
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.podman

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

          # TODO beszel agent -- needs overlay IP assigned first
          # beszel.nixosModules.agent
          # ({
          #   beszelAgent = {
          #     listen = "${overlayIp}:45876";
          #     token = "TODO"; # Generate and assign a beszel agent token
          #   };
          # })

          inputs.flatpaks.nixosModules.default

          ./configuration.nix
          ./hardware-configuration.nix
          ./nixld.nix
          ./llama-cpp.nix
          ./kokoro-tts.nix
          ./forge.nix
          ./homepage-dashboard.nix
          ./nginx.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence_mod;
          })

          # Host-specific config
          (
            { pkgs, ... }:
            let
              # Prism Launcher wrapper that forces LWJGL to use the native
              # Wayland GLFW backend instead of X11/XWayland.
              #
              # Why: prismlauncher already ships glfw3-minecraft (the Wayland-
              # patched GLFW 3.4) in LD_LIBRARY_PATH, but LWJGL still defaults
              # to GLFW's X11 platform unless told otherwise. Under XWayland,
              # opening the Minecraft chat with `t` or `/` causes the keypress
              # to be re-injected into the chat box (~70% of the time) due to
              # XWayland's broken key-repeat replay behavior.
              #
              # Setting LWJGL_USE_WAYLAND=1 makes LWJGL initialise GLFW with
              # the Wayland platform, so key events come straight from the
              # Wayland compositor with no replay/grab races.
              prismlauncher-wayland = pkgs.symlinkJoin {
                name = "prismlauncher-wayland";
                paths = [ pkgs.prismlauncher ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/prismlauncher \
                    --set LWJGL_USE_WAYLAND 1
                '';
                inherit (pkgs.prismlauncher) meta;
              };
            in
            {
              environment.systemPackages = with pkgs; [
                google-chrome
                qdirstat
                vlc
                jellyfin-media-player
                ffmpeg-full
                ttyd
                steam-run
                prismlauncher-wayland # Open-source Minecraft launcher (Wayland-native LWJGL/GLFW)
                # Native (non-flatpak) Vesktop. The flatpak build had broken
                # screen sharing on NVIDIA -- the picker would freeze after
                # the first attempt due to portal/pipewire sandboxing issues.
                # Native binary uses host xdg-desktop-portal-kde directly.
                vesktop
              ];
              services.flatpak.packages = [
                "com.spotify.Client"
                "com.bitwarden.desktop"
              ];
            }
          )
        ];
      };
    };
}
