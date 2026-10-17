# sec + zitadel cutover (h001, in place)

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
7. After a week, archive `/var/lib/zitadel` and `/var/lib/secrets_manager`
   to `/home/luser/backups`, then delete them.

**Rollback:** check out the previous h001 config, run
`cnt stop sec; cnt stop zitadel`, and switch. The old dirs are untouched until step 7.
