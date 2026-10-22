{
  description = "Floating self-hosted services (nspawn + podman) and the `containers` CLI";

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
      containersLib = import ./lib.nix;
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
      # checkNetIndexes: two services with the same net.index fail the eval.
      services = builtins.listToAttrs (
        map (s: {
          name = s.dir;
          value = s;
        }) (containersLib.checkNetIndexes (map serviceOf serviceDirs))
      );
      serviceOf =
        dir:
        let
          s = containersLib.normalize (import (./. + "/${dir}/service.nix"));
        in
        s
        // {
          inherit dir;
          persistPaths = containersLib.persistList s;
        };
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
          ringofstorms.containers.package = nixpkgs.lib.mkDefault (pkgs.callPackage ./cli { });
        };

      lib = containersLib;

      # Inventory read by the `containers` CLI:
      #   nix eval --json <ref>#inventory
      inventory = {
        inherit services;
        hosts = (import ../hosts/fleet.nix).hosts;
        # Hosts that run (or may run) floating containers; the CLI probes them
        # to find where a service is installed. Hosts declared in a
        # service.nix are added automatically. Laptops are not listed, so
        # their being offline never matters.
        containerHosts = [
          "h001"
          "h003"
          "lio"
        ];
        dataRoot = containersLib.dataRoot;
      };

      packages = forAll (pkgs: rec {
        containers = pkgs.callPackage ./cli { };
        default = containers;
      });

      apps = forAll (pkgs: rec {
        containers = {
          type = "app";
          program = "${self.packages.${pkgs.system}.containers}/bin/containers";
        };
        default = containers;
      });
    };
}
