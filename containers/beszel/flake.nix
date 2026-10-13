{
  description = "beszel: Beszel monitoring hub as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs the nixpkgs rev h001 runs today. Its beszel is
    # 0.18.7, the same as the old beszel-nixpkgs pin (ffb3c9b), which hit an
    # infinite recursion when evaluated as a container guest.
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
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
          # Host network (binds the host's tailnet IP); idmapped persist (ext4).
          privateNetwork = false;
        };
      };
    });
}
