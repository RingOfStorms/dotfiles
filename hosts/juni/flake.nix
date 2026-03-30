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
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    # de_plasma.url = "path:../../flakes/de_plasma";
    de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # stt_ime.url = "path:../../flakes/stt_ime";
    stt_ime.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/stt_ime";

    opencode.url = "github:anomalyco/opencode/c6262f9d4002d86a1f1795c306aa329d45361d12";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    { nixpkgs-unstable, ... }@inputs:
    let
      fleet = import ../fleet.nix;
      constants = import ./_constants.nix;
      primaryUser = constants.host.primaryUser;
    in
    {
      nixosConfigurations.${constants.host.name} = fleet.mkHost {
        inherit inputs constants;
        nixpkgsUnstable = nixpkgs-unstable;
        secretsRole = "machines-hightrust";
        authMethod = "hashedPassword";
        authValue = "$y$j9T$b66ZAxtTo75paZx.mnXyK.$ej0eKS3Wx4488qDfjUJSP0nsUe5TBzw31VbXR19XrQ4";
        mutableUsers = false;

        hmModules = [
          inputs.common.homeManagerModules.kitty
        ];

        nixosModules = [
          inputs.nixos-hardware.nixosModules.framework-12-13th-gen-intel
          inputs.impermanence.nixosModules.default
          ({
            ringofstorms.impermanence = {
              enable = true;
              disk = {
                boot = "/dev/disk/by-uuid/F5C0-5585";
                primary = "/dev/disk/by-uuid/3bfd6e57-5e0f-4742-99e3-e69891ae2431";
                swap = "/dev/disk/by-uuid/ad0311e2-7eb1-47af-bc4b-6311968cbccf";
              };
              encrypted = true;
              usbKey = true;
              usbKeyPassword = "expend-scarf-pebble";
            };
          })

          inputs.de_plasma.nixosModules.default
          ({
            ringofstorms.dePlasma = {
              enable = true;
              gpu.intel.enable = true;
              sddm.autologinUser = primaryUser;
              wallpapers = [
                ../../hosts/_shared_assets/wallpapers/pixel_neon.png
              ];
            };
          })
          inputs.common.nixosModules.jetbrains_font
          inputs.stt_ime.nixosModules.default
          ({ ringofstorms.sttIme = { enable = true; model = "tiny.en"; }; })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })
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

          ({ pkgs, ... }: {
            environment.systemPackages = [
              inputs.opencode.packages.${pkgs.system}.default
            ];
            environment.shellAliases = {
              "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
              "occ" = "oc -c";
            };
          })

          inputs.beszel.nixosModules.agent
          ({ beszelAgent.token = "2fb5f0a0-24aa-4044-a893-6d0f916cd063"; })

          ./hardware-configuration.nix
          (import ./impermanence.nix { inherit primaryUser; })

          # Host-specific config
          ({ pkgs, ... }: {
            environment.systemPackages = with pkgs; [
              vlc google-chrome jellyfin-media-player ttyd
            ];
            services.flatpak.packages = [
              "dev.vencord.Vesktop"
              "com.spotify.Client"
              "com.bitwarden.desktop"
            ];

            # TODO move to shared atuin module
            systemd.services.atuin-autologin = {
              description = "Auto-login to Atuin (if logged out)";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                Type = "oneshot";
                User = "josh";
                Group = "users";
                Environment = [
                  "HOME=/home/josh"
                  "XDG_CONFIG_HOME=/home/josh/.config"
                  "XDG_DATA_HOME=/home/josh/.local/share"
                ];
                ExecStart = pkgs.writeShellScript "atuin-autologin" ''
                  #!/usr/bin/env bash
                  set -euo pipefail

                  if ! ${pkgs.iputils}/bin/ping -c1 -W2 1.1.1.1 &>/dev/null; then
                    echo "No network access, skipping atuin login"
                    exit 0
                  fi

                  secret="/var/lib/openbao-secrets/atuin-key-josh_2026-03-15"
                  if [ ! -s "$secret" ]; then
                    echo "Missing atuin secret at $secret" >&2
                    exit 1
                  fi

                  # status exits non-zero when logged out.
                  out="$(${pkgs.atuin}/bin/atuin status 2>&1)" && exit 0

                  if [[ "$out" != *"You are not logged in"* ]]; then
                    echo "$out" >&2
                    exit 1
                  fi

                  username="$(${pkgs.gnused}/bin/sed -n '1p' "$secret")"
                  password="$(${pkgs.gnused}/bin/sed -n '2p' "$secret")"
                  key="$(${pkgs.gnused}/bin/sed -n '3p' "$secret")"

                  exec ${pkgs.atuin}/bin/atuin login --username "$username" --password "$password" --key "$key"
                '';
              };
            };
          })
        ];
      };
    };
}
