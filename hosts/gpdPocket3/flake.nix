{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    # for local testing.
    common.url = "path:../../common";
    # common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      ...
    }:
    let
      configuration_name = "gpdPocket3";
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
                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                  ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    desktopEnvironment.gnome = {
                      enable = true;
                      enableRotate = true;
                    };
                    secrets.enable = true;
                    general.enableSleep = true;
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      docker.enable = true;
                      opencode.enable = true;
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
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDa0MUnXwRzHPTDakjzLTmye2GTFbRno+KVs0DSeIPb7 nix2gpdpocket3"
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
                            tmux
                            atuin
                            kitty
                            direnv
                            git
                            nix_deprecations
                            postgres
                            ssh
                            starship
                            zoxide
                            zsh
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
