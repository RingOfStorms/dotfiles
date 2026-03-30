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
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    secrets-bao.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets-bao";

    opencode.url = "github:anomalyco/opencode/c6262f9d4002d86a1f1795c306aa329d45361d12";

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
        authValue = "$y$j9T$XLpiC8tE5WjaeAQ.qIvoe0$2UXH2k8FtLvP7mIVdVuab103EA6LEOXB8XEWdPeX0y3";
        mutableUsers = false;
        extraGroups = [ "wheel" "networkmanager" "video" "input" "gamemode" ];

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
                boot = "/dev/disk/by-uuid/D1C3-B6B2";
                primary = "/dev/disk/by-uuid/0d6e4079-e367-03eb-d37c-00722f5891d2";
                swap = "/dev/disk/by-uuid/4b56d370-63e8-4613-bf46-c3fc4ad2aa70";
              };
              encrypted = true;
              usbKey = true;
              usbKeyPassword = "brought-upside-twentieth";
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = primaryUser; # Media box, auto-login
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_rain.png
              ];
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })
          inputs.flatpaks.nixosModules.default

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.more_filesystems
          inputs.common.nixosModules.tailnet

          ({ pkgs, ... }: {
            environment.systemPackages = [
              inputs.opencode.packages.${pkgs.system}.default
            ];
            environment.shellAliases = {
              "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
              "occ" = "oc -c";
            };
          })

          ./hardware-configuration.nix
          (import ./impermanence.nix { inherit primaryUser; })
          ./configuration.nix
          ./battery-manager.nix

          # Override vault-agent role to host-gp3 so it gets the per-host
          # policy (host-gp3) on top of the shared machines-low-trust policy.
          # secretsRole stays "machines-lowtrust" for mkAutoSecrets compatibility.
          ({ lib, ... }: {
            ringofstorms.secretsBao.openBaoRole = lib.mkForce "host-gp3";
          })

          # Host-specific config
          ({ pkgs, ... }: {
            environment.systemPackages = with pkgs; [
              vlc google-chrome jellyfin-media-player ffmpeg-full
            ];
            services.flatpak.packages = [
              "com.spotify.Client"
              "com.bitwarden.desktop"
            ];
          })
        ];
      };
    };
}
