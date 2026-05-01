# h001 Immich upgrade — pgvecto-rs → vectorchord migration plan

## Background

The `immich-nixpkgs` flake input (pinned to `nixos-unstable`) was bumped past
the commit that removes the `pgvecto-rs` PostgreSQL extension. Upstream
abandoned pgvecto-rs; the NixOS `services.immich` module now uses
`vectorchord` (extension name `vchord`) instead.

Symptom on `nh os switch`:

```
error: PostgreSQL extension `pgvecto-rs` has been removed since the project
has been abandoned. Upstream's recommendation is to use vectorchord instead
(https://docs.vectorchord.ai/vectorchord/admin/migration.html#from-pgvecto-rs)
```

The `flake.lock` has been reverted to the pre-breaking-change revision so the
host continues to build. This document is the plan for redoing the upgrade
properly.

## What changed upstream (in nixpkgs)

In the new `services.immich` module
(`nixos/modules/services/web-apps/immich.nix`):

- `database.enableVectorChord` is deprecated — vectorchord is always on.
- `database.enableVectors` is deprecated — pgvecto-rs is gone.
- When `services.immich.database.enable = true` the module **automatically**:
  - sets `services.postgresql.extensions = ps: [ ps.pgvector ps.vectorchord ]`
  - sets `services.postgresql.settings.shared_preload_libraries = [ "vchord.so" ]`
  - sets `search_path = "\"$user\", public, vectors"`
  - runs an init SQL script that:
    - `CREATE EXTENSION IF NOT EXISTS vchord` (and friends)
    - `ALTER EXTENSION ... UPDATE`
    - reindexes when vectorchord version changes
- The systemd unit now depends on `postgresql.target` (not
  `postgresql.service`).

## Required code change in this repo

File: `hosts/h001/containers/immich.nix`

Currently (broken with new nixpkgs):

```nix
services.postgresql = {
  enable = true;
  package = pkgs.${"postgresql_${postgresVersion}"}.withPackages (ps: [ ps.pgvecto-rs ]);
  enableJIT = true;
  authentication = ''
    local all all trust
    host all all 127.0.0.1/8 trust
    host all all ::1/128 trust
    host all all fc00::1/128 trust
  '';
  ensureDatabases = [ "immich" ];
  ensureUsers = [
    {
      name = "immich";
      ensureDBOwnership = true;
      ensureClauses.login = true;
    }
  ];
  settings = {
    shared_preload_libraries = [ "vectors.so" ];
  };
};
```

Change to:

```nix
services.postgresql = {
  enable = true;
  package = pkgs.${"postgresql_${postgresVersion}"};
  enableJIT = true;
  authentication = ''
    local all all trust
    host all all 127.0.0.1/8 trust
    host all all ::1/128 trust
    host all all fc00::1/128 trust
  '';
  ensureDatabases = [ "immich" ];
  ensureUsers = [
    {
      name = "immich";
      ensureDBOwnership = true;
      ensureClauses.login = true;
    }
  ];
  # NOTE: pgvecto-rs has been removed upstream; the immich module now
  # injects pgvector + vectorchord extensions and the
  # `shared_preload_libraries = [ "vchord.so" ]` setting itself when
  # services.immich.database.enable = true. Don't override.
};
```

i.e. drop the `.withPackages (ps: [ ps.pgvecto-rs ])` and drop the manual
`settings.shared_preload_libraries`.

The existing `systemd.services.immich-server.{requires,after} =
[ "postgresql.service" ]` override is now redundant (module uses
`postgresql.target`) but not broken; can be left alone or removed.

## Data migration — DO THIS BEFORE BUMPING THE LOCK

The current immich postgres database has the old `vectors` (pgvecto-rs)
extension and uses it for the smart-search CLIP embeddings. After the
upgrade, immich will be running against vectorchord, and the old `vectors`
schema/columns won't be readable. You must migrate (or wipe) before
restarting immich on the new code.

Refs:
- https://docs.vectorchord.ai/vectorchord/admin/migration.html#from-pgvecto-rs
- https://docs.immich.app/administration/postgres-standalone/#updating-vectorchord

### Step 0: full backup (always)

```sh
# On h001 host
sudo nixos-container run immich -- \
  sudo -u postgres pg_dumpall > /drives/wd10/immich/backups/immich-pre-vchord-$(date +%F).sql
```

(Or rely on `services.postgresqlBackup` which writes to
`/drives/wd10/immich/var/lib/backups/postgres` — verify a recent dump exists
there first.)

Also snapshot the postgres data dir if possible:

```sh
sudo systemctl stop container@immich
sudo cp -a /drives/wd10/immich/var/lib/postgres \
          /drives/wd10/immich/var/lib/postgres.pre-vchord
sudo systemctl start container@immich
```

### Option A: Wipe smart-search index (simplest, slow re-index)

Easiest, loses CLIP embeddings — immich will regenerate them in the
background (hours to days depending on library size; uses GPU/CPU on the
host).

1. With the old (pgvecto-rs) stack still running:
   ```sh
   sudo nixos-container run immich -- sudo -u postgres psql -d immich -c \
     "DROP EXTENSION IF EXISTS vectors CASCADE;"
   ```
   This will drop the `smart_search.embedding` column and similar — that's
   expected.
2. Bump `flake.lock` (`nix flake update immich-nixpkgs`) and apply the code
   change above.
3. `nh os switch` — the new module's init SQL will create `vchord` and
   immich will start with empty embeddings.
4. In the immich web UI, run the "Smart Search" job under Administration →
   Jobs → All to re-embed everything.

### Option B: In-place migration (preserve embeddings)

Per the upstream guide, while still on pgvecto-rs:

1. Install vectorchord alongside pgvecto-rs (requires a transitional
   postgres with both extensions). On NixOS this means a one-shot
   `services.postgresql.extensions = ps: [ ps.pgvecto-rs ps.vectorchord ];`
   override and `shared_preload_libraries = [ "vectors.so" "vchord.so" ]`.
2. In psql, follow vectorchord's `pgvecto-rs → vchord` migration SQL
   (creates new columns, copies vectors, swaps indexes).
3. Drop pgvecto-rs.
4. Then bump the lock and apply the regular code change above.

This is more work and more risk. Only worth it if re-embedding the whole
library would actually be painful. For a personal-scale library, Option A
is usually fine.

## Sequenced execution plan (Option A)

1. `cd hosts/h001 && git status` — confirm clean.
2. Verify recent postgres backup exists in
   `/drives/wd10/immich/var/lib/backups/postgres`.
3. Take a fresh `pg_dumpall` (Step 0 above).
4. Drop the `vectors` extension inside the container (Option A step 1).
5. Apply the immich.nix edit described in "Required code change in this
   repo".
6. `nix flake update immich-nixpkgs` (in `hosts/h001`).
7. `nh os switch`.
8. Watch `journalctl -u container@immich -f` and
   `nixos-container run immich -- journalctl -u immich-server -f`.
9. Open immich UI, confirm browse/upload work.
10. Trigger Smart Search re-index job.
11. After a successful day or two, delete
    `/drives/wd10/immich/var/lib/postgres.pre-vchord`.

## Rollback

If anything goes wrong before step 11:

1. `nh os switch` to the previous generation (or `nixos-rebuild switch
   --rollback`).
2. `git checkout` the previous `flake.lock` and `containers/immich.nix`.
3. Stop the container, restore the postgres data dir from
   `postgres.pre-vchord`, restart.

## Open questions / TODO before executing

- [ ] Confirm the `services.postgresqlBackup` dumps in
  `/drives/wd10/immich/var/lib/backups/postgres` are recent and complete
  (they back up per-database with `pg_dump`, not the full cluster).
- [ ] Decide Option A vs Option B based on library size and tolerance for
  re-embedding time.
- [ ] Check whether any *other* host (e.g. anything else pinning
  `nixos-unstable` for immich/postgres) is affected.
- [ ] After upgrade, revisit whether the redundant
  `systemd.services.immich-server.{requires,after}` override should be
  removed.

## Unrelated follow-up spotted while diagnosing

While eval-testing the host I hit a separate error:

```
error: The option `services.shelfmark' does not exist.
Definition values:
- In `…/nixarr/shelfmark'
```

That's coming from the `nixarr` flake input, not from local config. Likely
needs a `nixarr` bump (or a temporary pin) when it's time to upgrade that
input. Track separately from the immich migration.
