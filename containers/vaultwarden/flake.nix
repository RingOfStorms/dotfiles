{
  description = "vaultwarden: password manager as a floating container";

  # Managed with the `containers` CLI (see ../README.md and ./README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs 26.05 (same as h001).
    guestpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
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
      envSecret = "${fleet.global.secretsDir}/vaultwarden_env_2026-03-15";
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
              container = "/var/secrets/vaultwarden.env";
              readOnly = true;
            }
          ];
        };
      };
    });
}
