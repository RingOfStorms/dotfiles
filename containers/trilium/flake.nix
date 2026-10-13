{
  description = "trilium: Trilium notes + oauth2-proxy as one floating container";

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
      fleet = import ../../hosts/fleet.nix;
      # Rendered on h001 by sec-agent (hosts/h001/sec-agent.nix). Dated name:
      # a rotation is a new path, so binding the single file is safe.
      envSecret = "${fleet.global.secretsDir}/oauth2_proxy_key_file_2026-03-15";
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          # Host network; idmapped persist (ext4), container uids are not host uids.
          privateNetwork = false;
          binds = [
            {
              host = envSecret;
              container = "/var/secrets/oauth2-proxy.env";
              readOnly = true;
            }
          ];
        };
      };
    });
}
