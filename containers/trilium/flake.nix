{
  description = "trilium: Trilium notes as a floating container (gated by the fleet oauth2-proxy)";

  # Managed with the `containers` CLI (see ../README.md and ./README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest is pinned to the unstable rev h001 ran trilium 0.103.0 and
    # oauth2-proxy from (trilium migrates its DB forward; 26.05 has 0.102.2,
    # a downgrade). Bump deliberately, after a `cnt backup trilium`.
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
