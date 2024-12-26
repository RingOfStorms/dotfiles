{
  description = "Oren system flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mods_common.url = "../../modules/common";
    mods_common.inputs.nixpkgs.follows = "nixpkgs";
    mods_boot_systemd.url = "../../modules/boot_systemd";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      mods_boot_systemd,
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
                {
                  ...
                }:
                {
                  mods = {
                    common = {
                      systemName = configuration_name;
                      allowUnfree = true;
                      primaryUser = "josh";
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
