{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    ros_neovim.url = "git+https://git.joshuabell.xyz/nvim";
    mod_common.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_common";
    mod_common.inputs.nixpkgs.follows = "nixpkgs";
    mod_boot_grub.url = "git+https://git.joshuabell.xyz/dotfiles?ref=mod_boot_grub";
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
      configuration_name = "h002";
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
                  ];

                  mods = {
                    common = {
                      systemName = configuration_name;
                      allowUnfree = true;
                      primaryUser = "luser";
                      docker = true;
                      zsh = true;
                      users = {
                        luser = {
                          openssh.authorizedKeys.keys = [
                            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJie9OPheWn/EZWfXJSZ3S0DnISqI3ToCmOqhX/Tkwby nix2h002"
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
                        };
                      };
                    };
                    home_manager = {
                      users = {
                        luser = {
                          imports = [
                            ../../components/hm/tmux/tmux.nix
                            ../../components/hm/atuin.nix
                            ../../components/hm/direnv.nix
                            ../../components/hm/git.nix
                            ../../components/hm/nix_deprecations.nix
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
