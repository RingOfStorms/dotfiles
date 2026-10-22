{
  description = "fleet-agent & fleet CLI - bare-metal host status/metrics/log agent and floating container CLI";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      agentModule =
        { pkgs, lib, ... }:
        {
          imports = [ ./agent-module.nix ];
          ringofstorms.fleetAgent.package = lib.mkDefault (pkgs.callPackage ./default.nix { });
        };
    in
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = rec {
          fleet = pkgs.callPackage ./default.nix { };
          fleet-agent = fleet;
          containers = fleet;
          default = fleet;
        };

        apps = rec {
          fleet = {
            type = "app";
            program = "${self.packages.${system}.fleet}/bin/fleet";
          };
          containers = {
            type = "app";
            program = "${self.packages.${system}.fleet}/bin/containers";
          };
          default = fleet;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            gopls
            gotools
            openssh
            zstd
            util-linux
          ];
        };
      }
    )
    // {
      nixosModules = {
        default = agentModule;
        agent = agentModule;
      };
    };
}
