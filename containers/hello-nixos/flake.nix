{
  description = "hello-nixos: test nspawn service serving the nginx splash page";

  # Managed with the `containers` CLI (see ../README.md).
  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # 25.11: extra-container's minimal eval-config breaks on unstable (issue #40).
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs =
    { extra-container, nixpkgs, ... }:
    let
      containersLib = import ../lib.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
        };
      };
    });
}
