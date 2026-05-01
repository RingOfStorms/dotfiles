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
    # stt_ime.url = "path:../../flakes/stt_ime";
    stt_ime.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/stt_ime";
    # ports.url = "path:../../flakes/ports";
    ports.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/ports";

    opencode.url = "github:anomalyco/opencode/88582566bf2bfd2d26000f0c25735bf48ddeca00";
    nono.url = "github:always-further/nono";
    nono.flake = false;

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
          ({
            ringofstorms.sttIme = {
              enable = true;
              model = "tiny.en";
            };
          })
          inputs.ports.nixosModules.default
          ({ ringofstorms.ports.enable = true; })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })

          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.plymouth
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

          (
            { pkgs, ... }:
            {
              # Allow root deploys via SSH using the nix2nix key (matches
              # joe/lio/h00x). Required so the root flake's `deploy_juni`
              # script can run `nix-env --set` + `switch-to-configuration`
              # on the target.
              users.users.root.openssh.authorizedKeys.keys = [
                fleet.global.sshPubKey
              ];

              environment.systemPackages = [
                inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.default
              ];
              environment.shellAliases =
                let
                  no_proxy = "NO_PROXY='h001.net.joshuabell.xyz,*.ts.net,127.0.0.1,localhost,100.64.0.0/10'";
                in
                {
                  "mva" =
                    "${no_proxy} nono run --profile mva --allow-cwd --read \"$(git rev-parse --git-common-dir 2>/dev/null || echo /tmp)\" -- /home/josh/projects/mva/target/release/mva";
                  "mva_" = "${no_proxy} /home/josh/projects/mva/target/release/mva";
                  # open code
                  "oc" =
                    "${no_proxy} nono run --allow-cwd --read \"$(git rev-parse --git-common-dir 2>/dev/null || echo /tmp)\" --profile oc -- opencode";
                  "oc_" =
                    "${no_proxy} nono run --allow-cwd --read \"$(git rev-parse --git-common-dir 2>/dev/null || echo /tmp)\" --profile oc -- opencode";
                  "occ" = "oc -c";
                };
            }
          )
          ./nono.nix

          inputs.beszel.nixosModules.agent
          ({ beszelAgent.token = "2fb5f0a0-24aa-4044-a893-6d0f916cd063"; })

          ./hardware-configuration.nix
          ./lm-studio.nix
          (import ./impermanence.nix {
            inherit primaryUser;
            impermanence_mod = inputs.impermanence;
          })

          # Host-specific config
          (
            { pkgs, ... }:
            {
              environment.systemPackages = with pkgs; [
                qdirstat
                vlc
                google-chrome
                firefox
                jellyfin-media-player
                ttyd
                vesktop
                spotify
                element-desktop
                bitwarden-desktop
              ];
            }
          )
        ];
      };
    };
}
