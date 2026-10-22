# sec + zitadel cutover (h001, in place)

Done on h001 on 2026-10-17; kept as the recipe for a re-run or a move.

`containers/zitadel` and `containers/sec` replace h001's old
`containers/zitadel.nix` nspawn container and `mods/sec.nix` unit. The
host-side removal is in the same change, so **deploying the h001 config and
the containers is one window.** Agents keep their hydrated cache, so a short
outage is harmless. Don't delete the old data until both containers work.

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
6. Run restic once (`systemctl start restic-backups-h001`). Check that the
   zitadel hook ran and that `staging/sqlite/sec/data/sec.db` exists.
7. **Done 2026-10-22.** Archived `/var/lib/zitadel` and
   `/var/lib/secrets_manager` to
   `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001, then deleted them.

**Rollback** (order matters):
1. `cnt destroy sec`, then `cnt destroy zitadel`. Do not pass `--purge`.
   `destroy` removes the extra-container units, the nginx snippets and the
   port files, and keeps `/srv/containers/<svc>`. Don't use `cnt stop` here.
   It only disables the unit and leaves its nginx snippet behind, so that
   snippet would clash with the old host vhosts.
2. Then switch h001 to the previous generation
   (`nixos-rebuild switch --rollback`, or the pre-cutover commit). If you
   switch first and stop afterwards, you also stop the restored old
   `container@zitadel`, because it has the same unit name.

The old dirs (`/var/lib/zitadel`, `/var/lib/secrets_manager`) were archived
to `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001 and deleted on
2026-10-22 (step 7 above). `secrets_manager_hydrated` is unrelated and was
not touched.
