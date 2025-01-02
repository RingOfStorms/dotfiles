{
  description = "oren system flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    mods_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mods_common.inputs.nixpkgs.follows = "nixpkgs";
    mods_boot_systemd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_boot_systemd";
    mods_de_cosmic.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_de_cosmic";
    mods_de_cosmic.inputs.nixpkgs-stable.follows = "nixpkgs";
    mods_de_cosmic.inputs.nixpkgs.follows = "nixpkgs";
    mods_ros_neovim.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_neovim";
    mods_ros_stormd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_stormd";
    mods_nebula.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_nebula";
    mods_home-manager.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_home_manager";
    mods_home-manager.inputs.home-manager.url = "github:rycee/home-manager/release-24.11";
    mods_home-manager.inputs.nixpkgs.follows = "nixpkgs";
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
                    ../../components/nix/rust-repl.nix
                    ../../components/nix/qflipper.nix
                    ../../components/nix/qdirstat.nix
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
                            # nautilus qimgv # file browsing (not needed in cosmic)
                            firefox-esr
                            # freecad
                            # ladybird
                            # ollama
                            # vlc
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
                            ../../components/hm/atuin.nix
                            ../../components/hm/direnv.nix
                            ../../components/hm/git.nix
                            # ../../components/hm/launcher_rofi.nix # not needed in cosmic
                            ../../components/hm/nix_deprecations.nix
                            ../../components/hm/postgres.nix
                            ../../components/hm/ssh.nix
                            ../../components/hm/starship.nix
                            ../../components/hm/zoxide.nix
                            ../../components/hm/zsh.nix
                          ];
                        };
                        # root = {
                        #   imports = [
                        #     ../../components/hm/nix_deprecations.nix
                        #     ../../components/hm/postgres.nix
                        #     ../../components/hm/starship.nix
                        #     ../../components/hm/zoxide.nix
                        #     ../../components/hm/zsh.nix
                        #   ];
                        # };
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
