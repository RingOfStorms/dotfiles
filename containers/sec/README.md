# sec + zitadel recovery and cutover history

The in-place cutover below completed on h001 on 2026-10-17. It is a historical
recipe for recovering the old layout, not the current way to move these
services; use [`fleet containers move`](../README.md#moving-a-service-to-another-host)
for an ordinary move and the break-glass instructions below for a cold restore.

`containers/zitadel` and `containers/sec` replaced h001's old
`containers/zitadel.nix` nspawn container and `mods/sec.nix` unit. For a re-run
of that historical cutover, deploying the host config and containers is one
window. Agents keep their hydrated cache, so a short outage is harmless.
Don't delete old data until both containers work.

Steps marked 🔑 move secret material. Copy it with `cp -a`/`rsync` only;
never print it.

1. Make sure a recent restic snapshot exists, and that the break-glass kit
   (db.key, masterkey) is at hand.
2. On h001, stop the old units. Then take a final dump of the old cluster
   while it is still runnable:
   ```
   nixos-container run zitadel -- systemctl start postgresqlBackup.service
   nixos-container stop zitadel
   systemctl stop sec
   ```
3. 🔑 Copy the data into persist. The postgres cluster is owned by 71:71
   (same uid in the guest). Persist is idmapped, so host uids equal guest
   uids:
   ```
   install -d /srv/containers/zitadel/{postgresql,pgdumps,keys,nixos} /srv/containers/sec/{data,nixos}
   rsync -aHAX /var/lib/zitadel/postgres/ /srv/containers/zitadel/postgresql/17/
   rm -f /srv/containers/zitadel/postgresql/17/postgresql.conf /srv/containers/zitadel/postgresql/17/postmaster.pid
   cp -a /var/lib/zitadel/backups/postgres/. /srv/containers/zitadel/pgdumps/
   cp -a /var/lib/zitadel/masterkey /srv/containers/zitadel/keys/masterkey   # 0444 root, keep as is
   sqlite3 /var/lib/secrets_manager/sec.db ".backup '/srv/containers/sec/data/sec.db'"
   cp -a /var/lib/secrets_manager/db.key /srv/containers/sec/data/db.key     # 0400 root
   chmod 700 /srv/containers/sec/data
   ```
4. Switch h001 to the new config (it drops the old container and unit, and
   NAT for `ve-*`). Then deploy the containers, zitadel first. The default
   repo is forgejo, which needs no SSO; `CONTAINERS_REPO=git+file://…` is
   the fallback.
   ```
   cnt deploy zitadel && cnt deploy sec
   ```
5. Check:
   - `curl -s https://sso.joshuabell.xyz/.well-known/openid-configuration`
   - log in to secrets.joshuabell.xyz/ui
   - `systemctl restart sec-agent` on one host, then on another host
   - log in via life, open-webui, trilium
6. With the current backup client, run `systemctl start fleet-backup-svc@zitadel`
   and `systemctl start fleet-backup-svc@sec`. Check that the Zitadel dump hook
   ran, then run `sudo fleet containers restore-check zitadel` and
   `sudo fleet containers restore-check sec`. Sec's SQLite online copy is
   under `/var/lib/fleet-backup/staging/sec/sqlite/sec/data/sec.db`; a staging
   file on the live host is not an independent backup.
7. **Done 2026-10-22.** Archived `/var/lib/zitadel` and
   `/var/lib/secrets_manager` to
   `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001, then deleted them.

**Rollback** (order matters):
1. `cnt destroy sec`, then `cnt destroy zitadel`. Do not pass `--purge`.
   `destroy` removes the extra-container units, the nginx snippets and the
   port files, and keeps `/srv/containers/<svc>`. Don't use `cnt stop` here.
   It only disables the unit and leaves its nginx snippet behind, so that
   snippet would clash with the old host vhosts.
2. Then switch h001 to the pre-cutover generation or commit. A generic
   `nixos-rebuild switch --rollback` only selects the previous generation;
   it does not necessarily select that historical configuration. If you
   switch first and stop afterwards, you also stop the restored old
   `container@zitadel`, because it has the same unit name. Restore the
   archived old directories before starting the old services; they no
   longer exist in the live layout.

The old dirs (`/var/lib/zitadel`, `/var/lib/secrets_manager`) were archived
to `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001 and deleted on
2026-10-22 (step 7 above). `secrets_manager_hydrated` is unrelated and was
not touched.

## Break-glass kit and cold restore

Keep recovery material **outside the fleet**, in the password manager. The
current per-subject architecture requires:

- The fleet-edge backup credential export: one `RESTIC_PASSWORD` per subject
  (the same password for h004 and B2), plus its REST login for h004 access.
  h005 generates these credentials; using **Export all** in `/backup/` is not
  complete until the export has been saved outside h005. Its export banner
  tracks newly generated passwords, not proof that a password-manager copy
  has actually been stored. Current export completion is not confirmed here.
- Each pusher's bucket URL and B2 application key. The user confirmed the
  old `restic_h001_env` and new `restic_b2_h004` entries were saved to the
  password manager on 2026-11-13; that does **not** include newly generated
  per-subject restic passwords. h004's new key is scoped to `svc-`, not the
  legacy repository. Preserve the legacy repository's actual URL, password
  and restricted recovery key until P6b deletion. `7f023d4a` is a repository
  label, **not a verified B2 prefix**; identify the actual URL/prefix safely
  before touching legacy objects.
- Sec's encryption key, `/srv/containers/sec/data/db.key`.
- Zitadel's master key, `/srv/containers/zitadel/keys/masterkey` (32 raw
  bytes, stored base64).
- The emergency SSH key `root_fleet_backup`, whose public half is authorized
  for root on every host by the common `hardening.nix`.

Copy or import key material only into root-readable files; do not print it,
put credentials in repository URLs, paste it into chat or commit it. The
current [`fleet-restic`](../README.md#nightly-restic-fleet-backup) wrapper
fetches subject credentials from h005 and only accepts REST repositories;
it is not the B2-only disaster-recovery command. Use plain `restic` with
independently recovered credentials when h005 is unavailable.

Keys are not a data backup. Sec and Zitadel now have separate repositories
on h004 and offsite copies through h004's B2 pusher; their successful B2
retention-set checks were recorded on 2026-11-13. Those records do not prove
that every later snapshot has been copied, or that the current offline kit
can recover the services. Staging SQL/SQLite dumps on the running host are
not an independent copy.

The old backup note recorded an independent sec/Zitadel data export and a
cold-restore test as completed on 2026-10-22; this README previously described
a keys-only kit and a test still to do. Preserve that historical report,
but **current availability and restoreability of the independent export
have not been confirmed**. Locate that export and retain it: it must share
neither the service repositories nor their credentials to provide an
independent recovery path. The pre-cutover
`/root/retired-2026-10-22-zitadel-sec.tar.zst` is separate historical rollback
data on h001, outside current backup subjects; it is not a confirmed
replacement for that off-fleet export.

### Recovering application state

Use the [B2-only recovery commands](../README.md#b2-only-recovery-independent-of-h005h004)
to restore the Sec and Zitadel subject snapshots into separate scratch trees
using the off-fleet passwords. Do not deploy/start applications against
partially restored data or change live placement for a scratch test.

- **Sec:** its live database is excluded. Copy
  `<scratch>/var/lib/fleet-backup/staging/sec/sqlite/sec/data/sec.db` over
  `<scratch>/srv/containers/sec/data/sec.db`, preserving mode/owner, before
  installing recovered state at `/srv/containers/sec/data`. Keep `db.key`
  with it; test `PRAGMA integrity_check` without dumping records.
- **Zitadel:** keep `/srv/containers/zitadel/keys/masterkey` and its dump
  `/srv/containers/zitadel/pgdumps/cnt-dumpall.sql.gz`. The snapshot does not
  hold the raw PostgreSQL 17 cluster. The dump is gzip-compressed
  **`pg_dumpall` SQL**, so import with `psql`, not `pg_restore`. Neither
  `fleet-restic` nor `restore-check` imports it. Prepare a compatible clean
  recovery database with Zitadel stopped, resolving the module's ensured
  `zitadel` role/database versus the dump's role/database creation statements
  before loading. The guest's first-start initialization must not race the
  import. No unattended Zitadel SQL cold-import runbook has been verified;
  the application-level login test remains essential.

An ordinary `cnt move` is different: it restores snapshot files and SQLite
overlays, then copies excluded PostgreSQL clusters from the stopped,
surviving source. A successful move is not proof of SQL recovery from B2
after both the source and h004 are lost.

**Cold-restore acceptance:** restore on a spare host from B2 alone using
password-manager credentials, with h005 unavailable; separately restore
from the independent data export plus the application keys. For each,
verify SQLite integrity and the PostgreSQL dump, then verify a Zitadel
login and a sec-agent secret fetch. A snapshot listing or dump-format check
alone does not satisfy the application-level recovery test. P6 retires the
old shared credential and future writes; P6b deletes its legacy B2 history.
That deletion remains deferred until B2-only recovery and the requested
h001 → h003 restore/move proof, not merely the waived seven-day wait.
