{
  description = "dawarich: location history (location.joshuabell.xyz) as a floating container";

  # Managed with the `containers` CLI (see ../README.md and ./README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs the rev the old h001 container ran (dawarich-nixpkgs lock; PG 17 + postgis 3.6).
    guestpkgs.url = "github:nixos/nixpkgs/331800de5053fcebacf6813adb5db9c9dca22a0c";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      ...
    }:
    let
      containersLib = import ../lib.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          # Network: service.nix net (private).
        };
      };
    });
}
