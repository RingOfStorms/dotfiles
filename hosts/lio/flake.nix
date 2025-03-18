{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Use relative to get current version for testing
    common.url = "path:../../common";
    # Pin to specific version
    # common.url = "git+https://git.joshuabell.xyz/dotfiles?rev=88f2d95e6a871f084dccfc4f45ad9d2b31720998";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_home-manager.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_home_manager";
    mod_secrets.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_secrets";
    mod_de_gnome.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_de_gnome";
    mod_ros_stormd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_stormd";
    mod_nebula.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_nebula";
  };

  outputs =
    {
      nixpkgs,
      common,
      ...
    }@inputs:
    let
      configuration_name = "lio";
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations = {
        "${configuration_name}" =
          let
            auto_modules = builtins.concatMap (
              input:
              lib.optionals
                (builtins.hasAttr "nixosModules" input && builtins.hasAttr "default" input.nixosModules)
                [
                  input.nixosModules.default
                ]
            ) (builtins.attrValues inputs);
          in
          (lib.nixosSystem {
            modules = [
              ./configuration.nix
              ./hardware-configuration.nix
              ./containers.nix
              (
                { config, pkgs, ... }:
                {
                  ringofstorms_common = {
                    systemName = configuration_name;
                    boot.systemd.enable = true;
                    general = {
                      disableRemoteBuildsOnLio = true;
                    };
                    programs = {
                      qFlipper.enable = true;
                      rustDev.enable = true;
                      uhkAgent.enable = true;
                      tailnet.enable = true;
                      ssh.enable = true;
                      docker.enable = true;
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
                            signal-desktop
                            spotify
                            blender
                            google-chrome
                            discordo
                            discord
                            firefox-esr
                            openscad
                            vlc
                            bitwarden
                            vaultwarden
                          ];
                        };
                      };
                    };
                  };

                  programs = {
                    steam.enable = true;
                  };

                  environment.systemPackages = with pkgs; [
                    lua
                    qdirstat
                    # qflipper
                    steam
                  ];

                  # Also allow this key to work for root user, this will let us use this as a remote builder easier
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
                  ];
                  # Allow emulation of aarch64-linux binaries for cross compiling
                  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

                  mods = {
                    common = {
                      zsh = true;
                      # still used somewhere...
                      systemName = configuration_name;
                      primaryUser = "josh";
                    };
                    home_manager = {
                      users = {
                        josh = {
                          imports = [
                            ../../components/hm/tmux/tmux.nix
                            ../../components/hm/alacritty.nix
                            ../../components/hm/kitty.nix
                            ../../components/hm/atuin.nix
                            ../../components/hm/direnv.nix
                            ../../components/hm/git.nix
                            ../../components/hm/nix_deprecations.nix
                            ../../components/hm/obs.nix
                            ../../components/hm/postgres.nix
                            ../../components/hm/slicer.nix
                            ../../components/hm/ssh.nix
                            ../../components/hm/starship.nix
                            ../../components/hm/zoxide.nix
                            ../../components/hm/zsh.nix
                          ];
                        };
                      };
                    };
                  };
                }
              )
            ] ++ auto_modules;
            specialArgs = {
              inherit inputs;
            };
          });
      };
    };
}
