{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    # common.url = "path:../../common";
    common.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";

    ros_neovim.url = "git+https://git.joshuabell.xyz/ringofstorms/nvim";

    nixarr.url = "github:rasmus-kirk/nixarr";
  };

  outputs =
    {
      nixpkgs,
      common,
      ros_neovim,
      nixarr,
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
              nixarr.nixosModules.default
              ./configuration.nix
              ./hardware-configuration.nix
              (import ./containers.nix { inherit inputs; })
              (
                { config, pkgs, ... }:
                {
                  # nixarr = {
                  #   enable = true;
                  #   # These two values are also the default, but you can set them to whatever
                  #   # else you want
                  #   # WARNING: Do _not_ set them to `/home/user/whatever`, it will not work!
                  #   mediaDir = "/var/lib/nixarr_test/media";
                  #   stateDir = "/var/lib/nixarr_test/state";
                  #
                  #   # vpn = {
                  #   #   enable = true;
                  #   #   # WARNING: This file must _not_ be in the config git directory
                  #   #   # You can usually get this wireguard file from your VPN provider
                  #   #   wgConf = "/data/.secret/wg.conf";
                  #   # };
                  #
                  #   jellyfin = {
                  #     enable = true;
                  #     # These options set up a nginx HTTPS reverse proxy, so you can access
                  #     # Jellyfin on your domain with HTTPS
                  #     expose.https = {
                  #       enable = true;
                  #       domainName = "your.domain.com";
                  #       acmeMail = "your@email.com"; # Required for ACME-bot
                  #     };
                  #   };
                  #
                  #   # transmission = {
                  #   #   enable = true;
                  #   #   vpn.enable = true;
                  #   #   peerPort = 50000; # Set this to the port forwarded by your VPN
                  #   # };
                  #
                  #   # It is possible for this module to run the *Arrs through a VPN, but it
                  #   # is generally not recommended, as it can cause rate-limiting issues.
                  #   sabnzbd.enable = true; # Usenet downloader
                  #   prowlarr.enable = true; # Index manager
                  #   sonarr.enable = true; # TV
                  #   radarr.enable = true; # Movies
                  #   bazarr.enable = true; # subtitles for sonarr and radarr
                  #   lidarr.enable = true; # music
                  #   readarr.enable = true; # books
                  #   jellyseerr.enable = true; # request manager for media
                  # };

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
