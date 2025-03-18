{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    common.url = "path:./common";
  };

  outputs =
    {
      nixpkgs,
      common,
      ...
    }:
    let
      # Utilities
      inherit (nixpkgs) lib;
      # Define the systems to support: https://github.com/NixOS/nixpkgs/blob/master/lib/systems/flake-systems.nix
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      # Create a mapping from system to corresponding nixpkgs : https://nixos.wiki/wiki/Overlays#In_a_Nix_flake
      nixpkgsFor = forAllSystems (system: nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          deploy_linode = pkgs.writeShellScriptBin "deploy_linode" ''
            cwd=$(pwd)
            root=$(git rev-parse --show-toplevel)
            if [ ! -d "$root/hosts/linode/$1" ]; then
              echo "Host $1 does not exist"
              exit 1
            fi
            cd "$root/hosts/linode/$1"
            echo "Deploying linode $(basename "$(pwd)")..."
            deploy
            cd "$cwd"
          '';
          deploy_oracle = pkgs.writeShellScriptBin "deploy_oracle" ''
            cwd=$(pwd)
            root=$(git rev-parse --show-toplevel)
            if [ ! -d "$root/hosts/oracle/$1" ]; then
              echo "Host $1 does not exist"
              exit 1
            fi
            cd "$root/hosts/oracle/$1"
            echo "Deploying oracle $(basename "$(pwd)")..."
            deploy
            cd "$cwd"
          '';
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              deploy_oracle
              deploy_linode
              deploy-rs
            ];
          };
        }
      );

      nixosModules = common.nixosModules;
      homeManagerModules = common.homeManagerModules;
    };
}
