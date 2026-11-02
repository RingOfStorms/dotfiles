{
  description = "life: Life server + PostgreSQL 18 as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest is pinned to a fixed rev (postgresql_18, matching the persisted cluster).
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
    # Locked in flake.lock; bump with `nix flake update life`.
    life.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/life.git";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      life,
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
          # Private network from service.nix net; idmapped persist (ext4).
          specialArgs = { inherit life; };
          binds = [
            {
              host = "${fleet.global.secretsDir}/life_pgbackrest_2026-09-30";
              container = "/run/secrets/life-pgbackrest.conf";
              readOnly = true;
            }
            {
              host = "${fleet.global.secretsDir}/life_backup_env_2026-09-30";
              container = "/run/secrets/life-backup.env";
              readOnly = true;
            }
          ];
        };
      };
    });
}
