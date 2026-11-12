# Data and backup inventory

Observed **2026-11-12**, primarily around 09:40–10:00 CST. This is a dated inventory, not a live dashboard. See [BACKUP-PLAN.md](BACKUP-PLAN.md) for backup design, retention and retirement gates.

Scope: the container data, media disks, migration archives and backup stores discussed during the backup rollout, on h001, h003, h004, h005, joe and lio. This is **not** a complete inventory of every workstation home directory or every fleet host.

## Reading this inventory

- Paths are **host paths** unless a guest path is explicitly given. Runtime placement was read from `fleet containers place`; directory existence alone does not mean a service is installed or running.
- Approximate sizes such as `9.6G` are `du -sh` observations (binary units, allocated space), sometimes rounded from the earlier same-day survey. Exact byte counts are labelled separately. Sizes change and should not be added indiscriminately: nested paths overlap, and hardlinks/compression/history affect storage usage.
- A bind mount, NFS mount or `/persist` backing directory is **not another copy**. A dump beside the live database is also not an independent copy.
- A successful B2 check covers the retention set **at its recorded check time**, not snapshots created afterwards. Policy `offsite=true` alone does not prove a completed copy.
- “No configured fleet backup” does not mean “no other copy exists anywhere.” Personal folders and exported archives may overlap; those overlaps have not been compared.
- File names, directory metadata, declarations, snapshot metadata and backup reports were inspected. Secret contents and private document/database records were not read; encrypted archives were not decrypted. Archive contents inferred from names are marked **[INFERENCE]**.
- This inventory does **not** authorize deletion. Current service backups do not prove equivalence to every historical archive.

## Storage and copy locations

| Host | Path / storage | Role |
|---|---|---|
| h001 | `/srv/containers/` on root ext4, `/dev/nvme0n1p1` (~464 GiB filesystem) | Persistent application state for most containers |
| h001 | `/srv/bulk/` on `/dev/sda`, ext4 (~9 TiB filesystem) | WD media/archive disk; formerly mounted at `/drives/wd10` |
| h001 | `/nfs/h002/nixarr/` from `10.12.14.184:/` | View of **h004's** NFS media, not a local copy; `h002` is a legacy path name |
| h003 | `/srv/containers/` and `/srv/bulk/`, persisted on bcachefs `/dev/nvme0n1p3` (~853 GiB) | Minecraft state and an empty bulk destination; `/persist` is backing on the same disk |
| joe | `/srv/containers/localai/`, persisted on bcachefs root | LocalAI state and model/backend files |
| lio | `/srv/containers/hello-podman/` | Test-container persistent state |
| h004 | `/data/`, bcachefs pool (~50.2 TiB), devices `/dev/sdf:/dev/sdc:/dev/sdb:/dev/sde:/dev/sdd` | NAS media, restic repositories, retained rsync archives |
| h004 | `/scratch/`, bcachefs `/dev/sda` (~637 GiB) | Separate scratch/burn-in disk |
| h005 | `/var/lib/private/fleet-edge*`, `/var/lib/fleet-edge-forwards/` | Fleet authority and metrics, backed by `/persist` on the same bcachefs eMMC |

### Repository naming

For a subject `<name>` with an existing h004 repository:

- Local backup: **h004 `/data/backups/svc-<name>/`**.
- Client endpoint: **`rest:http://100.64.0.17:8000/svc-<name>/`**.
- Replacement offsite repository, when enabled and copied: **B2 bucket `belljm-LoiuasdV3-system-backups`, prefix `svc-<name>/`**, through `s3:https://s3.us-west-002.backblazeb2.com`.
- h004 `/data/backups/` occupied about **511G** at this survey. Repository usage includes retained history; it is not comparable directly to live directory size as a completeness test.

**Legacy B2** below means the repository accessed by **`restic-h001` on h001**, not a `svc-*` repository. The plan calls it `7f023d4a`, but that label is **not a verified object prefix**. Historical evidence mentions a legacy `/h001` suffix; the configured URL comes from a secret environment file and was not exposed during this inventory. Verify the actual repository URL/prefix before any deletion; never use the eight-character label as a deletion target.

## Current container data

All rows have a reported h004 snapshot on **2026-11-12**, except LocalAI. “h004” means `/data/backups/svc-<service>/`, using the service name in the first column.

Replacement B2 status codes:

- **A:** successful check early Nov 12, 04:57–04:59 UTC. The subsequent nightly local snapshot is newer.
- **B:** successful check Nov 11, 22:10–22:13 UTC. Newer local snapshots are not certified by that older result.
- **Uploading:** first Immich copy still running; no completed B2 result yet.
- **Off:** `offsite=false`; no replacement B2 completion reported. Only `h001-archives` has an explicit accepted local-only decision in this conversation. Other omissions are unresolved coverage decisions.

| Service | Original host and path | Approx. live size | Source / contents (subpaths relative to service root) | h004 copy | Replacement B2 |
|---|---|---:|---|---|---|
| arr | h001 `/srv/containers/arr/` | 9.6G | `nixarr/` application databases/config/history; `kavita/` library catalogue; `media-integrity/`; `recyclarr/`; `sabnzbd-secrets/`. **Not the media library.** Disabled audiobookshelf state retained under `nixarr/state/audiobookshelf`. | Yes | A |
| atuin | h001 `/srv/containers/atuin/` | 501M | `postgresql/` shell-history sync database and `dumpall.sql` | Yes | A |
| dawarich | h001 `/srv/containers/dawarich/` | 2.1G | `data/` location-history uploads/imports/storage; `postgres/`, `pgdumps/`, `redis/` | Yes | A |
| forgejo | h001 `/srv/containers/forgejo/` | 6.6G | `data/` Git repositories, LFS, avatars, configuration; `postgres/`, `pgdumps/` | Yes | A |
| hello-nixos | h001 `/srv/containers/hello-nixos/` | 8K | `data/`, test persistence | Yes | Off |
| hello-podman | lio `/srv/containers/hello-podman/` | 8K | `data/`, test persistence | Yes | Off |
| immich | h001 `/srv/containers/immich/` | 3.3G | `postgres/`, `pgdumps/`, `dbro/` DB access credential, `mlcache/`; **media is outside this root** | Yes, includes media extra path | Uploading |
| life | h001 `/srv/containers/life/` | 8.9G | `state/` blobs/releases/logical backups; `postgres/`, `pgbackrest/` local database backup repository | Yes | B |
| litellm | h001 `/srv/containers/litellm/` | 22M | `data/` Copilot tokens, configuration and caches | Yes | Off |
| llm-router | h001 `/srv/containers/llm-router/` | 36K | `data/`, including device-login token/state | Yes | Off |
| localai | joe `/srv/containers/localai/` | 98G | `models/` (~83G), `backends/` (~16G), `configuration/`, `data/`, `images/` | **No repository/snapshot reported** | Off |
| minecraft | h003 `/srv/containers/minecraft/` | 5.4G | `srv/` worlds/server/plugin state; `secrets/` forwarding secret; `postgresql/` LuckPerms DB and SQL dump | Yes | Off |
| open-webui | h001 `/srv/containers/open-webui/` | 3.4G | `data/`: chat SQLite DB, uploads, vector DB, model caches | Yes | B |
| opengist | h001 `/srv/containers/opengist/` | 125M | `data/`: SQLite DB, Git repositories, index, keys/sessions | Yes | B |
| paperless | h001 `/srv/containers/paperless/` | 130M | `data/` classifier/index/secret key; `postgres/`, `pgdumps/`; **documents are outside this root** | Yes, includes media and consume extra paths | B; **check predates media addition** |
| puzzles | h001 `/srv/containers/puzzles/` | 664M | `data/`: application databases and `storage/` | Yes | B |
| searx | h001 `/srv/containers/searx/` | 36K | `data/`, principally `secret-key.env` | Yes | Off |
| sec | h001 `/srv/containers/sec/` | 34M | `data/`: encrypted `sec.db` and essential `db.key` | Yes | B |
| trilium | h001 `/srv/containers/trilium/` | 1.6G | `data/`: notes database and application state | Yes | B |
| vaultwarden | h001 `/srv/containers/vaultwarden/` | 47M | `data/` vault database, attachments/key material; `backups/` | Yes | B |
| zitadel | h001 `/srv/containers/zitadel/` | 1.8G | `postgresql/`, `pgdumps/`, `keys/masterkey` | Yes | B |

Most NixOS service roots also contain `nixos/` for persistent UID/GID state. The declarations are in `containers/<service>/service.nix` and the corresponding `flake.nix` binds.

### What a service snapshot actually contains

- Declared persistent state plus declared `backup.extraPaths`; arbitrary bind mounts are not automatically backed up.
- Raw PostgreSQL clusters under `/srv/containers/*/postgres` and `/srv/containers/*/postgresql/[0-9]*` are excluded by default. SQL dumps are the intended restore source. Hooks run for active containers; a stopped service may have only its pre-existing dump.
- SQLite online copies are included from `/var/lib/fleet-backup/staging/<service>/sqlite/<service>/…`; the live DB and sidecars are excluded. Staging on the original host is not another backup tier.
- Dotted roots such as `.moved-*` and `.retired-*`, and uninstalled service data, are skipped by the ordinary nightly scan.
- Life also declares internal pgBackRest/restic backups. Their independent destination and health were not verified here; do not count them as a confirmed extra copy.
- LocalAI's models can include hand-edited YAML and voice packs, not just replaceable downloads. `images/` is generated scratch cleaned after 24h. Joe backup admission is still P7; a policy target alone has not created a backup.

The backup policy also lists `canary`, but h004 reports no repository/snapshot for it. It is a policy entry, not verified stored data.

## h001 bulk disk: live media

| Host path | Contents / guest view | Backup copies and exclusions |
|---|---|---|
| `/srv/bulk/immich/media/` | Immich originals in `upload/`, plus `library/`, `profile/`, `backups/`, thumbnails and transcodes; bound as guest `/var/lib/immich` | h004 `svc-immich`; replacement B2 copy unfinished; legacy B2 host job still covers originals. `thumbs/` (~25G in earlier survey) and `encoded-video/` (~196G) excluded from both jobs. |
| `/srv/bulk/immich/media/backups/` | ~4.1G of Immich's own DB dumps on the same disk | Included in the media backup; not an independent live-host copy |
| `/srv/bulk/immich/media/upload/.immich` | Sentinel proving the expected media tree is present | Included in the snapshot; backup fails when it is absent |
| `/srv/bulk/paperless/media/` | Originals/archived documents and `media.lock`; guest `/var/lib/paperless/media` | h004 `svc-paperless`; legacy B2 host job. New per-subject B2 **media coverage not yet verified**: last successful check predates first media-inclusive snapshot. `documents/thumbnails/` excluded. |
| `/srv/bulk/paperless/consume/` | Incoming document queue; guest `/var/lib/paperless/consume`; may legitimately be empty | Included in h004 `svc-paperless` and legacy B2 host job |

`/srv/bulk/immich/` totals about 642G including generated files; `/srv/bulk/paperless/` about 650M. Immich's service `mlcache/` and Paperless's `data/index/` are also excluded as regenerable.

Verification records:

- First full Immich snapshot `0ef8bfe2` (Nov 11): media file paths matched the live tree exactly, **83,573 files / 452,100,655,023 logical bytes**, excluding thumbnails/transcodes. This was a file-list/size comparison, not a full byte-for-byte restore test.
- Newest local Immich snapshot observed: `f3e6c392` (Nov 12 03:05 CST), roots `/srv/bulk/immich/media`, `/srv/containers/immich`, `/var/lib/fleet-backup/staging/immich`.
- Newest local Paperless snapshot observed: `977b049b` (Nov 12 03:05 CST), roots `/srv/bulk/paperless/consume`, `/srv/bulk/paperless/media`, `/srv/containers/paperless`, `/var/lib/fleet-backup/staging/paperless`.

h003 `/srv/bulk/` is an empty persisted destination, **not a mirror** of h001's media.

## h001 bulk disk: personal and historical files

These paths are **outside configured fleet backup coverage**, including the current legacy h001 job. No additional independent copy was verified. Nested names indicate possible overlap; they do not establish identical or complete duplicates. The user has not authorized removal of these folders.

| Path under `/srv/bulk/` | Approx. size | Observed contents / likely source |
|---|---:|---|
| `lio_backs/` | 818G | Laptop/disk archives; details below |
| `forgejo_bak/` | 91G | 2,636 `.tar.gz.age` files with hash-like names; newest mtime May 21. **[INFERENCE]** older Forgejo backup/export scheme. Not decrypted or matched against current Git repositories. |
| `export/` | 61G | `be_minecraft_stuff.zip`, `buks.zip`, `CaptionSav.tar.gz.age`, `desktop_backup.zip`, `google-drive-11_jan_2023/`, `Takeout/`; provenance/content inferred from names |
| `phone_backups/` | 56G | `2024_12_10.tar.gz`, `2025_01_28.tar.gz`, `2025_02_12.tar.gz`, `android_photos_export_2024_feb_7/`, `nothing_2024_06_20/` |
| `joeb_backup/` | 12G | Personal/project files, CaptionSaver archives, documents, Notion exports, `projects/`, encrypted archives; exact originating machine and duplicates unverified |
| `adguardhome_2025_04_25.tar.gz` | 20M | **[INFERENCE]** old AdGuard export; not compared to h005's live state |
| `randrw.test`, `seqwrite.test` | 4 GiB logical each | Regular files named as disk benchmarks; content/provenance not inspected. No backup declared. |
| `lost+found/` | 16K | ext4 recovery directory, not a backup set |

### Inside `lio_backs/`

| Path | Approx. size | Observed contents |
|---|---:|---|
| `nvme1tb/` | 780G | `backups/` and `gopro/`; **[INFERENCE]** copy of an older disk, not verified as a complete disk image |
| `nvme1tb/backups/` | Included above | `ellas_camera/`, `google_photos/`, `google_takeouts/`, `h001_wd10tb/`, `joe_backup/`, `phone_exports/`, `atuin_from_joe.tar.gz` |
| `backups/` | 38G | `1pass/`, Kindle, SMS/phone, Snapchat and Takeout exports; AdGuard/Home Assistant/Minecraft/Opengist archives, Atuin DB, chat exports and Signal backup. Sensitive contents not inspected. |
| `docs_tmp/` | 440M | Contents not inspected |
| `postcards/` | 181M | Contents not inspected |
| `books/` | 70M | Contents not inspected |

Files called `google_photos`, `phone_exports` or `h001_wd10tb` may overlap Immich or other disk archives. Until compared, neither complete duplication nor uniqueness is established.

## h001 migration tarballs: `h001-archives`

**Originals:** h001 `/home/luser/backups/`. This is a host backup subject, **not a container**.

**Copies:** h004 `/data/backups/svc-h001-archives/`; also existing snapshots in legacy B2. Replacement B2 is deliberately **off**, accepted by the user on Nov 12. P6 only stops future legacy backups; P6b removes the legacy offsite copy. Afterwards h001 originals and h004 backup remain.

The latest h004 snapshot observed, `de94ae2d`, and the live directory both contain **30 regular files / 50,601,665,568 logical bytes** (~47.1 GiB). This corrects the earlier count of 31. No archive was unpacked for this inventory.

All filenames below are relative to `/home/luser/backups/`:

| Source | Files | Meaning / other data sources |
|---|---|---|
| arr | `arr-h001-2026-10-12T1654.tar.zst` | Migration-time container export; current arr state separately backed up |
| atuin | `atuin-h001-2026-10-12T2312.tar.zst` | Migration-time export; current Atuin state separately backed up |
| dawarich | `dawarich-h001-2026-10-13T1019.tar.zst`; `dawarich-premigration-2026-10-13.tar.gz` | Export and pre-migration state; current service separately backed up |
| forgejo | `forgejo-h001-2026-10-13T1018.tar.zst`; `forgejo-premigration-2026-10-13.tar.gz` | Export and pre-migration state; not proven equivalent to current repos or `forgejo_bak/` |
| immich | `immich-h001-2026-10-13T1058.tar.zst`; `immich-premigration-2026-10-13.tar.gz` | Migration-time service archives; do **not** assume these include the external photo library |
| life | `life-h001-2026-10-13T0108.tar.zst`; `life-pre-migration-2026-10-13.tar.gz` | Migration-time state; current service separately backed up |
| litellm | `litellm-h001-2026-10-13T0100.tar.zst`; `litellm-pre-migration-2026-10-13.tar.gz` | Migration-time state; current service has h004 backup, replacement B2 off |
| open-webui | `open-webui-h001-2026-10-13T0100.tar.zst`; `open-webui-pre-migration-2026-10-13.tar.gz` | Historical chats/application state; current service separately backed up |
| paperless | `paperless-h001-2026-10-13T1058.tar.zst`; `paperless-premigration-2026-10-13.tar.gz` | Service archives; external document coverage must not be assumed from filename |
| puzzles | `puzzles-h001-2026-10-13T0100.tar.zst`; `puzzles-pre-migration-2026-10-13.tar.gz` | Migration-time state; current service separately backed up |
| searx | `searx-h001-2026-10-13T0034.tar.zst`; `searx-pre-migration-2026-10-13.tar.gz` | Migration-time configuration/state; replacement B2 off |
| trilium | `trilium-h001-2026-10-13T0033.tar.zst`; `trilium-pre-migration-2026-10-13.tar.gz` | Historical notes state; current service separately backed up |
| vaultwarden | `vaultwarden-h001-2026-10-12T2347.tar.zst`; `vaultwarden-pre-migration-2026-10-12.tar.gz` | Historical vault state; current service separately backed up |
| retired services | `beszel-premigration-2026-10-13.tar.gz`; `etebase-final-2026-10-13.tar.gz`; `matrix-final-2026-10-13.tar.gz`; `host-postgresql-final-2026-10-14.tar.gz` | Historical service/database archives, not automatically replaced by current applications. Older Etebase/PostgreSQL and Beszel data also appear in legacy B2 history; equivalence unverified. |
| h003 Minecraft | `minecraft-h003-2026-10-15T2001.tar.zst` | Old world/server export; current world on h003 and in h004 `svc-minecraft` is not the same historical point |
| h003 host state | `h003-state-2026-10-15.tar.zst` | Historical migration record says old home files, router state, SSH/machine/tailnet identity, shell history and locally unpushed work; not just Minecraft. See `hosts/h005/readme.md`, Phase 6. |

Size grouping: 24 current-service migration files = **37.69 GiB**; four retired-service finals = **87.14 MiB**; two h003 archives = **9.35 GiB**. These groups total the 30 files above.

Deleting live tarballs does **not** remove retained restic snapshots or immediately shrink a future B2 copy. Retention sets, not just the newest snapshot, determine what is copied.

## Retired roots and additional rollback copies

These are not automatically covered just because they sit near live service data.

| Host and path | Size / contents | Verified copies elsewhere / qualification |
|---|---|---|
| h001 `/srv/containers/beszel.retired-2026-11-10/` | 4.3M; `data/`, `nixos/`, including `data/beszel_data/` | Skipped by nightly service scan. Legacy B2 has seven Beszel snapshots; imported fleet-edge metrics are a different representation, not a verified full replacement. |
| h001 **and** h005 `/root/beszel-data-snapshot-20261027.db` | 978,944 bytes each; historical Beszel DB snapshot | These two files have matching SHA-256 `e9ac0fc6b88b753688a3c8def52bd601d267c34baa8ccac67ec3410c8475b62e`. Neither `/root` path is in the fleet-edge subject. |
| h001 `/root/retired-2026-10-22-zitadel-sec.tar.zst` | 189,675,410 bytes | Documented archive of pre-cutover `/var/lib/zitadel` and `/var/lib/secrets_manager`, whose old directories are now absent. No current subject includes this `/root` archive. Current sec/Zitadel backups are later state, not a verified identical copy. |
| h001 `/root/atuin-h001-2026-10-12T2310.tar.zst` | 258,598,542 bytes | Separate earlier export than the `2312` file under `/home/luser/backups`; not compared, not in `h001-archives` |
| h001 `/root/opengist-h001-2026-10-12T1726.tar.zst` | 10,263,879 bytes | Historical export outside `h001-archives`; current Opengist separately backed up |
| h001 `/root/acme-retired-2026-10-21/`, `/root/vhost-backup-tls/` | 380K / 60K | **[INFERENCE]** retired TLS/config rollback data. Contents not inspected; no current backup declared for these paths. |
| h001 `/srv/containers/hello-nixos.moved-2026-10-28/` | 8K | Retained test service data; skipped by nightly scan |
| h003 `/srv/containers/hello-nixos.moved-2026-11-10/` | 0 allocated | Retained test service directory; skipped by nightly scan |
| lio `/srv/containers/hello-nixos.moved-2026-10-28/` | 8K | Retained test service directory; skipped by nightly scan |
| h001 `/drives/wd10/` | 52K of directory skeletons | Contains `dawarich/`, `immich/media/`, `paperless/{media,consume}` skeletons, not the mounted media disk. It is not literally one empty directory. |
| h001 `/var/lib/nixos-containers/openwebui/`, `openwebui.bak/` | 12K each | Observed only `var/empty` directory skeletons, not current Open WebUI data |
| h001 `/var/lib/postgresql/` | 39M | Old host PostgreSQL state; host PostgreSQL observed inactive. Relationship to final SQL archive not verified. |
| h001 `/var/lib/private/openbao/`, `/var/lib/openbao-secrets/` | 912K / 72K | Old host state; OpenBao observed inactive. Sensitive contents not read; no replacement equivalence established. |
| h001 `/var/lib/private/bifrost/` | 27M | Application state; use and independent copies not established |

Offline sec/Zitadel recovery keys/data copies are mentioned inconsistently in existing documents. Their current availability and restoreability were **not verified** by this survey; do not count a documented keys-only kit as a verified full data backup.

## h004 NAS data and older host archives

| Path | Approx. size | Source / contents | Copies elsewhere |
|---|---:|---|---|
| `/data/nixarr/` | 13T | NAS media, under `media/{library,torrents,usenet}`. Configured library categories include movies, shows, music, books, audiobooks and podcasts. | NFS view on h001 at `/nfs/h002/nixarr`, also bound into arr at that legacy path. **Not a second copy and not in `svc-arr`.** No independent fleet backup declared. |
| `/data/pinchflat/` | 0 allocated | Retained media root; no populated content observed | No independent copy verified |
| `/data/rsync-archive/l001/` | 316K | Dated June 24–25, 2026 rsync trees and `latest`; historical headscale state | No independent copy verified; not part of `/data/backups` restic subjects |
| `/data/rsync-archive/o001/` | 549M | Dated June 25, 2026 trees, `test_235830/`, `latest`; old `var/` and identity files | No independent copy verified; not a current service backup |
| `/scratch/wd-burnin/`, `/scratch/wd-burnin.aborted-1/`, `/scratch/wd-burnin.sh` | 11M / 44K for the directories | **[INFERENCE]** disk burn-in artifacts, not application backups | No independent copy verified |

The rsync directories were moved out of `/data/backups` when it became the restic target. `latest` is an archive pointer, not a new backup tier. The pool's filesystem redundancy also does not protect against logical deletion or a shared-site loss.

Backup operating state, separate from the repository data:

- `/var/lib/fleet-backup-target/`: policy reply, `stats.json`, `b2-stats.json`, `offsite-b2.json`, clear bookkeeping and lock.
- `/var/lib/fleet-backup-target-keys/`: applied revisions, REST logins and `repo-keys/svc-<subject>` credentials. Secret contents not included here.
- `/var/cache/fleet-backup-target/`: restic cache, not another backup copy.

## h005 fleet-edge and host state

The **`fleet-edge` host subject** has h004 `/data/backups/svc-fleet-edge/` and a successful replacement B2 copy checked **2026-11-12 04:58 UTC**. A newer local snapshot exists. Its source directories are:

| Host path | Contents | Backup handling |
|---|---|---|
| `/var/lib/private/fleet-edge-overrides/` (~672K) | `placements.json`, `state.json`, placement/exposure audits; `backup.json`, `backup-targets.json`, `backup-audit.log`, **`backup-credentials.json`** | Included. Credential contents not read; treat archives of this directory as sensitive. |
| `/var/lib/fleet-edge-forwards/` | `forwards.json`, runtime WAN-forward state | Included |
| `/var/lib/private/fleet-edge/` (~246M) | Live `metrics.db`; static `metrics.db.pre-beszel-import` | Pre-import DB included. Live DB and its WAL/SHM excluded in favor of the online copy below. |
| `/var/backup/fleet-edge/metrics-online.db` | SQLite online backup created by the pre-hook | Included in snapshot, then deleted by post-hook. An empty staging directory between runs is expected. |

The following are persistent but **outside** the `fleet-edge` backup subject; no additional h005 subject was found for them:

- `/var/lib/private/AdGuardHome/` (~1.5G): DNS statistics, sessions and query logs; configuration is declarative. Historical archives elsewhere are not a verified current copy.
- `/var/lib/dnsmasq/`: DHCP leases; `/var/lib/dhcpcd/`: DHCP client state.
- `/var/lib/acme/`: certificate/account state.
- `/var/lib/h005-isp-speedtest/`: Ookla acceptance/settings (0 allocated observed), **not** a persistent measurement archive.
- `/var/lib/secrets_manager_hydrated/`, `/root/.ssh/` and shared host/user identity state: not covered by this subject. Secrets are normally fetched or provisioned; that does not prove an independent recoverable copy of all identity files.

These directories' `/persist` backing is on the same eMMC. The two root-level Beszel snapshots are described in the retired-data table, not included by this subject.

## Legacy B2: what would disappear on retirement

The live metadata query returned **216 retained snapshots**. This is a separate repository from the replacement `svc-*` repositories. No deletion is implied by listing it here.

| Legacy snapshot group | Observed history | Replacement / risk |
|---|---|---|
| `fleet,svc:<service>` for arr, atuin, dawarich, forgejo, immich, life, litellm, open-webui, opengist, paperless, puzzles, searx, sec, trilium, vaultwarden, zitadel | 11 each, Oct 22–Nov 10 | Current local repos exist; replacement B2 varies by service table. These are historical restore points, not proof of identical replacement history. |
| `fleet,svc:hello-nixos` | 11, Oct 22–Nov 10 | h004 copy exists; replacement B2 off |
| `fleet,svc:hello-podman` | 9, Oct 22–Nov 5 | h004 copy exists; replacement B2 off |
| `fleet,svc:llm-router` | 1, Nov 10 | h004 copy exists; replacement B2 off |
| `fleet,svc:beszel` | 7, Oct 22–27 | Retired local tree and DB export remain; imported fleet-edge metrics are not equivalent full service snapshots |
| `h001` | 12, Oct 2–Nov 12 | Host/media/archive history; roots changed over time, below |

Important older `h001` snapshots contain **more than photo/document history**:

- `8fd69acf` (Oct 2): `/drives/wd10/dawarich`, `/drives/wd10/immich/media`, `/drives/wd10/paperless`, `/var/lib/etebase-server`, old Immich/Paperless PostgreSQL backup paths, `/var/lib/paperless/data`, `/var/lib/restic-staging`.
- `b7108bea` (Oct 18): old media paths, `/home/luser/backups`, **`/srv/containers`**, `/var/lib/restic-staging`.
- Later retained snapshots through Nov 11: old media paths and `/home/luser/backups`.
- `39145da2` (Nov 12): `/home/luser/backups`, `/srv/bulk/immich/media`, `/srv/bulk/paperless`.

The legacy host job is still active as a scheduled backup path. **P6 stops future writes, not existing B2 data. P6b deletes the legacy offsite history.** After that, archives retain h001 originals plus the h004 backup by the user's local-only decision. The same decision has **not** been recorded for litellm, llm-router, searx or hello-*; their replacement offsite coverage must be settled before claiming legacy coverage is redundant. Minecraft is also currently local-only, but has no `svc:minecraft` group in this legacy repository.

## Verification and maintenance

This inventory was grounded in:

- Live placement registry, directory/file metadata and filesystem mounts on the listed hosts.
- h004 `policy.json`, `stats.json`, `offsite-b2.json`, `b2-stats.json`; local stats at about **08:50 CST** and policy refreshed at about **09:34 CST**. Last completion file update was **Nov 11 22:58 CST** while the pusher was still handling Immich.
- Live `fleet-restic` snapshot roots and file listings for Immich, Paperless, fleet-edge and h001-archives; `restic-h001 snapshots --json` for legacy history.
- Service `service.nix` / `flake.nix` declarations; [host backup defaults](host-module.nix); [backup client](../flakes/fleet-agent/backup/client.nix); [h001 host subjects](../hosts/h001/floating-containers.nix); [legacy h001 job](../hosts/h001/mods/restic-backup.nix); [h005 subject](../hosts/h005/fleet-edge.nix); [h004 target/pusher](../hosts/h004/flake.nix).

To update coverage, read the policy and completion files together, preserving each subject's `checkedAt`; compare the required snapshot IDs to what was copied. `restic snapshots --latest 1` may return one result **per path group**; sort snapshot metadata by time when a single newest snapshot is needed. Repo disk usage and process disk reads do not prove completeness or upload progress. B2 data-pack listings can measure transferred storage, but a completed retention-set check and restore verification remain separate requirements.

Before pruning a historical item, identify its originating data, compare any claimed replacement, and keep deletion approval separate from this inventory. Do not clear retained snapshots merely to make an upload estimate smaller.
