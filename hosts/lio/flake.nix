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
      common,
      ros_neovim,
      ...
    }@inputs:
    let
      configuration_name = "lio";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = {
              inherit inputs;
              upkgs = import inputs.nixpkgs-unstable {
                system = "x86_64-linux";
                config.allowUnfree = true;
              };
            };
            modules = [
              common.nixosModules.default
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              (import ./containers.nix { inherit inputs; })
              # ./jails_text.nix
              # ./hyprland_customizations.nix
              ./sway_customizations.nix
              (
                {
                  config,
                  pkgs,
                  upkgs,
                  lib,
                  ...
                }:
                {
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
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                    ffmpeg-full
                    appimage-run
                    nodejs_24
                    foot
                    vlc
                    upkgs.ladybird
                    google-chrome
                    trilium-desktop
                    dig
                    traceroute
                    # opensnitch-ui
                  ];
                  # Also allow this key to work for root user, this will let us use this as a remote builder easier
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                  ];
                  # Allow emulation of aarch64-linux binaries for cross compiling
                  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

                  home-manager.extraSpecialArgs = {
                    inherit inputs;
                    inherit upkgs;
                  };

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    secrets.enable = true;
                    general = {
                      reporting.enable = true;
                      disableRemoteBuildsOnLio = true;
                    };
                    desktopEnvironment.sway = {
                      enable = true;
                      waybar.enable = true;
                      swaync.enable = true;
                    };
                    programs = {
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      tailnet.enableExitNode = true;
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
                          "com.bitwarden.desktop"
                          "org.openscad.OpenSCAD"
                          "org.blender.Blender"
                          "com.rustdesk.RustDesk"
                        ];
                      };
                    };
                    users = {
                      # Users are all normal users and default password is password1
                      admins = [ "josh" ]; # First admin is also the primary user owning nix config
                      users = {
                        josh = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                          ];
                          extraGroups = [
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                          packages = with pkgs; [
                            sabnzbd
                          ];
                        };
                      };
                    };
                    homeManager = {
                      users = {
                        josh = {
                          imports = with common.homeManagerModules; [
                            tmux
                            atuin
                            kitty
                            foot
                            direnv
                            git
                            nix_deprecations
                            obs
                            postgres
                            slicer
                            ssh
                            starship
                            zoxide
                            zsh
                          ];

                          # services.opensnitch-ui.enable = true;
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
