{
  description = "life: Life server + PostgreSQL 18 as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs the nixpkgs rev h001 runs today (postgresql_18 as before).
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
    # Locked to the rev h001 runs today (4ef30d9); bump with `nix flake update life`.
    life.url = "git+ssh://git@git.joshuabell.xyz:3032/ringofstorms/life.git?rev=4ef30d9189aa25b1d710f2f8fb65a5274aa6bf52";
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
          # Host network; idmapped persist (ext4).
          privateNetwork = false;
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
