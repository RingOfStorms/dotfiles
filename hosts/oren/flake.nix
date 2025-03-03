{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_secrets.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_secrets";
    mod_boot_systemd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_boot_systemd";
    mod_de_gnome.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_de_gnome";
    mod_home-manager.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_home_manager";
    mod_home-manager.inputs.home-manager.url = "github:rycee/home-manager/release-24.11";
  };

  outputs =
    {
      nixpkgs,
      ...
    }@inputs:
    let
      configuration_name = "oren";
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
              (
                { pkgs, ... }:
                {
                  imports = [
                    ../../components/nix/lua.nix
                    ../../components/nix/rust-dev.nix
                    ../../components/nix/qflipper.nix
                    ../../components/nix/qdirstat.nix
                    ../../components/nix/tailscale.nix
                  ];
                  mods = {
                    common = {
                      systemName = configuration_name;
                      allowUnfree = true;
                      primaryUser = "josh";
                      docker = true;
                      zsh = true;
                      users = {
                        josh = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMzgAe4od9K4EsvH2g7xjNU7hGoJiFJlYcvB0BoDCvn nix2oren"
                          ];
                          initialPassword = "password1";
                          isNormalUser = true;
                          extraGroups = [
                            "wheel"
                            "networkmanager"
                            "video"
                            "input"
                          ];
                          shell = pkgs.zsh;
                          packages = with pkgs; [
                            signal-desktop
                            google-chrome
                            discordo
                            discord
                            firefox-esr
                          ];
                        };
                      };
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
                            ../../components/hm/postgres.nix
                            ../../components/hm/ssh.nix
                            ../../components/hm/starship.nix
                            ../../components/hm/zoxide.nix
                            ../../components/hm/zsh.nix
                          ];
                          components.kitty.font_size = 20.0;
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
