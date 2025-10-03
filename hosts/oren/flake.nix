{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,

      common,
      ros_neovim,
      ...
    }:
    let
      configuration_name = "oren";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            modules = [
              common.nixosModules.default
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              # ./sway_customizations.nix
              ./hyprland_customizations.nix
              (
                { config, pkgs, ... }:
                {
                  services.devmon.enable = true;
                  services.gvfs.enable = true;
                  services.udisks2.enable = true;

                  networking = {
                    firewall = {
                      allowedTCPPorts = [
                        9991
                      ];
                    };
                  };

                  programs = {
                    nix-ld = {
                      enable = true;
                      libraries = with pkgs; [
                        icu
                        gmp
                        glibc
                        openssl
                        stdenv.cc.cc
                      ];
                    };
                  };
                  environment.shellAliases = {
                    "oc" =
                      "all_proxy='' http_proxy='' https_proxy='' /home/josh/other/opencode/node_modules/opencode-linux-x64/bin/opencode";
                    "occ" = "oc -c";

                    "ollamal" = "ollama list | tail -n +2 | awk '{print $1}' | fzf --ansi --preview 'ollama show {}'";
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                    ffmpeg-full
                    appimage-run
                    nodejs_24
                    foot
                    ttyd
                  ];

                  services.ollama = {
                    enable = true;
                    package = nixpkgs-unstable.legacyPackages.x86_64-linux.ollama;
                    acceleration = "rocm"; # cuda for NVIDA; rocm for amd; false/default for neither
                  };

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    general = {
                      enableSleep = true;
                      reporting.enable = true;
                    };
                    secrets.enable = true;
                    desktopEnvironment.hyprland = {
                      enable = true;
                      waybar.enable = true;
                      swaync.enable = true;
                    };
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      podman.enable = true;
                      virt-manager.enable = true;
                      flatpaks = {
                        enable = true;
                        packages = [
                          "org.signal.Signal"
                          "dev.vencord.Vesktop"
                          "md.obsidian.Obsidian"
                          "com.spotify.Client"
                          "org.videolan.VLC"
                          "com.bitwarden.desktop"
                          "im.riot.Riot"
                          "com.rustdesk.RustDesk"
                          "com.google.Chrome"
                        ];
                      };
                    };
                    users = {
                      # Users are all normal users and default password is password1
                      admins = [ "josh" ]; # First admin is also the primary user owning nix config
                      users = {
                        josh = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMzgAe4od9K4EsvH2g7xjNU7hGoJiFJlYcvB0BoDCvn nix2oren"
                          ];
                          extraGroups = [
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        josh = {
                          imports = with common.homeManagerModules; [
                            zsh
                            ssh
                            starship
                            zoxide
                            tmux
                            atuin
                            kitty
                            foot
                            direnv
                            git
                            nix_deprecations
                            obs
                            postgres
                          ];
                        };
                      };
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
