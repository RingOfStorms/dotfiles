{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../flakes/common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets.url = "path:../../flakes/secrets";
    secrets.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/secrets";
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

    opencode.url = "github:anomalyco/opencode";
    nixpkgs-bun-latest.url = "github:NixOS/nixpkgs/3f0336406035444b4a24b942788334af5f906259";
    opencode.inputs.nixpkgs.follows = "nixpkgs-bun-latest";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
    qvm.url = "git+https://git.joshuabell.xyz/ringofstorms/qvm";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      common,
      secrets,
      flatpaks,
      beszel,
      ros_neovim,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      constants = import ./_constants.nix;
      configuration_name = constants.host.name;
      primaryUser = constants.host.primaryUser;
      overlayIp = constants.host.overlayIp;
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs constants;
            };
            modules = [
              ({
                nixpkgs.overlays = [
                  (final: prev: {
                    unstable = import nixpkgs-unstable {
                      inherit (final) system config;
                    };
                  })
                ];
              })
              home-manager.nixosModules.default

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

              secrets.nixosModules.default
              ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })
              inputs.qvm.nixosModules.default
              ({
                programs.qvm = {
                  memory = "30G";
                  cpus = 30;
                };
              })
              flatpaks.nixosModules.default

              common.nixosModules.essentials
              common.nixosModules.git
              common.nixosModules.tmux
              common.nixosModules.boot_systemd
              # common.nixosModules.de_sway
              # common.nixosModules.de_i3
              common.nixosModules.hardening
              common.nixosModules.jetbrains_font
              common.nixosModules.nix_options
              common.nixosModules.no_sleep
              common.nixosModules.podman
              common.nixosModules.q_flipper
              common.nixosModules.tailnet
              common.nixosModules.timezone_auto
              common.nixosModules.tty_caps_esc
              common.nixosModules.zsh
              common.nixosModules.more_filesystems

              inputs.secrets-bao.nixosModules.default
              (
                { pkgs, ... }:
                {
                  environment.systemPackages = [
                    inputs.opencode.packages.${pkgs.system}.default
                  ];
                  environment.shellAliases = {
                    "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
                    "occ" = "oc -c";
                  };
                }
              )
              (
                { inputs, lib, ... }:
                let
                  secrets = {
                    headscale_auth = {
                      kvPath = "kv/data/machines/home_roaming/headscale_auth";
                      # dependencies = [ "tailscaled" ];
                      # configChanges.services.tailscale.authKeyFile = "$SECRET_PATH"; # TODO remove secrets and enable this
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
                  (inputs.secrets-bao.lib.applyHmChanges secrets)
                ]
              )

              beszel.nixosModules.agent
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
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                rec {
                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = "25.05";
                      programs.home-manager.enable = true;
                    }) (lib.filterAttrs (name: user: user.isNormalUser or false) users.users);

                    sharedModules = [
                      # common.homeManagerModules.de_sway
                      # common.homeManagerModules.de_i3
                      common.homeManagerModules.tmux
                      common.homeManagerModules.atuin
                      common.homeManagerModules.direnv
                      common.homeManagerModules.foot
                      common.homeManagerModules.git
                      common.homeManagerModules.kitty
                      common.homeManagerModules.launcher_rofi
                      common.homeManagerModules.postgres_cli_options
                      common.homeManagerModules.slicer
                      common.homeManagerModules.ssh
                      common.homeManagerModules.starship
                      common.homeManagerModules.zoxide
                      common.homeManagerModules.zsh
                      (
                        { ... }:
                        {
                          programs.tmux.package = pkgs.unstable.tmux;
                        }
                      )
                    ];

                    extraSpecialArgs = {
                      inherit inputs;
                    };
                  };

                  # System configuration
                  networking.hostName = configuration_name;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${config.networking.hostName}";
                  nixpkgs.config.allowUnfree = true;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      initialPassword = "password1";
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                      ];
                    };
                  };

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

                  networking.firewall.allowedTCPPorts = [
                    8080
                  ];
                }
              )
            ];
          }
        );
      };
    };
}
