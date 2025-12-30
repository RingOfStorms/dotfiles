{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    i001.url = "path:./hosts/i001";
    l001.url = "path:./hosts/linode/l001";
    o001.url = "path:./hosts/oracle/o001";
  };

  outputs =
    {
      ...
    }@inputs:
    let
      # Utilities
      inherit (inputs.nixpkgs) lib;
      # Define the systems to support: https://github.com/NixOS/nixpkgs/blob/master/lib/systems/flake-systems.nix
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      # Create a mapping from system to corresponding nixpkgs : https://nixos.wiki/wiki/Overlays#In_a_Nix_flake
      nixpkgsFor = forAllSystems (system: inputs.nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              # Some aliases for building + deploying to some remote systems.
              (pkgs.writeShellScriptBin "deploy_l001" ''
                nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/linode/l001' --target-host l001 --use-substitutes --no-reexec switch
              '')
              (pkgs.writeShellScriptBin "deploy_o001" ''
                nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/oracle/o001' --target-host o001 --use-substitutes --no-reexec switch
              '')
              (pkgs.writeShellScriptBin "deploy_h001" ''
                nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/h001' --target-host h001 --use-substitutes --no-reexec switch
              '')
              (pkgs.writeShellScriptBin "deploy_i001" ''
                NIX_SSHOPTS="-i /run/agenix/nix2nix" nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/i001' --target-host root@10.12.14.119 --use-substitutes --no-reexec switch
              '')
              (pkgs.writeShellScriptBin "deploy_h002" ''
                NIX_SSHOPTS="-i /run/agenix/nix2nix" nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/h002' --target-host root@10.12.14.183 --use-substitutes --no-reexec switch
              '')
              (pkgs.writeShellScriptBin "deploy_juni" ''
                NIX_SSHOPTS="-i /run/agenix/nix2nix" nixos-rebuild --flake $(git rev-parse --show-toplevel)'/hosts/juni' --target-host josh@10.12.14.172 --use-substitutes --no-reexec switch
              '')
            ];
          };
        }
      );
    };
}
