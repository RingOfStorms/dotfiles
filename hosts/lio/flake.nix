{
  description = "lio system flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_common.inputs.nixpkgs.follows = "nixpkgs";
    mod_boot_systemd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_boot_systemd";
    mod_de_cosmic.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_de_cosmic";
    mod_de_cosmic.inputs.nixpkgs-stable.follows = "nixpkgs";
    mod_de_cosmic.inputs.nixpkgs.follows = "nixpkgs";
    mod_ros_neovim.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_neovim";
    mod_ros_stormd.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_stormd";
    mod_nebula.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_nebula";
    mod_home-manager.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_home_manager";
    mod_home-manager.inputs.home-manager.url = "github:rycee/home-manager/release-24.11";
    mod_home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
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
              (
                { pkgs, ... }:
                {
                  imports = [
                    ../../components/nix/lua.nix
                    ../../components/nix/rust-repl.nix
                    ../../components/nix/qflipper.nix
                    ../../components/nix/qdirstat.nix
                    ../../components/nix/steam.nix
                  ];

                  # Also allow this key to work for root user, this will let us use this as a remote builder easier
                  users.users.root.openssh.authorizedKeys.keys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
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
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
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
                            spotify
                            blender
                            google-chrome
                            discordo
                            discord
                            # nautilus qimgv # file browsing (not needed in cosmic)
                            firefox-esr
                            # freecad
                            # openscad
                            # ladybird
                            # ollama
                            vlc
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
                            ../../components/hm/obs.nix
                            ../../components/hm/postgres.nix
                            ../../components/hm/slicer.nix
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
