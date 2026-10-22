{
  description = "puzzles: puzzles server as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs the nixpkgs rev h001 runs today.
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
    # Locked to the rev h001 runs today (a3e1f7d); bump with `nix flake update puzzles`.
    puzzles.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/puzzles.git?rev=a3e1f7d37dc38652f3765269709f1ebdd9cc325f";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      puzzles,
      ...
    }:
    let
      containersLib = import ../lib.nix;
      fleet = import ../../hosts/fleet.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          # Network: service.nix net (private, 10.233.2.2); idmapped persist (ext4).
          specialArgs = { inherit puzzles; };
          binds = [
          ];
        };
      };
    });
}
