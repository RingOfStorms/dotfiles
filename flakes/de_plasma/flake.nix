{
  inputs = {
    plasma-manager.url = "github:nix-community/plasma-manager";
  };

  outputs = { plasma-manager, ... }: {
    nixosModules = {
      default =
        { config, lib, pkgs, ... }:
        {
          imports = [
            ./de_plasma.nix
          ];
          config = {
            _module.args = {
              inherit plasma-manager;
            };
          };
        };
    };
  };
}
