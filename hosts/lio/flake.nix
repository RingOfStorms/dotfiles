{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
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

    opencode.url = "github:anomalyco/opencode/eb3bfffad453f1c8c3f0f92bba0d8e34c83fa244";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
    qvm.url = "git+https://git.joshuabell.xyz/ringofstorms/qvm";
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

        hmModules = [
          inputs.common.homeManagerModules.kitty
          inputs.common.homeManagerModules.foot
          inputs.common.homeManagerModules.launcher_rofi
          inputs.common.homeManagerModules.slicer
          (
            { pkgs, ... }:
            {
              programs.tmux.package = pkgs.unstable.tmux;
            }
          )
          # Local network SSH entries for joe and gp3
          (
            { ... }:
            {
              programs.ssh.matchBlocks = {
                "joe_" = {
                  hostname = fleet.hosts.joe.lanIp;
                  user = fleet.hosts.joe.user;
                };
                "gp3_" = {
                  hostname = fleet.hosts.gp3.lanIp;
                  user = fleet.hosts.gp3.user;
                };
              };
            }
          )
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
          inputs.stt_ime.nixosModules.default
          ({
            ringofstorms.sttIme = {
              enable = true;
              gpuBackend = "hip"; # Use AMD ROCm/HIP acceleration
              useGpu = true;
              model = "large";
            };
          })

          inputs.ros_neovim.nixosModules.default
          ({ ringofstorms-nvim.includeAllRuntimeDependencies = true; })
          inputs.qvm.nixosModules.default
          ({
            programs.qvm = {
              memory = "30G";
              cpus = 30;
            };
          })
          inputs.flatpaks.nixosModules.default

          inputs.common.nixosModules.essentials
          inputs.common.nixosModules.git
          inputs.common.nixosModules.tmux
          inputs.common.nixosModules.boot_systemd
          inputs.common.nixosModules.hardening
          inputs.common.nixosModules.jetbrains_font
          inputs.common.nixosModules.nix_options
          inputs.common.nixosModules.no_sleep
          inputs.common.nixosModules.podman
          inputs.common.nixosModules.q_flipper
          inputs.common.nixosModules.tailnet
          inputs.common.nixosModules.timezone_chi
          inputs.common.nixosModules.tty_caps_esc
          inputs.common.nixosModules.zsh
          inputs.common.nixosModules.more_filesystems

          (
            { pkgs, ... }:
            {
              environment.systemPackages = [
                inputs.opencode.packages.${pkgs.system}.default
                pkgs.claude-code
                pkgs.code-cursor
                pkgs.zed-editor
              ];
              environment.shellAliases = {
                # open code
                "oc" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile oc -- opencode";
                "occ" = "oc -c";
                # claude code
                "cc" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile cc -- claude";
                # cursor
                "cur" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile cc -- cursor";
                # zed
                "zed" = "all_proxy='' http_proxy='' https_proxy='' nono run --allow-cwd --profile cc -- zeditor";
              };
            }
          )

          inputs.beszel.nixosModules.agent
          ({
            beszelAgent = {
              listen = "${overlayIp}:45876";
              token = "20208198-87c2-4bd1-ab09-b97c3b9c6a6e";
            };
            services.beszel.agent.environment = {
              EXTRA_FILESYSTEMS = "nvme0n1p1__nvme1tb";
            };
          })

          ./configuration.nix
          ./hardware-configuration.nix
          (import ./containers.nix { inherit inputs; })
          # ./jails_text.nix
          # ./hyprland_customizations.nix
          # ./sway_customizations.nix
          # ./i3_customizations.nix
          ./vms.nix
          ./nono.nix

          # Host-specific config
          (
            { pkgs, ... }:
            {
              environment.systemPackages = with pkgs; [
                vlang
                ttyd
                pavucontrol
                nfs-utils
                jellyfin-media-player
                element-desktop
              ];
              services.flatpak.packages = [
                "org.signal.Signal"
                "dev.vencord.Vesktop"
                "com.spotify.Client"
                "com.bitwarden.desktop"
                "org.openscad.OpenSCAD"
                "org.blender.Blender"
              ];
              networking.firewall.allowedTCPPorts = [ 8080 ];
            }
          )
        ];
      };
    };
}
