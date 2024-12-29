{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:rycee/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      home-manager,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          with lib;
          {
            options.mods.home_manager = {
              users = mkOption {
                type = types.attrsOf types.attrs;
                default = { };
                description = "Home manager users to configure. Should match nix options of home-manager.users.<name>.*";
              };
            };
            imports = [ home-manager.nixosModules.home-manager ];
            config = {
              # Home manager options
              security.polkit.enable = true;
              home-manager.useUserPackages = true;
              home-manager.useGlobalPkgs = true;
              home-manager.extraSpecialArgs = {
                nixConfig = config;
              };
              home-manager.backupFileExtension = "bak";

              home-manager.users = mapAttrs' (name: user: {
                inherit name;
                value = user // {
                  # TODO does this need to be per user per machine and updated better?
                  home.stateVersion = "23.11";
                  programs.home-manager.enable = true;
                  home.username = name;
                  home.homeDirectory = lib.mkForce "/home/${name}";
                };
              }) config.mods.home_manager.users;
            };
          };
      };
    };
}
