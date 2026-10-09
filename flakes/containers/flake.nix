{
  description = "Floating self-hosted services (nspawn + podman) and the `boxes` CLI";

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs =
    {
      self,
      extra-container,
      nixpkgs,
      ...
    }:
    let
      boxesLib = import ./lib.nix;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # Every subdirectory with a service.nix is a service.
      entries = builtins.readDir ./.;
      serviceDirs = builtins.filter (
        n: entries.${n} == "directory" && builtins.pathExists (./. + "/${n}/service.nix")
      ) (builtins.attrNames entries);
      services = builtins.listToAttrs (
        map (dir: {
          name = dir;
          value =
            let
              s = boxesLib.normalize (import (./. + "/${dir}/service.nix"));
            in
            s
            // {
              inherit dir;
              persistPaths = boxesLib.persistList s;
            };
        }) serviceDirs
      );
    in
    {
      # Hosts import this once: inputs.containers.nixosModules.default
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [
            extra-container.nixosModules.default
            ./host-module.nix
          ];
          # the CLI, built with the host's pkgs (no extra nixpkgs eval)
          boxes.package = nixpkgs.lib.mkDefault (pkgs.callPackage ./boxes { });
        };

      lib = boxesLib;

      # Inventory read by the `boxes` CLI:
      #   nix eval --json <ref>#inventory
      inventory = {
        inherit services;
        hosts = (import ../../hosts/fleet.nix).hosts;
        dataRoot = boxesLib.dataRoot;
      };

      packages = forAll (pkgs: rec {
        boxes = pkgs.callPackage ./boxes { };
        default = boxes;
      });

      apps = forAll (pkgs: rec {
        boxes = {
          type = "app";
          program = "${self.packages.${pkgs.system}.boxes}/bin/boxes";
        };
        default = boxes;
      });
    };
}
