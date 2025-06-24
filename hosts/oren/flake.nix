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
              (
                { config, pkgs, ... }:
                {
                  programs = {
                    steam.enable = true;
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
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
                    };
                    secrets.enable = true;
                    desktopEnvironment.gnome.enable = true;
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      docker.enable = true;
                      flatpaks = {
                        enable = true;
                        packages = [
                          "org.signal.Signal"
                          "com.discordapp.Discord"
                          "md.obsidian.Obsidian"
                          "com.spotify.Client"
                          "org.videolan.VLC"
                          "com.bitwarden.desktop"
                          "org.openscad.OpenSCAD"
                          "org.blender.Blender"
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
                          components.kitty.font_size = 20.0;
                          imports = with common.homeManagerModules; [
                            zsh
                            ssh
                            starship
                            zoxide
                            tmux
                            atuin
                            kitty
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
