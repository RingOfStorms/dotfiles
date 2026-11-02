{
  description = "paperless-ngx: documents (docs.joshuabell.xyz) as a floating container";

  # Managed with the `containers` CLI (see ../README.md and ./README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest is pinned to a fixed rev; bump deliberately, after a `cnt backup`.
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
          # Media stays on /drives/wd10 (service.nix requires "wd10"); not in
          # persist, so `cnt backup` skips it (the host's restic job covers it).
          binds = [
            {
              host = "/drives/wd10/paperless/media";
              container = "/var/lib/paperless/media";
            }
            {
              host = "/drives/wd10/paperless/consume";
              container = "/var/lib/paperless/consume";
            }
          ];
        };
      };
    });
}
