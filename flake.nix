{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";

    i001.url = "path:./hosts/i001";
    l001.url = "path:./hosts/linode/l001";
    o001.url = "path:./hosts/oracle/o001";
  };

  outputs =
    {
      deploy-rs,
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
              inputs.deploy-rs.packages.${system}.default
            ];
          };
        }
      );

      deploy = {
        sshUser = "root";
        sshOpts = [
          "-i"
          "/run/agenix/nix2nix"
        ];

        nodes = {
          i001 = {
            hostname = "10.12.14.119"; # NOTE not stable ip check...
            profiles.system = {
              user = "root";
              path = deploy-rs.lib.x86_64-linux.activate.nixos inputs.i001.nixosConfigurations.i001;
            };
          };

          l001 = {
            sshOpts = [
              "-i"
              "/run/agenix/nix2linode"
            ];
            hostname = "172.236.111.33";
            profiles.system = {
              user = "root";
              path = deploy-rs.lib.x86_64-linux.activate.nixos inputs.l001.nixosConfigurations.l001;
            };
          };

          o001 = {
            sshOpts = [
              "-i"
              "/run/agenix/nix2oracle"
            ];
            hostname = "64.181.210.7";
            profiles.system = {
              user = "root";
              path = deploy-rs.lib.aarch64-linux.activate.nixos inputs.o001.nixosConfigurations.o001;
            };
          };
        };
      };
    };
}
