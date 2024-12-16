{
  description = "Dummy Stormd Service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system: {
        stormd = nixpkgs.legacyPackages.${system}.writeScriptBin "stormd" ''
          #!${nixpkgs.legacyPackages.${system}.bash}/bin/bash
          echo "This is a dummy stormd implementation"
          exit 0
        '';
        default = self.packages.${system}.stormd;
      });

      apps = forAllSystems (system: {
        stormd = {
          type = "app";
          program = "${self.packages.${system}.stormd}/bin/stormd";
        };
        default = self.apps.${system}.stormd;
      });

      overlays = forAllSystems (system: [ (final: prev: { stormd = self.packages.${system}.stormd; }) ]);

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ self.packages.${system}.stormd ];
        };
      });

      nixosModules = forAllSystems (
        system:
        { config, lib, ... }:
        {
          options = {
            services.stormd = {
              enable = lib.mkEnableOption "Enable the Stormd service.";
              extraOptions = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Extra options to pass to stormd daemon.";
              };
              rootUser = lib.mkOption {
                type = lib.types.str;
                default = "root";
                description = "Root user name that will have stormd available.";
              };
              nebulaPackage = lib.mkOption {
                type = lib.types.package;
                default = self.packages.${system}.stormd;
                description = "The nebula package to use.";
              };
            };
          };

          config = lib.mkIf config.services.stormd.enable { };
        }
      );
    };
}
