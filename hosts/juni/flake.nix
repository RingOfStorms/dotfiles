{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager.url = "github:rycee/home-manager/release-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    impermanence.url = "github:nix-community/impermanence";

    # Use relative to get current version for testin
    common.url = "path:../../flakes/common";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/common";
    # secrets-bao.url = "path:../../flakes/secrets-bao";
    # NOTE: using an absolute path so this works before you commit/push.
    # After you add `flakes/secrets-bao` to the repo, switch to a git URL like your other flakes.
    secrets-bao.url = "path:../../flakes/secrets-bao";
    # flatpaks.url = "path:../../flakes/flatpaks";
    flatpaks.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/flatpaks";
    # beszel.url = "path:../../flakes/beszel";
    beszel.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/beszel";
    de_plasma.url = "path:../../flakes/de_plasma";
    # de_plasma.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/de_plasma";
    # opencode.url = "path:../../flakes/opencode";
    opencode.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/opencode";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      configuration_name = "juni";
      stateVersion = "25.11";
      primaryUser = "josh";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = { inherit inputs; };
            modules = [
              inputs.nixos-hardware.nixosModules.framework-12-13th-gen-intel
              inputs.impermanence.nixosModules.impermanence
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
                  gpu.intel.enable = true;
                  sddm.autologinUser = "josh";
                };
              })
              inputs.common.nixosModules.jetbrains_font

              inputs.ros_neovim.nixosModules.default
              ({
                ringofstorms-nvim.includeAllRuntimeDependencies = true;
              })
              inputs.opencode.nixosModules.default

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
              (
                { pkgs, lib, ... }:
                {
                  # Some boots come up without `/dev/net/tun` until `modprobe tun`.
                  # This makes `tailscaled` reliable by forcing the module load
                  # before it starts.
                  systemd.services.ensure-tun = {
                    description = "Ensure tun module is loaded";
                    wantedBy = [ "tailscaled.service" ];
                    before = [ "tailscaled.service" ];
                    after = [ "systemd-modules-load.service" ];
                    serviceConfig = {
                      Type = "oneshot";
                      RemainAfterExit = true;
                      ExecStart = "${pkgs.kmod}/bin/modprobe tun";
                    };
                  };

                  systemd.services.tailscaled = {
                    after = lib.mkAfter [ "ensure-tun.service" ];
                    wants = lib.mkAfter [ "ensure-tun.service" ];
                    requires = lib.mkAfter [ "ensure-tun.service" ];
                  };
                }
              )
              inputs.common.nixosModules.remote_lio_builds

              inputs.secrets-bao.nixosModules.default
              (
                { inputs, lib, ... }:
                let
                  secrets = {
                    headscale_auth = {
                      kvPath = "kv/data/machines/home_roaming/headscale_auth";
                      softDepend = [ "tailscaled" ];
                      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
                    };
                    "atuin-key-josh" = {
                      owner = "josh";
                      group = "users";
                      mode = "0400";
                      hardDepend = [ "atuin-autologin" ];
                      template = ''{{- with secret "kv/data/machines/home_roaming/atuin-key-josh" -}}{{ printf "%s\n%s\n%s" .Data.data.user .Data.data.password .Data.data.value }}{{- end -}}'';
                    };
                    nix2github = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
                    };
                    nix2bitbucket = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks."bitbucket.org".identityFile = "$SECRET_PATH";
                    };
                    nix2gitforgejo = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks."git.joshuabell.xyz".identityFile = "$SECRET_PATH";
                    };
                    nix2lio = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "lio" "lio_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2oren = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks.oren.identityFile = "$SECRET_PATH";
                    };
                    nix2gpdPocket3 = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks.gp3.identityFile = "$SECRET_PATH";
                    };
                    nix2t = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "t" "t_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2h001 = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "h001" "h001_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2h002 = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "h002" "h002_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2h003 = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "h003" "h003_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2linode = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "l001" "l002" "l002_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
                    };
                    nix2oracle = {
                      owner = "josh";
                      group = "users";
                      hmChanges.programs.ssh.matchBlocks = lib.genAttrs [ "o001" "o001_" ] (_: {
                        identityFile = "$SECRET_PATH";
                      });
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

              inputs.beszel.nixosModules.agent
              ({
                beszelAgent = {
                  token = "2fb5f0a0-24aa-4044-a893-6d0f916cd063";
                };
              })

              ./hardware-configuration.nix
              ./hardware-mounts.nix
              ./impermanence-tools.nix
              (import ./impermanence.nix { inherit primaryUser; })
              (
                { config, pkgs, ... }:
                rec {
                  # Home Manager
                  home-manager = {
                    useUserPackages = true;
                    useGlobalPkgs = true;
                    backupFileExtension = "bak";
                    # add all normal users to home manager so it applies to them
                    users = lib.mapAttrs (name: user: {
                      home.stateVersion = stateVersion;
                      programs.home-manager.enable = true;
                    }) (lib.filterAttrs (name: user: user.isNormalUser or false) users.users);

                    sharedModules = [
                      inputs.common.homeManagerModules.tmux
                      inputs.common.homeManagerModules.atuin
                      inputs.common.homeManagerModules.direnv
                      inputs.common.homeManagerModules.kitty
                      inputs.common.homeManagerModules.git
                      inputs.common.homeManagerModules.postgres_cli_options
                      inputs.common.homeManagerModules.starship
                      inputs.common.homeManagerModules.zoxide
                      inputs.common.homeManagerModules.zsh
                      inputs.common.homeManagerModules.ssh
                      (
                        { ... }:
                        {
                          programs.tmux.package = pkgs.unstable.tmux;
                        }
                      )
                    ];
                  };

                  # System configuration
                  system.stateVersion = stateVersion;
                  networking.hostName = configuration_name;
                  programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${config.networking.hostName}";
                  nixpkgs.config.allowUnfree = true;
                  users.mutableUsers = false;
                  users.users = {
                    "${primaryUser}" = {
                      isNormalUser = true;
                      hashedPassword = "$y$j9T$b66ZAxtTo75paZx.mnXyK.$ej0eKS3Wx4488qDfjUJSP0nsUe5TBzw31VbXR19XrQ4";
                      extraGroups = [
                        "wheel"
                        "networkmanager"
                        "video"
                        "input"
                      ];
                      openssh.authorizedKeys.keys = [
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH2KFSRkViT+asBTjCgA7LNP3SHnfNCW+jHbV08VUuIi nix2nix"
                      ];
                    };
                  };

                  environment.systemPackages = with pkgs; [
                    vlc
                    google-chrome
                  ];

                  services.flatpak.packages = [
                    "dev.vencord.Vesktop"
                    "com.spotify.Client"
                    "com.bitwarden.desktop"
                  ];

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

                        secret="/run/secrets/atuin-key-josh"
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
                }
              )
            ];
          }
        );
      };
    };
}
