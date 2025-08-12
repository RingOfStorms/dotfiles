{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    # Use relative to get current version for testing
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
    }@inputs:
    let
      configuration_name = "lio";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" = (
          lib.nixosSystem {
            specialArgs = { inherit inputs; };
            modules = [
              common.nixosModules.default
              ros_neovim.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              (import ./containers.nix { inherit inputs; })
              # ./jails_text.nix
              (
                {
                  config,
                  pkgs,
                  lib,
                  ...
                }:
                {
                  programs = {
                    steam.enable = true;
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                    steam
                    ffmpeg-full
                    appimage-run
                  ];

                  # Also allow this key to work for root user, this will let us use this as a remote builder easier
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                  ];
                  # Allow emulation of aarch64-linux binaries for cross compiling
                  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    secrets.enable = true;
                    general = {
                      reporting.enable = true;
                      disableRemoteBuildsOnLio = true;
                    };
                    desktopEnvironment.gnome.enable = true;
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      tailnet.enableExitNode = true;
                      ssh.enable = true;
                      docker.enable = true;
                      opencode.enable = true;
                      virt-manager.enable = true;
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
