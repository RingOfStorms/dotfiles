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
      # Standalone host telemetry & status agent (`ringofstorms.fleetAgent`),
      # re-exported from flakes/fleet-agent.
      nixosModules.agent =
        { pkgs, ... }:
        {
          imports = [ ../flakes/fleet-agent/agent-module.nix ];
          ringofstorms.fleetAgent.package = nixpkgs.lib.mkDefault (
            pkgs.callPackage ../flakes/fleet-agent/default.nix { }
          );
        };

      # Hosts import this once: inputs.containers.nixosModules.default
      nixosModules.default =
        { pkgs, ... }:
        let
          fleetPkg = pkgs.callPackage ../flakes/fleet-agent/default.nix { };
        in
        {
          imports = [
            extra-container.nixosModules.default
            ../flakes/fleet-agent/agent-module.nix
            ./host-module.nix
          ];
          # the CLI/agent, built with the host's pkgs (no extra nixpkgs eval)
          ringofstorms.containers.package = nixpkgs.lib.mkDefault fleetPkg;
          ringofstorms.fleetAgent.package = nixpkgs.lib.mkDefault fleetPkg;
        };

      lib = containersLib;

      # Inventory read by the `containers` CLI:
      #   nix eval --json <ref>#inventory
      inventory = {
        inherit services;
        hosts = (import ../hosts/fleet.nix).hosts;
        # Hosts that run (or may run) floating containers; the CLI probes them
        # to find where a service is installed. The CLI also probes every host
        # the placement registry knows and, while `host` is still a build-time
        # seed, every host a service.nix declares (PLACEMENT-PLAN.md §6), so
        # this list must name the hosts that hold a service and nothing else —
        # a host that only ever held one would otherwise vanish from discovery
        # once phase 5 drops the declared-host loop. Laptops stay unlisted
        # except `joe`, which runs localai. A host that is offline only
        # matters for the services placed on it.
        containerHosts = [
          "h001"
          "h003"
          "lio"
          "joe"
        ];
        # Every host running fleet-agent (:9101), including NAS/router/VPS/laptops.
        agentHosts = builtins.filter (
          h: ((import ../hosts/fleet.nix).hosts.${h}.overlayIp or null) != null
        ) (builtins.attrNames (import ../hosts/fleet.nix).hosts);
        dataRoot = containersLib.dataRoot;
        # LAN subnet, for the `weblan` ports-file lines (host-module.nix).
        lanSubnet = containersLib.lanSubnet;
      };

      packages = forAll (pkgs: rec {
        fleet = pkgs.callPackage ../flakes/fleet-agent/default.nix { };
        containers = fleet;
        default = fleet;
      });

      apps = forAll (pkgs: rec {
        fleet = {
          type = "app";
          program = "${self.packages.${pkgs.system}.fleet}/bin/fleet";
        };
        containers = {
          type = "app";
          program = "${self.packages.${pkgs.system}.fleet}/bin/containers";
        };
        default = fleet;
      });
    };
}
