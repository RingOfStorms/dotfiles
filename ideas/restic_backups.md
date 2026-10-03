# Restic backups: design (h001 primary repo + offsite)

Status: h001 → B2 backup deployed (see checklist below); everything else is design only. File:line refs are relative to the repo root.
Pinned nixpkgs: h001 `b18a4b9` and lio `78e9c78`, both nixos-26.05 (restic 0.18.1, rest-server 0.14.0).

## Status / resume checklist (2026-10-02)

Decision: **h001 backs up directly to Backblaze B2** (S3 endpoint), not via a local repo + `restic copy`. Sections 3–5 below describe the original plan and still apply to lio later.

Done:
- `hosts/h001/mods/restic-backup.nix` deployed; env secret `restic_h001_env_2026-10-01` holds `RESTIC_REPOSITORY=s3:https://<b2-endpoint>/<bucket>/h001`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
- `restic-h001 init` run; first backup started 2026-10-02 18:48 (~2 TB, multi-day upload). Interrupting is safe; re-running resumes (already-uploaded data is skipped).

When the first run finishes, on h001:
1. Confirm success: `systemctl status restic-backups-h001` (exit 0) and the summary at the end of `journalctl -u restic-backups-h001`.
2. `sudo restic-h001 snapshots` -> one snapshot tagged `h001`.
3. `sudo restic-h001 check` (metadata), then `sudo restic-h001 check --read-data-subset=2%` (downloads ~2% from B2; egress free up to 3x stored).
4. Restore test: `sudo restic-h001 restore latest --target /tmp/rt --include /drives/wd10/paperless` (or one immich album dir); open a few files; `zcat` one `*.sql.gz` dump | head. `rm -rf /tmp/rt`.
5. Enable schedule in `restic-backup.nix`: `timerConfig = { OnCalendar = "03:00"; Persistent = true; RandomizedDelaySec = "15m"; };` and update its header comment; deploy. Nightly runs then also `forget --prune` per `pruneOpts`.
6. Offline recovery sheet: B2 bucket + endpoint, key ID/key, `RESTIC_PASSWORD` stored outside sec (Bitwarden + paper). Without it a dead h001 = unreadable backup.
7. Failure notification (section 7): `notify-failure@` ntfy hook on `restic-backups-h001`.
8. Later: lio backup (section 2.1/5.5, Q2), point the `life` container's restic at B2 too (Q6), quarterly restore drill (section 8).

## 0. TL;DR

1. **Repo location:** `/drives/wd10/backups/` on h001. The data drive is mounted at `/drives/wd10` (`hosts/h001/hardware-configuration.nix:40-43`). `restic-server/<client>/` holds repos served over HTTP; `restic-local/h001/` holds h001's own repo, written as root by local path.
2. **Transport:** run `services.restic.server` on h001 in **append-only** mode with **private repos**, bound to the tailnet IP `100.64.0.13` (`hosts/h001/_constants.nix:9`) and protected by an htpasswd file. lio can only add data. Forget/prune runs on h001 locally against the filesystem path.
3. **Offsite:** a nightly `restic copy` from h001 into a second restic repo on a **Hetzner Storage Box** (sftp). The offsite repo gets its own password. Backblaze B2 is the fallback if you want an S3 backend with Object Lock.
4. **Secrets:** add them to `hosts/h001/mods/sec.nix` (server declarations) and to `hosts/<host>/sec-agent.nix` `extraSecrets` (hydration). This follows exactly the existing `life_backup_env_2026-09-30` pattern.
5. **Existing tooling:** the rsync-to-h002 module `flakes/common/nix_modules/backup.nix` should be **retired for h001/lio, not reused**. `ideas/service_backups.md` is superseded by this doc where they overlap. See section 9.
6. **Monitoring:** the fleet has no notifier today. Add a tiny `OnFailure=` ntfy hook (see the open questions) and a weekly restore-drill unit. Beszel can only alert on disk usage.

## 1. Data drive layout proposal (h001 `/drives/wd10`)

Today: `immich/` (`_constants.nix:45`), `dawarich/` (`:58`), `paperless/` (`:91`). The mount is ext4 with no subvolumes.

```
/drives/wd10/
  immich/            # (exists) media/{library,upload,profile,backups,thumbs,encoded-video}
  paperless/         # (exists) media/, consume/
  dawarich/          # (exists) postgres/, backups/, redis/, data/, secrets/
  backups/
    restic-server/   # rest-server dataDir (owner restic:restic, 0700)
      lio/           # one repo per client (privateRepos => path == htpasswd user)
      life/          # optional (Q6)
    restic-local/
      h001/          # h001's own repo, root-owned, local path (not served)
    staging/         # pre-backup dumps (sqlite .backup, penpot pg_dump), rewritten each run
  archive/           # canonical home for consolidated "old copies", read-mostly
    <source>/<yyyy-mm>-<label>/   e.g. archive/old-laptop/2019-12-home/, archive/phone/...
  inbox/             # landing zone for stuff to sort into archive/ or immich
```

Rules:
- Every scattered copy (old drives, h002 dumps, `/var/lib/forgejo.tar.gz` noted at `ideas/service_backups.md:62`) gets moved into `archive/<source>/`, deduplicated (`rmlint`/`jdupes`), and then **backed up once** as part of the h001 repo.
- Photos go into immich (external library or upload) rather than `archive/`, so there is one canonical photo store.
- `backups/` is never itself a backup source, so restic does not back up its own repo.

Note: wd10 is a **single disk** (`/dev/sda`, no RAID). The local repo protects against deletion/ransomware and gives fast restores. The offsite copy is what protects against that disk dying, which is why offsite is not optional.

## 2. What gets backed up

### 2.1 lio (USER TO FILL)

lio's primary user is `josh` (`hosts/lio/_constants.nix:7`). `/home` is on the root nvme (1.8T, 94% used). `/mnt/nvme1tb` is a second disk (`hosts/lio/hardware-configuration.nix`).

```nix
# >>> USER: edit this list. Defaults are a guess. <<<
lioPaths = [
  "/home/josh/Documents"
  "/home/josh/projects"        # code not pushed anywhere; git remotes are NOT a backup of WIP
  "/home/josh/Pictures"        # only what is NOT already in immich
  "/home/josh/Desktop"
  "/home/josh/.ssh"            # private keys (encrypted in repo)
  "/home/josh/.gnupg"
  "/home/josh/.local/share/atuin" # optional; atuin also syncs to h001
  "/home/josh/.config/nixos-config" # also in git; cheap
  # "/mnt/nvme1tb/<something>"
];
lioExclude = [
  "**/.cache" "**/node_modules" "**/target" "**/.direnv" "**/result" "**/result-*"
  "**/.venv" "**/__pycache__" "**/.gradle" "**/build/intermediates" "**/.next" "**/dist"
  "/home/josh/.local/share/Steam" "/home/josh/.steam" "**/SteamLibrary"
  "/home/josh/.local/share/containers"   # podman storage
  "/home/josh/.local/share/Trash"
  "/var/lib/libvirt/images" "**/*.qcow2" "**/*.vdi" "**/*.vmdk" "**/*.iso"
  "/home/josh/.local/share/flatpak" "/home/josh/.var/app/*/cache"
  "/home/josh/Downloads"                # opt-in if you want it
];
# plus extraBackupArgs = [ "--exclude-caches" "--exclude-if-present=.nobackup" "--one-file-system" ]
```

`--exclude-if-present=.nobackup` lets you opt dirs out with `touch .nobackup`, no rebuild needed.

### 2.2 h001

Policy: back up **dumps, not live database directories**, plus all non-DB state. Live PG dirs are excluded. (They would be inconsistent anyway; restic is not atomic across a running postgres.)

| Service | Host paths to INCLUDE | DB / consistency | EXCLUDE |
|---|---|---|---|
| immich | `/drives/wd10/immich/media/{library,upload,profile,backups}`, `/var/lib/immich/backups/postgres` | PG16; `postgresqlBackup` in container (`containers/immich.nix:193`), bind at `:38-43` | `media/thumbs`, `media/encoded-video`, `/var/lib/immich/ml-cache`, `/var/lib/immich/postgres` |
| paperless | `/drives/wd10/paperless/media` (originals+archive), `/drives/wd10/paperless/consume`, `/var/lib/paperless/backups/postgres`, `/var/lib/paperless/data` | PG16; `postgresqlBackup` (`containers/paperless.nix:202`) | `media/documents/thumbnails`, `data/index`, `/var/lib/paperless/postgres` |
| dawarich | `/drives/wd10/dawarich/{data,backups,secrets}` | PG17+PostGIS; `postgresqlBackup` (`containers/dawarich.nix:231`) | `redis`, `postgres` |
| forgejo | `/var/lib/forgejo/{data,backups}` | PG17; `postgresqlBackup` (`containers/forgejo.nix:165`) | `data/indexers`, `data/data/tmp`, `postgres` |
| zitadel | `/var/lib/zitadel/{backups,masterkey}` | PG17; `postgresqlBackup` (`containers/zitadel.nix:196`). **masterkey is critical** (`:31`) | `postgres` |
| matrix | `/var/lib/matrix/{backups,synapse,gmessages,signal,meta-instagram,meta-facebook,whatsapp,discord,telegram}` | PG17; `postgresqlBackup` with explicit DB list (`containers/matrix.nix:519-524`) | `synapse/media_store/{remote_content,remote_thumbnail,url_cache}`, `postgres` |
| atuin | `/var/lib/atuin/backups` | PG17; `postgresqlBackup` (`containers/atuin.nix:147`) | `postgres` |
| vaultwarden | `/var/lib/vaultwarden/{data,backups}` | SQLite; module `backupDir` (`containers/vaultwarden.nix:110`), timer 23:00 | `data/icon_cache`, live `data/db.sqlite3*` (use backups/) |
| life | **already has its own restic + pgBackRest** (`containers/life.nix:214-223`); point its repo at this server (Q6) or include `/var/lib/life/state` | pgBackRest | `/var/lib/life/postgres` |
| penpot (podman) | `/var/lib/penpot/{assets,secret-key.env}` + staged dump | PG15 container, **no dump today** -> prepare: `podman exec penpot-postgres pg_dump -U penpot penpot` (`containers/penpot.nix:256-257`) | `postgres`, `mcp-plugin` |
| opengist (podman) | `/var/lib/opengist` | SQLite, no dump -> prepare: `sqlite3 .backup` to staging | live `opengist.db` |
| sec (secrets mgr) | `/var/lib/secrets_manager` + staged sqlite `.backup` | **master key generated into dataDir** (`mods/sec.nix:39-42`). Losing it loses every secret | live db |
| trilium | staged `.backup` of `/var/lib/trilium/document.db` + rest of dir | SQLite (`_constants.nix:158`) | live db |
| etebase | staged `.backup` of `db.sqlite3`, plus `secret.txt` (`_constants.nix:252`) | SQLite | live db |
| n8n, open-webui, litellm | `/var/lib/private/{n8n,open-webui}` (**DynamicUser**: `/var/lib/<x>` is a symlink, restic would store only the link) | SQLite -> staged `.backup` | litellm: skip (reproducible) |
| nixarr | `/var/lib/nixarr/state` | per-app SQLite; file copy OK (medium value) | `/nfs/h002/**` (media lives on h002), `**/Cache`, `**/transcodes`, `**/MediaCover` |
| kavita | `/var/lib/kavita` | SQLite (optional) | covers cache |
| beszel hub | `/var/lib/beszel-hub` | low value | - |
| acme | `/var/lib/acme` | certs (rate-limit insurance) | - |
| **excluded on purpose** | `/machine-key.json` (re-seeded per host, `hosts/oracle/readme.md:175`), `/var/lib/secrets_manager_hydrated` (re-hydrated by sec-agent), media-integrity cache, searx, ml caches | | |

The host-level `services.postgresqlBackup` in `mods/postgresql.nix:20-22` dumps an empty cluster. That is harmless; include `/var/backup/postgresql` anyway.

Dump timing: the container `postgresqlBackup` timers run at 01:15 (module default `startAt`, `postgresql-backup.nix:84-85`) and vaultwarden's at 23:00. Schedule the h001 restic run at **03:00** so those dumps are fresh. The prepare script also triggers them synchronously, so a missed run is not stale (section 5.2).

## 3. Transport: rest-server (append-only) vs sftp vs rclone

| | rest-server `--append-only --private-repos` | restic `sftp:` over ssh | rclone serve/backend |
|---|---|---|---|
| Compromised lio can delete/encrypt history | **No** (DELETE rejected; can only add) | **Yes** (needs a restricted shell or ssh forced-command to mitigate) | depends; `rclone serve restic --append-only` is equivalent but adds a component |
| Auth | htpasswd per client; private repos lock each user to `/<user>/` | ssh key; nix2nix key is fleet-wide (`hosts/sec-agent.nix:47-58`), so a dedicated key would be needed | rclone config |
| Performance | HTTP, fast, socket-activated | slower on many small packs | similar |
| NixOS module | upstream `services.restic.server` (`restic-rest-server.nix`), heavily sandboxed (`:103-130`) | none needed | none |
| Prune | must run **on h001 locally** against the path (append-only blocks client prune) | client can prune | - |

**Recommendation: rest-server with append-only.** You were right to lean that way. The cost is that forget/prune is centralised on h001. That is simpler anyway: one place, one lock, run while clients are idle.

Caveats:
- Append-only stops deletion, but a client holding the repo password can still **read** everything. Each client gets its **own repo and its own password**: lio cannot read h001's repo and vice versa.
- `restic forget` from a client fails in append-only mode. So the client `pruneOpts = [ ]` (the module then skips unlock/forget, `restic.nix:409-412`).
- Stale client locks can only be removed locally on h001. The prune job runs `unlock` first (module does this, `restic.nix:410`).
- The module's listen assertion forbids a leading `:` (`restic-rest-server.nix:72-78`). Use `"100.64.0.13:8010"`. The socket has `FreeBind = true` (`:139`), so binding before tailscale is up is safe, matching the IPFreeBind pattern in `mods/monitoring_hub.nix:32-38`.
- The tailnet module trusts `tailscale0` in the firewall (`flakes/common/nix_modules/tailnet/default.nix:167`), so no firewall port opening is needed. Do **not** add it to `allowedTCPPorts`.
- Port 8010 is free in `_constants.nix` (8000-8096 audit: 8008, 8080, 8082, 8084-8087, 8090, 8093, 8094, 8096 are used). Add `services.resticServer.port = 8010;`.
- h001 backs up to itself via `rest:http://h001:<pw>@127.0.0.1:8010/h001/`. That needs a second socket listen. Simpler: h001 writes to the **local path** `/drives/wd10/backups/restic/h001` as root. Recommended; append-only does not matter for the host that owns the disk.

## 4. Offsite

Candidates (prices checked 2026-10, ex VAT):
- **Hetzner Storage Box** (sftp/rclone/borg; snapshots on the box side): BX11 1 TB about EUR 3.20/mo, BX21 5 TB about EUR 11-13/mo (Hetzner raised prices in Apr 2026; confirm on hetzner.com/storage/storage-box). No egress fees. Server-side snapshots give ransomware protection independent of restic credentials.
- **Backblaze B2**: about $6.95/TB/mo, free egress up to 3x stored. Supports Object Lock (immutability) and application keys without delete permission (`deleteFiles` omitted).
- AWS S3 / Wasabi: more expensive or with minimum-retention billing; not recommended.

Method: **`restic copy` (repo -> repo) over `rclone sync` of the repo dir.**
- `restic copy` only copies snapshots that pass restic's read path. A corrupted or ransomed local pack is not blindly mirrored (rclone would happily sync a damaged or emptied repo to offsite, unless `--backup-dir`/versioning is used).
- The offsite repo has an independent password and its own retention, so it can keep longer history.
- Cost: restic copy re-encrypts, so it uses CPU on h001 (negligible here) and needs `--from-repo` access. It cannot be done from the client; it runs on h001.
- `restic init --copy-chunker-params --from-repo ...` keeps dedup efficient between the two repos.

**Recommendation:** Hetzner Storage Box BX11/BX21 via restic's native `sftp:` backend (`sftp:uXXXX@uXXXX.your-storagebox.de:/restic/h001`, port 23), with Storage Box daily snapshots enabled on the box. Choose B2 instead if you want true object-lock immutability.

Sizing (TBD; measure with `du` first, see Q3): photos dominate. Example: immich originals 500 GB + paperless 20 GB + services 50 GB + lio 200 GB, about 0.8 TB after dedup/compression -> BX11 (EUR ~3.20/mo) or B2 about $5.50/mo. If it is over 1 TB: BX21 about EUR 11-13/mo vs B2 about $7/TB/mo.

Alternative to B2/Hetzner: an offsite friend/family box running the same rest-server, $0/mo.

## 5. NixOS implementation

Option names verified against the pinned nixpkgs `nixos/modules/services/backup/restic.nix` and `restic-rest-server.nix`:
- `services.restic.backups.<n>`: `paths`, `exclude`, `extraBackupArgs`, `repository`/`repositoryFile`, `passwordFile`, `environmentFile`, `extraOptions`, `timerConfig` (default daily+Persistent), `pruneOpts`, `checkOpts`, `runCheck`, `backupPrepareCommand`, `backupCleanupCommand`, `initialize`, `user`, `inhibitsSleep`, `createWrapper`.
- Units: `restic-backups-<n>.service/.timer`; wrapper `restic-<n>` in PATH (`restic.nix:513-532`).
- `paths = [ ]` makes a **prune/check-only job** (`restic.nix:406-412`).
- `services.restic.server`: `enable`, `listenAddress`, `dataDir`, `appendOnly`, `htpasswd-file` (**hyphenated**), `privateRepos`, `prometheus`, `extraFlags`. Runs as user `restic`, `ReadWritePaths = [ dataDir ]` (`restic-rest-server.nix:100-121`).

Placement (repo conventions): host-local modules, because h001 consumes `common` by git URL (`hosts/h001/flake.nix:36`). A shared module would need a push+lock bump for every tweak, and only two hosts use this.
- `hosts/h001/mods/restic-server.nix`, `hosts/h001/mods/restic-backup.nix`, `hosts/h001/mods/restic-offsite.nix`, all added to `hosts/h001/mods/default.nix` imports.
- `hosts/lio/restic.nix`, added to `nixosModules` in `hosts/lio/flake.nix:53-155`.
- Optional later: lift the notify-on-failure unit into `flakes/common/nix_modules/notify_failure.nix` once a third host needs it.

Directory layout is as in section 1: the **server-owned** tree (`restic:restic`, `restic-server/`) stays separate from root-written repos (`restic-local/`), so ownership never mixes.

### 5.1 Secrets (reuse the life_backup pattern exactly)

Server declarations, `hosts/h001/mods/sec.nix` inside `secrets = { ... }` (same shape as `:150-154`):

```nix
"machines/high-trust/restic_h001_password_2026-10-01" = {
  fields = [ "value" ];
  description = "restic repo password: h001 local repo (/drives/wd10/backups/restic-local/h001).";
  access = [ { type = "role"; value = "device_high_trust"; } ];
};
"machines/high-trust/restic_lio_password_2026-10-01" = { fields = [ "value" ]; description = "restic repo password: lio repo on h001 rest-server."; access = [ { type = "role"; value = "device_high_trust"; } ]; };
"machines/high-trust/restic_lio_rest_env_2026-10-01" = { fields = [ "value" ]; description = "lio EnvironmentFile: RESTIC_REPOSITORY=rest:http://lio:<pw>@100.64.0.13:8010/lio/"; access = [ { type = "role"; value = "device_high_trust"; } ]; };
"machines/high-trust/restic_server_htpasswd_2026-10-01" = { fields = [ "value" ]; description = "h001 rest-server htpasswd (bcrypt, user lio)."; access = [ { type = "role"; value = "device_high_trust"; } ]; };
"machines/high-trust/restic_offsite_password_2026-10-01" = { fields = [ "value" ]; description = "restic offsite repo password (Storage Box/B2)."; access = [ { type = "role"; value = "device_high_trust"; } ]; };
"machines/high-trust/restic_offsite_ssh_key_2026-10-01" = { fields = [ "value" ]; description = "SSH key for Hetzner Storage Box (or B2 env file)."; access = [ { type = "role"; value = "device_high_trust"; } ]; };
```

Access caveat: `device_high_trust` means every high-trust host can read lio's repo password. That mirrors the existing life secrets. If you want tighter scoping, use `{ type = "sub"; value = "<machine sub>"; }` per host, as the `machines/by-host/*` entries do (`mods/sec.nix:188-200`) (Q7).

Hydration, `hosts/h001/sec-agent.nix` `extraSecrets` (same shape as `life_backup_env_2026-09-30` at `:53-56`):

```nix
restic_h001_password_2026-10-01 = {
  remotePath = "machines/high-trust/restic_h001_password_2026-10-01";
  configChanges.services.restic.backups.h001.passwordFile = "$SECRET_PATH";
};
restic_lio_password_2026-10-01 = {          # h001 needs it to prune lio's repo locally
  remotePath = "machines/high-trust/restic_lio_password_2026-10-01";
  owner = "restic"; group = "restic";
  configChanges.services.restic.backups.prune-lio.passwordFile = "$SECRET_PATH";
};
restic_server_htpasswd_2026-10-01 = {
  remotePath = "machines/high-trust/restic_server_htpasswd_2026-10-01";
  group = "restic"; mode = "0440";
  softDepend = [ "restic-rest-server" ];
  configChanges.services.restic.server.htpasswd-file = "$SECRET_PATH";
};
restic_offsite_password_2026-10-01 = { remotePath = "machines/high-trust/restic_offsite_password_2026-10-01"; };
restic_offsite_ssh_key_2026-10-01  = { remotePath = "machines/high-trust/restic_offsite_ssh_key_2026-10-01"; ensureNewline = true; };
```

lio: `hosts/lio/sec-agent.nix` currently passes no `extraSecrets` (`:3-6`). Add:

```nix
extraSecrets = {
  restic_lio_password_2026-10-01 = {
    remotePath = "machines/high-trust/restic_lio_password_2026-10-01";
    configChanges.services.restic.backups.h001.passwordFile = "$SECRET_PATH";
  };
  restic_lio_rest_env_2026-10-01 = {
    remotePath = "machines/high-trust/restic_lio_rest_env_2026-10-01";
    configChanges.services.restic.backups.h001.environmentFile = "$SECRET_PATH";
  };
};
```

Hydrated files land in `/var/lib/secrets_manager_hydrated/<name>` (`hosts/fleet.nix:30`, `hosts/sec-agent.nix:11`), root:root 0400 by default (`agent.nix` default owner/mode). Hydration happens through `applyChanges` (`hosts/sec-agent.nix:87`), so modules reference no paths directly.

### 5.2 h001: rest-server (`hosts/h001/mods/restic-server.nix`)

```nix
{ constants, ... }:
let c = constants.services.resticServer; # add { port = 8010; dataDir = "/drives/wd10/backups/restic-server"; } to _constants.nix
in {
  services.restic.server = {
    enable = true;
    listenAddress = "${constants.host.overlayIp}:${toString c.port}";
    dataDir = c.dataDir;
    appendOnly = true;
    privateRepos = true;      # user lio can only touch /lio/
    # htpasswd-file set by sec-agent configChanges
  };
  systemd.tmpfiles.rules = [ "d ${c.dataDir} 0700 restic restic -" ];
  # dataDir lives on /drives/wd10: don't start before the mount
  systemd.services.restic-rest-server.unitConfig.RequiresMountsFor = [ c.dataDir ];
}
```

Generate htpasswd once (bcrypt): `htpasswd -B -n lio` (from `apacheHttpd`), then paste it into sec as the value.

### 5.3 h001: own backup + local prune (`hosts/h001/mods/restic-backup.nix`)

```nix
{ pkgs, lib, constants, ... }:
let
  staging = "/drives/wd10/backups/staging";
  localRepo = "/drives/wd10/backups/restic-local/h001";
  serverDir = constants.services.resticServer.dataDir;
  retention = [ "--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12" "--keep-yearly 3" ];
  sqliteSnap = src: name: ''${pkgs.sqlite}/bin/sqlite3 ${src} ".backup '${staging}/${name}.sqlite3'"'';
in {
  systemd.tmpfiles.rules = [ "d ${staging} 0700 root root -" "d /drives/wd10/backups/restic-local 0700 root root -" ];

  services.restic.backups.h001 = {
    repository = localRepo;
    initialize = true;
    # passwordFile via sec-agent configChanges
    timerConfig = { OnCalendar = "03:00"; Persistent = true; RandomizedDelaySec = "15m"; };
    backupPrepareCommand = ''
      set -eu
      PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.podman pkgs.nixos-container ]}:$PATH
      # fresh PG dumps inside each container (unit name from postgresql-backup.nix:190/201)
      for ct in atuin dawarich forgejo immich paperless zitadel; do
        nixos-container run "$ct" -- systemctl start postgresqlBackup.service
      done
      nixos-container run matrix -- sh -c 'systemctl start "postgresqlBackup-*.service"'
      systemctl start backup-vaultwarden.service 2>/dev/null || nixos-container run vaultwarden -- systemctl start backup-vaultwarden.service
      podman exec penpot-postgres pg_dump -U penpot -Fc penpot > ${staging}/penpot.pgdump
      ${sqliteSnap "/var/lib/opengist/opengist.db" "opengist"}
      ${sqliteSnap "/var/lib/secrets_manager/<db-file>" "secrets_manager"}   # confirm filename (Q8)
      ${sqliteSnap "/var/lib/trilium/document.db" "trilium"}
      ${sqliteSnap "/var/lib/etebase-server/db.sqlite3" "etebase"}
      ${sqliteSnap "/var/lib/private/n8n/.n8n/database.sqlite" "n8n"}
      ${sqliteSnap "/var/lib/private/open-webui/webui.db" "openwebui"}
    '';
    paths = [
      staging
      "/drives/wd10/immich/media" "/var/lib/immich/backups"
      "/drives/wd10/paperless" "/var/lib/paperless/backups" "/var/lib/paperless/data"
      "/drives/wd10/dawarich"
      "/var/lib/forgejo" "/var/lib/zitadel" "/var/lib/matrix" "/var/lib/atuin" "/var/lib/vaultwarden"
      "/var/lib/life/state"
      "/var/lib/penpot" "/var/lib/opengist"
      "/var/lib/secrets_manager" "/var/lib/trilium" "/var/lib/etebase-server"
      "/var/lib/private/n8n" "/var/lib/private/open-webui"
      "/var/lib/nixarr/state" "/var/lib/kavita" "/var/lib/beszel-hub" "/var/lib/acme"
      "/var/backup/postgresql"
    ];
    exclude = [
      # live DB clusters (dumps are backed up instead)
      "/var/lib/*/postgres" "/drives/wd10/*/postgres" "/var/lib/life/postgres"
      "/drives/wd10/dawarich/redis"
      # regenerable
      "/drives/wd10/immich/media/thumbs" "/drives/wd10/immich/media/encoded-video"
      "/drives/wd10/paperless/media/documents/thumbnails" "/var/lib/paperless/data/index"
      "/var/lib/forgejo/data/indexers" "/var/lib/forgejo/data/data/tmp"
      "/var/lib/matrix/synapse/media_store/remote_content" "/var/lib/matrix/synapse/media_store/remote_thumbnail" "/var/lib/matrix/synapse/media_store/url_cache"
      "/var/lib/penpot/mcp-plugin" "/var/lib/vaultwarden/data/icon_cache"
      "/var/lib/nixarr/state/**/Cache" "/var/lib/nixarr/state/**/transcodes" "/var/lib/nixarr/state/**/MediaCover"
      # live sqlite files covered by staging snapshots
      "/var/lib/vaultwarden/data/db.sqlite3*" "/var/lib/trilium/document.db*" "/var/lib/etebase-server/db.sqlite3*"
      "/var/lib/opengist/opengist.db*" "/var/lib/private/n8n/.n8n/database.sqlite*" "/var/lib/private/open-webui/webui.db*"
    ];
    extraBackupArgs = [ "--exclude-caches" "--tag" "h001" ];
    pruneOpts = retention;                       # local path => prune allowed
    checkOpts = [ "--read-data-subset=5%" ];      # daily sampled data check
  };
  systemd.services.restic-backups-h001.unitConfig.RequiresMountsFor = [ "/drives/wd10" ];

  # Prune lio's (append-only served) repo locally, after the 03:00 window.
  services.restic.backups.prune-lio = {
    repository = "${serverDir}/lio";
    user = "restic";                       # keep file ownership restic:restic
    paths = [ ];                            # prune/check-only job (restic.nix:406-412)
    pruneOpts = retention;
    checkOpts = [ "--read-data-subset=5%" ];
    timerConfig = { OnCalendar = "Sun 05:00"; Persistent = true; };
  };
}
```

Note: `/drives/wd10/immich/media/backups` (Immich's built-in DB dumps) is included through `media` and is a second, app-consistent DB copy. Keep it.

### 5.4 h001: offsite copy (`hosts/h001/mods/restic-offsite.nix`)

The upstream module has no `copy` mode, so use a small plain unit. It reuses the same timer/notify conventions.

```nix
{ pkgs, constants, ... }:
let
  sd = "/var/lib/secrets_manager_hydrated";
  box = "uXXXXX@uXXXXX.your-storagebox.de";   # Q1
  sftpArgs = "-o sftp.args='-p 23 -i ${sd}/restic_offsite_ssh_key_2026-10-01 -o StrictHostKeyChecking=accept-new'";
  copyOne = src: pwFile: dst: ''
    ${pkgs.restic}/bin/restic ${sftpArgs} -r sftp:${box}:/restic/${dst} \
      --password-file ${sd}/restic_offsite_password_2026-10-01 \
      copy --from-repo ${src} --from-password-file ${pwFile}
  '';
in {
  systemd.services.restic-offsite = {
    after = [ "restic-backups-h001.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.openssh ];
    environment.RESTIC_CACHE_DIR = "/var/cache/restic-offsite";
    serviceConfig = { Type = "oneshot"; CacheDirectory = "restic-offsite"; Nice = 10; IOSchedulingClass = "idle"; };
    unitConfig.RequiresMountsFor = [ "/drives/wd10" ];
    script = ''
      set -eu
      ${copyOne "/drives/wd10/backups/restic-local/h001" "${sd}/restic_h001_password_2026-10-01" "h001"}
      ${copyOne "${constants.services.resticServer.dataDir}/lio" "${sd}/restic_lio_password_2026-10-01" "lio"}
    '';
  };
  systemd.timers.restic-offsite = { wantedBy = [ "timers.target" ]; timerConfig = { OnCalendar = "05:30"; Persistent = true; }; };

  # Offsite retention + check: weekly, longer history than local.
  # Use services.restic.backups.offsite-prune-{h001,lio} with paths = [ ],
  #   repository = "sftp:${box}:/restic/<x>", extraOptions = [ "sftp.args='-p 23 -i ...'" ],
  #   pruneOpts = [ "--keep-daily 7" "--keep-weekly 8" "--keep-monthly 24" "--keep-yearly 5" ],
  #   checkOpts = [ "--read-data-subset=1/12" ] (monthly rotation of 1/12 ~= full read yearly),
  #   timerConfig.OnCalendar = "Sat 06:00".
}
```

One-time init of each offsite repo (copy-friendly chunking):
`restic -r sftp:...:/restic/h001 init --from-repo /drives/wd10/backups/restic-local/h001 --copy-chunker-params`

Ordering: `lio` pushes at 02:00, h001 runs at 03:00 (dumps, backup, prune, check), offsite copy runs at 05:30, and lio prune runs Sun 05:00. Copy and prune of the same repo can collide on locks. restic retries (`--retry-lock 30m` is available since 0.16). Add `"--retry-lock 30m"` to `extraBackupArgs`/copy.

### 5.5 lio (`hosts/lio/restic.nix`)

```nix
{ ... }:
{
  services.restic.backups.h001 = {
    # environmentFile (RESTIC_REPOSITORY=rest:http://lio:<pw>@100.64.0.13:8010/lio/) and
    # passwordFile both via sec-agent configChanges (section 5.1)
    initialize = true;            # init is an append operation; allowed in append-only
    paths = lioPaths;             # section 2.1 (USER TO FILL)
    exclude = lioExclude;
    extraBackupArgs = [ "--exclude-caches" "--exclude-if-present=.nobackup" "--one-file-system" "--tag" "lio" "--retry-lock 30m" ];
    pruneOpts = [ ];              # MUST stay empty: append-only server rejects forget
    inhibitsSleep = true;         # desktop: don't suspend mid-backup
    timerConfig = { OnCalendar = "02:00"; Persistent = true; RandomizedDelaySec = "30m"; };
  };
  # Only run when tailnet is up (otherwise the timer fails noisily)
  systemd.services.restic-backups-h001 = {
    wants = [ "tailscaled-autoconnect.service" ];
    after = [ "tailscaled-autoconnect.service" ];
  };
}
```

`Persistent = true` catches up after the desktop was off at 02:00. `RESTIC_REPOSITORY` must come from the env file, not `repository` (it contains the htpasswd password). The module assertion accepts `environmentFile` alone (`restic.nix:370-373`).

`--retry-lock` is a global restic flag. For backup it can go in `extraBackupArgs`; for the offsite `copy` add it to the command line.

## 6. Schedule, retention, checks

| When | What | Where |
|---|---|---|
| 23:00 | vaultwarden sqlite backup (module timer) | vaultwarden container |
| 01:15 | container `postgresqlBackup` dumps (module default) | containers |
| 02:00 +30m | lio -> rest-server (backup only) | lio |
| 03:00 +15m | h001: prepare dumps -> backup -> forget/prune -> check 5% | h001 local repo |
| 05:00 Sun | prune + check 5% of lio repo (as `restic`) | h001 |
| 05:30 | `restic copy` h001+lio -> offsite | h001 |
| 06:00 Sat | offsite forget/prune + check 1/12 | h001 -> offsite |
| monthly | restore drill (section 8) | h001 |

Retention local: `--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 3`. Offsite: daily 7, weekly 8, monthly 24, yearly 5.
Append-only trap: a compromised client can't delete, but it **can add snapshots with forged `--time`** that crowd the daily/weekly buckets, so a later prune drops real snapshots. Mitigations: add `--keep-within 30d` as a floor, never use `--keep-last`, and have the prune job refuse to run (exit non-zero, which notifies) if a client repo gained more than ~5 snapshots since the last prune.

## 7. Monitoring

Finding: no ntfy/gotify/healthchecks/uptime-kuma/`OnFailure`/sendmail anywhere in `hosts/` or `flakes/` (grep, 2026-10-01). Beszel hub runs on h001 (`mods/monitoring_hub.nix:41-49`). It alerts on host metrics and disk usage only, not on unit failures.

Proposal (Q4):
1. **Failure push:** a template unit `notify-failure@.service` that `curl`s an ntfy topic. Use ntfy.sh with an unguessable topic, or self-host `services.ntfy-sh` on h001 behind nginx/tailnet. Attach `onFailure = [ "notify-failure@%n.service" ];` to `restic-backups-*`, `restic-offsite`, `restic-restore-drill`. Its token/topic goes in sec as another secret.
2. **Dead-man switch** (catches "timer silently never ran"): healthchecks.io free tier, or self-hosted. `ExecStartPost=curl https://hc-ping.com/<uuid>` on success; it alerts if no ping in 26h. This is the only thing that catches a broken timer or a dead h001.
3. **Beszel:** add `/drives/wd10` to h001 `extraFilesystems` (currently `sda__Media`, `hosts/h001/flake.nix:87-90`, already the same disk) and set a disk-usage alert at 85% in the hub UI.
4. Optional: `services.restic.server.prometheus = true` exposes repo metrics, but there is no Prometheus in the fleet. Skip.

## 8. Restore test procedure

Manual (do this after first deploy, then quarterly):
1. `restic-h001 snapshots --latest 3` (wrapper from `createWrapper`) and `restic-h001 check --read-data-subset=10%`.
2. File-level: `restic-h001 restore latest --target /tmp/rt --include /var/lib/trilium`, then compare `sqlite3 /tmp/rt/.../trilium.sqlite3 'PRAGMA integrity_check'`.
3. Postgres: start a throwaway `postgres` (e.g. `nix shell nixpkgs#postgresql_17 -c pg_ctl init -D /tmp/pg && pg_ctl -D /tmp/pg start`), then `zcat all.sql.gz | psql`. Spot-check row counts (immich `assets`, forgejo `repository`).
4. Immich: count restored originals vs `SELECT count(*) FROM asset` from the dump.
5. Offsite: from **lio** (proves a host-independent path), `restic -r sftp:...:/restic/h001 snapshots` using only the offsite password. Restore one small dir.
6. Disaster rehearsal note: the offsite password, Storage Box credentials, and **sec master key** must also exist **outside** sec (paper/Vaultwarden export/USB in a drawer). Otherwise a dead h001 means sec is down, which means no passwords to read the backup that contains sec. This is the single most important bootstrap item (Q5).

Automated: `restic-restore-drill.service` (monthly timer) on h001 restores a random 1% of files from `latest` plus the newest `trilium`/`vaultwarden` dumps into `/drives/wd10/backups/drill/`, runs `sqlite3 PRAGMA integrity_check` and `gzip -t` on the dumps, fails on mismatch (so it triggers `notify-failure@`), and cleans up.

## 9. Existing tooling: replace or reuse?

- `flakes/common/nix_modules/backup.nix` (`ringofstorms.backup`): rsync + `--link-dest` push to `h002:/data/backups` over nix2nix ssh, **unencrypted by design** (`:13-15`). Today it is only imported by `hosts/oracle/o002` and `hosts/oracle/bootstrap` (`flake.nix:91` / `:99`), not by h001 or lio.
  - **Do not reuse it for this.** h002 is not a backup target (may be reformatted), the module has no encryption, no dedup, and no append-only protection (the nix2nix key can `rm -rf` the remote, `:193`). Wrapping restic inside it would mean a second convention next to upstream `services.restic`.
  - Leave it in place for o002 for now. Follow-up decision (Q9): migrate o002 to `services.restic.backups` against h001's rest-server (it's on the tailnet) and delete `backup.nix`. That is the clean cutover; one backup convention fleet-wide.
- `ideas/service_backups.md`: older plan (topology into h002, mentions OpenBao `/bao-keys`, which is gone now that `sec` replaced it, `mods/sec.nix:1`). Its path inventory is useful but stale. **Supersede it** with this doc. Add a one-line pointer at its top, or delete it once this is implemented.
- `life` container has its own restic + pgBackRest pipeline (`containers/life.nix:214-223`, secret `life_backup_env_2026-09-30`). Reuse it by pointing its `RESTIC_REPOSITORY` at the h001 rest-server (`/life/` user) so it inherits prune/offsite, rather than duplicating (Q6).

## 10. Rollout order

1. Measure sizes (`du -sh` for section 2.2 paths, lio paths). Pick the offsite plan.
2. Create secrets in the sec UI (values), then add declarations + `extraSecrets`.
3. Deploy h001 `restic-server` + `restic-backup`. Run `systemctl start restic-backups-h001` manually and watch the first run (multi-hour for immich).
4. Deploy lio. Run the first backup manually.
5. Init offsite repos; first `restic copy` (seeding 0.5-1 TB over home upload may take days; it is resumable).
6. Notifications + dead-man switch, then the restore drill.
7. Write offline recovery sheet (Q5).

## 11. Open questions (user decisions)

- **Q1 Offsite provider:** Hetzner Storage Box (recommended, cheapest, box-side snapshots) vs B2 (object lock) vs a friend's box.
- **Q2 lio paths:** confirm/edit the list in section 2.1. Is anything on `/mnt/nvme1tb` important? Include `Downloads`?
- **Q3 Sizes:** actual `du` of immich originals, paperless, matrix synapse media, forgejo, lio set. This decides BX11 vs BX21 and the initial upload time.
- **Q4 Notifications:** ntfy.sh (hosted) or self-host ntfy on h001; healthchecks.io dead-man yes/no.
- **Q5 Offline bootstrap:** where the offsite password, Storage Box key, and sec master key live outside sec (paper/USB/Vaultwarden export).
- **Q6 life:** point life's existing restic at the rest-server, or just back up `/var/lib/life/state` + pgbackrest dir in the h001 job?
- **Q7 Secret scoping:** `device_high_trust` role (matches existing pattern) vs per-host `sub` access for repo passwords.
- **Q8:** exact sqlite filename in `/var/lib/secrets_manager` (staging snapshot). Is there a supported `sec` export command to prefer?
- **Q9:** migrate o002 off `backup.nix` to restic->h001 and delete the rsync module?
- **Q10:** nixarr state, kavita, beszel: include (small, medium value) or skip?

