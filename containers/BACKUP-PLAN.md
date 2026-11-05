# Fleet backups: backup targets, pushers, one repo per subject

Status: **P1 and P2 code written, nothing deployed.** rest-server behaviour was
measured on loopback fixtures (rest-server 0.14.0, restic 0.18.1), not on h004
(Appendix A). Revised 2026-11-04 to the user's decisions (§0 items 7–10); the
2026-11-01 revision is in git.

Target state: fleet hosts push restic snapshots to a **backup target** over the
REST protocol and hold no B2 credential. A target that also holds a B2 key is a
**pusher** and copies repos off site. Which target a service uses, and whether it
also goes to B2, are runtime toggles in the fleet-edge UI.

## 0. Decisions (user, 2026-11-01)

1. Build all of it; this plan is the spec.
2. Two tiers, opted into per host by an ordinary Nix module (not at runtime):
   **target** (receives pushes, rest-server) and **pusher** (a target with a B2 key
   from Nix that copies repos to B2). h004 is both. Per service, at runtime:
   `target` (which target) and `offsite` (also push to B2; only if that target
   is a pusher).
3. h004: move the current `/data/backups` content out; `/data/backups` becomes
   the restic target root (§4).
4. h001's media goes h001 → h004 → B2 like any other service data, declared in
   `service.nix` (`backup.extraPaths`, `backup.hooks`) (§3, §5).
5. fleet-edge state on h005 is backed up as a subject, like a service (§6).
6. joe (low trust) may back up to h004 under conditions (§7).
7. Legacy B2 repo `7f023d4a` stays untouched during the migration. It is
   deleted a few days after the completeness check shows every new per-service
   repo fully copied to B2 (P6b, §9). No 12-month hold.
8. The rest of wd10 (`lio_backs`, `forgejo_bak`, `export`, `phone_backups`,
   `joeb_backup`) is out of scope; the user sorts it manually.
9. fleet-edge `metrics.db` is part of the `fleet-edge` subject (§6).
10. The one-time ~485 GiB media re-upload to B2 is approved (§5, P5).

**Does the tier split simplify the design? Yes, for three reasons.**
- A target needs no B2 key. Phase 1 involves no Backblaze work, and any large
  disk can become a target. The B2 key, copier, B2 prune, B2 stats and B2
  *clear* all live in the pusher module. "Holds a B2 key ⇔ pusher" is a single
  assertion.
- Combined with decision 4, the old special cases go away: the `host-h001`
  media subject; the h004 media job and its NFS-export precondition; the reuse
  of the old repo `7f023d4a` with a tag-scoped prune; the `unassociatedBytes`
  gate; and a B2 key granting two prefixes, which B2 cannot express (one
  `namePrefix` per key). Every subject now has one shape.
- `offsite` reduces to "the resolved target advertises `pusher: true`".

What it does not simplify: one repo per subject, per-subject credentials,
retention run on the target, and the completeness gate. Those come from
isolation and append-only, not from tiering.

## 1. Current state (facts)

- **One fleet-wide key.** `machines/high-trust/restic_h001_env_2026-10-01`
  (`containers/sec/registry.nix:206-215`) holds `RESTIC_REPOSITORY` (an S3 URL
  to B2), `RESTIC_PASSWORD` and `AWS_*`. It is granted to the
  **`device_high_trust` role**, so any high-trust host can hydrate it. h001, lio
  and h003 consume it (`containers.backup.environmentFile`). Any holder can
  `forget --prune` the whole fleet's history. That has happened: h001's run on
  2026-10-22 removed `731895a9` (`svc:puzzles`).
- **Repo `7f023d4a`:** 164 snapshots, 491.7 GiB stored. `--tag fleet`
  (containers) = 31.2 GiB; `--tag h001` (h001 host job) = 484.9 GiB. At
  $6.95/TB/mo that is $3.34/mo.
- **Client prune today:** `containers/host-module.nix` `backupScript` ends with
  `restic forget --prune --tag fleet --group-by tags <pruneOpts>` (7/5/12/3).
  `hosts/h001/mods/restic-backup.nix` prunes `--tag h001` with the same keep-set.
  Both work only because S3 is not append-only.
- **h001 host job** (`hosts/h001/mods/restic-backup.nix`) backs up
  `/drives/wd10/immich/media` (excluding `thumbs` and `encoded-video`),
  `/drives/wd10/paperless` (excluding `media/documents/thumbnails`) and
  `/home/luser/backups`. Measured 2026-11-01: `/drives/wd10/immich` 639G,
  `/drives/wd10/paperless` 650M, `/home/luser/backups` 48G. `/drives/wd10` is a
  local 9.1T ext4 disk in h001 (1.7T used). It is bind-mounted into the
  **immich** and **paperless** containers (`containers/{immich,paperless}/flake.nix`
  `binds`; both declare `requires = [ "wd10" ]`), not into arr. arr's media
  already lives on h004 (`/data/nixarr`, NFS-mounted at `/nfs/h002/nixarr`).
  wd10 also holds about 1.04T that no job backs up: `lio_backs` 818G,
  `forgejo_bak` 91G, `export` 61G, `phone_backups` 56G, `joeb_backup` 12G.
  Out of scope (§0.8).
- **h004** has no restic, no rest-server, no B2 key and no containers module.
  `/data` is bcachefs, 51T with 26T free, replicas=2, `nofail`
  (`hosts/h004/data-pool.nix`). `/data/backups` is subvolume id 2 and holds only
  stale rsync output (§4). `hosts/h004/nfs-data.nix` `ensure-backups-subvolume`
  resets it to `luser:users 0700` on every boot.
- **fleet-edge state on h005** (§6) is not backed up.
- **joe** (`trust = "low"`) is a container host (nvidia, localai) with no backup.

## 2. Model

### 2.1 Tiers (Nix, per host)

All backup code lives in `flakes/fleet-agent/backup/`, imported by
`agent-module.nix`. Every host gets it: h004 and h005 declare `inputs.fleet-agent`,
and container hosts get it through `containers`.

```nix
ringofstorms.backup.target = {           # tier (a): receive pushes
  enable = true;
  dataDir = "/data/backups";             # restic target root (§4)
  requiresMount = "/data";               # RequiresMountsFor + ConditionPathIsMountPoint
};
ringofstorms.backup.pusher.enable = true; # tier (b): implies a B2 key + copier
```

| Module | Emits | Asserts |
|---|---|---|
| `target` | `services.restic.server` (`listenAddress = "8000"`, `dataDir`, `appendOnly`, `privateRepos`, `htpasswd-file = /run/restic-rest-server/htpasswd`), `users.users.restic.createHome = mkForce false` (§4.3), `render-htpasswd` (§2.5), the prune and local-stats units, registration heartbeat, *clear* executor (local scope), and the `:8000` firewall rule | `trust == "high"`; `dataDir` is under `requiresMount`; allow-list non-empty and contains lio |
| `pusher` | copier, B2 prune, B2 stats, completeness record, *clear* executor (b2 scope) | `target.enable`; the host's sec-agent declares `restic_b2_<host>_<date>`; no host without `pusher` declares any `restic_b2_*` key (eval check over `hosts/*`) |
| `client` | `fleet-backup` / `fleet-backup-svc@` / `fleet-restic`, the resolver, stamps | at least one subject source: the containers module or `ringofstorms.backup.subjects` |

A target's root reads every repo it holds, because it needs each repo's password
to prune. Its root is therefore in the same trust tier as the backup data,
which is why targets must be high-trust. A target never runs containers.

### 2.2 Subjects: one repo per subject

A **subject** is the unit of backup, isolation and policy. It is either a
floating service (`containers/*/service.nix`) or a host subject
(`ringofstorms.backup.subjects.<name>`, §3.2). There is one namespace and one
repo per subject: `svc-<name>`, at `rest:http://<target>:8000/svc-<name>/`.

- rest-server `privateRepos` admits a user only on its own path component and
  its children (Appendix A.1), so **repo path = htpasswd user = subject**.
  `svc-sec` cannot reach `svc-secrets` (measured: 401).
- With append-only, a client cannot delete snapshots (403) or remove keys, but it
  can break locks (200), so `--retry-lock` and `cnt move` keep working
  (Appendix A.2).
- Cost: no dedup across subjects; one full first upload per new repo (§2.6).
- Host-subject names are checked at eval time against `lib.allServices` names;
  a collision fails the build.

### 2.3 Runtime policy (fleet-edge)

**Target record** (posted by each target, `POST /api/backup/targets/<id>`, with
the caller's peer IP equal to `declaredBy`, via a heartbeat timer every few
minutes; a record older than about 1 h is *stale* and cannot be selected):

| Field | Example |
|---|---|
| `id`, `url` | `h004`, `rest:http://100.64.0.17:8000/` |
| `pusher` | `true`: only then may a service set `offsite` |
| `presets` | `{short, standard, long}` → `--keep-*` args (below) |
| `stats` | per subject: `localBytes`, `b2Bytes`, `lastBackup`, `lastCopied`, `complete` |
| `enabled` | operator drain switch |

**Policy row** (one per subject, plus a `default` row):

| Field | Values | Rule |
|---|---|---|
| `target` | target id, or `none` (*turn off*) | must be enabled and not stale |
| `offsite` | bool | `PUT` returns 409 unless the target's record has `pusher: true`. If a pusher is later demoted in Nix, its rows show "offsite unavailable"; they are never silently cleared |
| `retentionLocal` | `short`/`standard`/`long` | default `standard` = today's 7/5/12/3 |
| `retentionB2` | same, or `local` (follow) | default `local` |

| Preset | `restic forget` args |
|---|---|
| `short` | `--keep-daily 3 --keep-weekly 2 --keep-monthly 1` |
| `standard` | `--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 3` |
| `long` | `--keep-daily 14 --keep-weekly 8 --keep-monthly 24 --keep-yearly 5` |

Implementation: `flakes/fleet-edge/internal/backup`, alongside `overrides` and
`placements` in the `fleet-edge-overrides` unit (`StateDirectory`
`fleet-edge-overrides`). State: `backup-targets.json` and `backup.json`, 0600,
atomic writes, one mutex, plus `backup-audit.log`. Routes go on h005's `:443`
vhost, proxied like `/api/placements` (`deny 100.64.0.5`, 16k body,
`identityClear`).

Auth uses `internal/authority`. Today `Authenticate` admits only configured
writers (a sub and overlay IP pair), so `internal/backup` builds three
allowlists:
- **writers** (lio, juni, gp3, oren) for `PUT` and *clear*;
- **readers** (every client host) for `GET`;
- **targets** for `POST`, each only for its own record.

Errors:
- 409: `PUT` naming an unknown, disabled or stale target, an unknown preset, or
  `offsite` on a non-pusher.
- 409: a revision conflict.
- 401/403: bad auth.

**UI** (dashboard table, one row per subject): target, B2 checkbox (disabled
when the target is not a pusher), the two presets, local size, B2 size,
estimated $/mo (`b2PricePerTbMonth = 6.95` from Nix), last backup and last
copied, plus two actions:
- **Turn off** writes `target = none`. Nothing is deleted, the target keeps
  pruning under the preset, and the change is reversible.
- **Clear** takes a scope `local|b2|both` and a typed confirmation
  (`clear svc-x b2`). It is audited, and only the target that holds the repo
  executes it, on its next heartbeat; fleet-edge never runs restic. `local`
  deletes the repo, and the next run re-inits it. `b2` deletes the
  subject's B2 prefix and sets `offsite = false` in the same operation.
  `both` does local first, then B2. A clear naming a repo the target does
  not hold, or `b2` on a subject without an offsite repo, returns 409.

Sizes come from the target's stats timer (`restic stats --mode raw-data`,
hourly, 0600 `stats.json`). Stale sizes render with a timestamp, never as 0.

### 2.4 Client

- **Resolve** once per run: `fleet backup-resolve <subject>` makes an
  authenticated `GET /api/backup` with the host's Zitadel machine token
  (reusing `fleet-agent/internal/containers/edgeapi.go`'s client). It yields
  `target`, `url`, and the repo `<url>svc-<name>/`. The answer is cached in
  `/var/lib/fleet-backup/target.json` (0600). If the API is unreachable, the
  cache is used. With no cache the run fails; it never guesses. `none` skips
  the subject and logs it. The client never sees `offsite`.
- **Credentials**: the subject's secret (§2.7) is loaded per subject, so
  `RESTIC_REPOSITORY` is built per subject and never stored in a secret.
- **Stamp** `/var/lib/fleet-containers/backup-last/<svc>` gains `target=` and
  `repo=`. `parseStamp` ignores unknown keys, so old `cnt` still reads it.
- **Client prune deleted** in the same phase in which clients point at a
  target (§8 P3). Against append-only it would print a 403 per snapshot, exit 0,
  and silently stop retention.
- `containers.backup.repository`, `passwordFile` and `pruneOpts` are removed.
  `fleet-restic` takes `-r` (and then does not export its own
  `RESTIC_REPOSITORY`), or resolves `<subject>` from `--subject <name>`.

### 2.5 Target

- `render-htpasswd` is a root oneshot, `before` rest-server, with
  `reloadPropagatedFrom`. For each hydrated subject secret it hashes
  `RESTIC_REST_PASSWORD` with `htpasswd -niB` (password on stdin), checks for a
  `user:$2y$` line, and atomically `mv`s the result to
  `/run/restic-rest-server/htpasswd`. An empty username or password fails the
  unit before the rename, and with no secrets the file is empty. rest-server
  reads htpasswd only at start or on SIGHUP, so add
  `ExecReload = kill -HUP $MAINPID`; rotation is `systemctl reload
  render-htpasswd`. (Measured: a file `ReadOnlyPaths` bind does not pin the
  old inode across `rename(2)`.)
- **Prune** runs per repo, by filesystem path. It loops over
  `${dataDir}/svc-*/` and runs `restic forget --prune --group-by ''
  <preset args>`. `--group-by ''` is required: the default `host,paths`
  grouping split one repo into 4 groups and removed nothing (measured). The
  preset comes from the policy per run. If the policy is unreachable it uses
  the cache; with no cache it uses `long` (the safe direction).
- **Unit user:** prune, stats and *clear* run as `User=restic`, with subject
  passwords passed through `LoadCredential=`. A root process writing into the
  repo would leave root-owned packs and index files that rest-server (uid 291)
  cannot read.
- All target units have `RequiresMountsFor=/data` and
  `ConditionPathIsMountPoint=/data`. `/data` is `nofail`, and without these a
  pool-less boot would accept backups onto the root filesystem.
- Nothing auto-creates repos. `restic init` per subject is an explicit step (§8)
  run as `restic`, with the chunker params copied (§2.6).

### 2.6 Pusher

- **Copier** (timer after prune): for each subject whose resolved `target` is
  this host and `offsite = true`, run `restic copy --from-repo
  ${dataDir}/svc-<name> --from-password-file <pw> -r <B2>/svc-<name>
  --password-file <pw>`. The B2 URL uses the S3 endpoint as today, one repo per
  subject under one bucket. The **same repo password** is used at both ends,
  so a pusher needs no extra per-subject secret, and break-glass is one
  password per subject plus the bucket key. (Earlier revision: separate B2
  passwords. Dropped: the B2 repo holds the same plaintext, and the second
  password added rotation work and no isolation.) If the policy fetch fails,
  the copier copies nothing and `lastCopied` goes stale.
- **B2 prune**: same loop and preset rules, `retentionB2` (or `local`), by URL.
  This is the only deletion done off the target's disk.
- **First copy is a full upload.** An empty destination dedups against nothing,
  even with copied chunker params (measured: 20,005,756 B source → 20,005,811 B
  destination). Later copies are incremental (0 B when nothing changed; about
  the raw size of new data otherwise).
- **Chunker:** each local `svc-*` repo is `init --copy-chunker-params` from the
  old repo (for history dedup), and each B2 repo is init'd from the local one.
  This matters only for the client's next backup deduping against seeded
  history: 2,366 B instead of 20 MB (measured).
- **Completeness record** `offsite-b2.json` (per subject). Expected keys = the
  B2 preset's `forget --dry-run --json --group-by ''` run **on the local
  repo**. Running it on the destination is circular (measured: it missed an
  uncopied snapshot). Match on `(.original // .id)`: copied snapshots get new
  IDs, so raw IDs intersect in 0 (measured, A→B→C). Each match must also agree
  on `time,hostname,paths,tags,tree`. The test is a subset, not equality, and
  `check --read-data-subset` runs on a sample. A shallower `retentionB2` is
  legal; the gate accounts for it.
- **B2 key** `restic_b2_<host>_<date>` (sub: that pusher only) holds a new B2
  application key with `namePrefix = "svc-"` on the bucket. A single prefix now
  suffices because every subject lives under `svc-`. A second pusher gets its
  own key.

### 2.7 Secrets

One key per subject: `machines/backup/restic_<subject>_<date>`. It has a `value`
field and **`sub` grants only**: the hosts the policy places the subject on,
plus every target. It never gets a role grant. Contents (names only):

```
RESTIC_PASSWORD=<repo password, local and B2>
RESTIC_REST_USERNAME=svc-<name>
RESTIC_REST_PASSWORD=<plaintext; targets hash it, never stored hashed here>
```

- A host's key set is exactly the subjects placed on it. A `cnt move` needs the
  grant first (reviewed registry change, then deploy, then move; preflight
  enforces it, §2.9). Never grant "everything a host might run".
- Kill switch for one subject: drop the consumer's sub, deploy `sec`, delete
  the hydrated copy, then `systemctl reload render-htpasswd` on each target.
- `RESTIC_REPOSITORY` must be `rest:http://…` (a bare `http://` parses as a
  local path), with no userinfo: userinfo would be stored in every snapshot.
- **Changing a target** is a UI edit plus a one-time local `restic copy` of the
  repo from the old target to the new one (a full transfer). The old target
  stays readable until its keep-window passes. The B2 repo is keyed by subject,
  so it continues unchanged under the new pusher. The copier's "target is
  myself" filter means two pushers never write the same subject.

### 2.8 Firewall (each target)

```
iifname "tailscale0" ip saddr { <allow-list> } tcp dport 8000 accept
```

The allow-list is `fleetLib.firewallHighTrustIps { exclude = [ "o002" <self> ]; }`
plus the explicit `backup.lowTrustClients` (joe, §7). It is generated once
inside the `target` module. The socket binds all addresses, so this rule is the
whole ACL. The LAN stays closed (h004 `allowedTCPPorts = mkForce [ ]`).
Assertion (shape of `sshGuardAssertion`): the list is non-empty and contains
lio.

### 2.9 `cnt move` and restore

- A move restores the **stamped** repo and snapshot from the final backup:
  `fleet-restic -r <stamped repo> restore <id>` with the subject's credentials.
  `restoreCheck` uses the same pair. It never picks "newest across targets".
- Preflight, before the source stops:
  - the subject resolves to a target (not `none`);
  - the destination holds the subject's secret;
  - it can read the stamped repo (`snapshots <id>`) and lock the destination
    repo;
  - every extra path passes its `onMove` rule (§3.4).
- The SQLite overlay comes from the restored snapshot's staging copy, never the
  destination's live staging directory.
- `cnt restore <svc> --latest` alone queries every enabled target (401 =
  absent) and records which one answered.

## 3. Declaring backup data: `service.nix` and host subjects

### 3.1 `service.nix` schema

```nix
backup = {
  enable = true;                       # false: not a subject (UI: "excluded in service.nix")
  exclude = [ "mlcache" ];             # relative to /srv/containers/<svc>
  hooks = {
    pre  = "pg_dump … > /var/lib/…";   # in-container, before snapshot, only if the unit is active
    post = "rm -f /var/lib/…/dump";    # in-container, after the snapshot (success or failure)
  };
  extraPaths = [
    {
      path = "/drives/wd10/immich/media";
      requires = "wd10";               # a host capability, must be in the service's `requires`
      exclude = [ "thumbs" "encoded-video" ];  # relative to `path`
      mount = "/drives/wd10";          # optional: `findmnt -T <path>` TARGET must equal this
      sentinel = null;                 # optional: absolute file that must exist (e.g. /drives/wd10/.wd10-online)
      onMove = "present";              # "restore" (default) | "present"
    }
  ];
};
```

Clean cutover: the top-level `backupHook` becomes `backup.hooks.pre` in every
`service.nix`, and `lib.nix` throws on `backupHook` ("renamed to
backup.hooks.pre"). The service-specific default excludes in
`host-module.nix` (`immich/mlcache`, `open-webui/data/{hf_home,…}`,
`paperless/data/index`) move into their services' `backup.exclude`. The
generic `*/postgres` excludes stay host-wide.

### 3.2 Host subjects (non-container data)

```nix
ringofstorms.backup.subjects.<name> = {
  paths = [ "/abs/path" … ];   # non-empty
  exclude = [ … ];             # relative to each path
  hooks.pre = "…";             # host shell, as root
  hooks.post = "…";
};
```

These are handled by the same client loop, resolver, stamp format and repo
naming (`svc-<name>`). The client option `stampDir` is set by the containers
module to the existing `/var/lib/fleet-containers/backup-last` and defaults
elsewhere to `/var/lib/fleet-backup/backup-last`.

### 3.3 Validation

**At eval time** (`lib.nix` `normalize`; host subjects in the client module):
each failure throws `containers/<svc>/service.nix: backup: …` and fails the
build.

- Unknown keys in `backup`, `hooks` or any `extraPaths` entry fail.
  `enable = false` combined with any other field fails.
- `path` must be absolute, match `^(/[A-Za-z0-9._@+-]+)+$`, contain no `.` or
  `..` component, and not be `/`.
- `path` must not be under `/srv/containers` (already the subject root), `/nix`,
  `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/etc`, `/var/lib/secrets*` or
  `/var/lib/fleet-backup`. Hydrated secrets are never backed up.
- `requires` ∈ the service's `requires`. Placement then guarantees that the host
  running the service has the capability. A host subject has no `requires`,
  because it is pinned to the host that declares it.
- No overlap: no path may be a prefix of another, within one service or across
  all services and host subjects (a `checkBackupPaths` pass beside
  `checkNetIndexes`). Two repos holding the same data would make restores fight.
- `exclude` patterns must be relative and contain no `..`. `onMove` ∈
  {`restore`, `present`}. Hooks are non-empty strings.
- `mount` and `sentinel` are optional. If set, each must be absolute and
  normalised like `path`. `path` must be equal to or under `mount`, and
  `sentinel` must be under `mount` when both are set. Set at least one for any
  path on a capability disk; without one, an unmounted disk is caught only if
  the path is then missing.

**At run time** (client, per extra path, before the snapshot): the subject fails
with a clear message, and the other subjects still run, if:
- `findmnt -no FSTYPE -T <path>` is `nfs*`, `cifs`/`smb3`, `fuse.sshfs`,
  `autofs` or `9p`. Message: "remote path: back it up on the host that owns
  it".
- the path is missing.
- `mount` is set and `findmnt -no TARGET -T <path>` ≠ `mount`. An unmounted
  `/drives/wd10` resolves to `/`, so it fails here instead of producing an
  empty snapshot that retention would let replace the real data.
- `sentinel` is set and the file does not exist (`[ -f <sentinel> ]`).

**Empty directories are allowed.** A queue such as
`/drives/wd10/paperless/consume` is legitimately empty once ingestion drains
it. Emptiness is never used as a mount check.

### 3.4 Snapshot, move and restore

- One snapshot per subject per run. It contains `/srv/containers/<svc>`,
  `$staging/<svc>` and every extra path at its absolute path, and excludes are
  expanded to `<path>/<pattern>`. A single snapshot ID keeps the stamp and `cnt
  move` unchanged. SQLite online copies cover `/srv/containers` only. A DB inside
  an extra path needs a hook.
- **A path on a different host than the service.** An extra path is always read
  on the host that runs the service. If the data physically lives elsewhere, it
  is either a network mount, refused at run time, or it belongs to the owning
  host as a host subject there. Pulling data over NFS from h004 only to push it
  back to h004 is never right. Example: arr's `/data/nixarr` belongs to h004 and
  is deliberately not backed up (re-downloadable).
- **`cnt move`**:
  - `onMove = "restore"`: the path is restored from the stamped snapshot to the
    same absolute path on the destination, before start, like
    `/srv/containers/<svc>`. Preflight refuses if the destination path exists
    and is non-empty.
  - `onMove = "present"`: the path is not restored. Preflight refuses unless the
    destination path is local and non-empty. Use this for bulk data on a
    capability disk (immich media), where restoring 639G inside a move window is
    wrong; stage it first with `cnt restore --extra`.
- **`cnt restore <svc> [--snapshot <id>] [--extra all|<path>] [--into <dir>]`**:
  the default restores the `/srv/containers` part only. `--extra` adds extra
  paths at their absolute paths on the service's current host, after the
  capability check, and refuses non-empty destinations unless `--into` points at
  a scratch directory. `restore-check` covers the `/srv/containers` part. Extra
  paths are covered by the target's `check --read-data-subset`.

## 4. h004 storage

### 4.1 Found (2026-11-01, names, sizes and modes only)

```
/data                drwxrwxrwx root:root
/data/backups        drwx------ luser:users   bcachefs subvolume id 2 (created 2026-10-22)
  l001/   316K       2026-06-24_233729, 2026-06-24_234406, 2026-06-25_031548, latest -> /data/backups/l001/2026-06-24_233729
  o001/   549M       2026-06-25_000007, _032443, _035727, _035824, test_235830, latest -> /data/backups/o001/2026-06-25_035824
/data/nixarr         drwxrwsr-x root:2000     (the NFS export)
/data/pinchflat      drwxr-x--- root:media
/data/lost+found
```

`l001` and `o001` are dated rsync trees from the retired
`flakes/common/nix_modules/backup.nix` (deleted in `f877cf5a`). Nothing has
written to them since 2026-06-25, and the `latest` symlinks are **absolute**.

### 4.2 Proposal

- Move them to **`/data/rsync-archive/`** (`luser:users 0700`, a plain
  directory). The name says what the trees are; dates live inside. A subvolume is
  not needed: the barrier against NFS handle forging is `subtree_check` on the
  `/data/nixarr` export, which rejects any dentry outside the export
  (`nfs-data.nix` C2 header), and 0700 stops local non-root readers.
- `/data/backups` stays subvolume id 2 and becomes rest-server's `dataDir`.
  Repos are `/data/backups/svc-<name>`, created by `restic init` as `restic`
  (0700).

### 4.3 Ownership

- `ensure-backups-subvolume` (`hosts/h004/nfs-data.nix`) keeps the subvolume
  check and sets `${target.owner}:${target.owner} 0700` (= `restic:restic`)
  while `ringofstorms.backup.target.enable`, else `luser:users`. It is
  `before` and `requiredBy` rest-server and the prune unit
  (`RemainAfterExit`), so a failed check keeps rest-server down. With the
  target on it also refuses any entry other than `svc-*` and `.htpasswd`, so a
  deploy before §4.4 fails closed. An assertion pins `dataDir =
  /data/backups`. The C2 comment says "0700 restic:restic".
- `restic` has the fixed uid/gid 291 (`ids.uids.restic`), so it is stable across
  h004's impermanent root.
- `users.users.restic.createHome = lib.mkForce false`. Otherwise the module's
  `home = dataDir; createHome = true` lets user activation create and chmod
  `/data/backups` before `/data` mounts at boot (on the root filesystem), and
  re-chown it on every switch. That would be a second owner of the same
  permission bits.
- The module's privateRepos tmpfiles rule creates an unused
  `/data/backups/.htpasswd` stub, because `htpasswd-file` points at `/run`. It
  is harmless, since no user can be named `.htpasswd`.
- `luser` loses access to `/data/backups`. That is intended: nothing of luser's
  remains there after §4.4.

### 4.4 Migration steps (run on h004 as root, before the P1 deploy)

```sh
mountpoint -q /data && bcachefs subvolume list /data | awk '{print $1}' | grep -qx backups
install -d -m700 -o luser -g users /data/rsync-archive
cp -a /data/backups/l001 /data/backups/o001 /data/rsync-archive/   # cross-subvolume: a copy, 549M
ln -sfn 2026-06-24_233729 /data/rsync-archive/l001/latest           # absolute links would dangle
ln -sfn 2026-06-25_035824 /data/rsync-archive/o001/latest
diff -rq --no-dereference /data/backups/l001 /data/rsync-archive/l001 | grep -v '^Symbolic links.*latest'
diff -rq --no-dereference /data/backups/o001 /data/rsync-archive/o001 | grep -v '^Symbolic links.*latest'
# both diffs must print nothing; then
rm -rf /data/backups/l001 /data/backups/o001
ls -A /data/backups          # must be empty
```

Then deploy P1. If §4.4 was skipped, `ensure-backups-subvolume` fails on the
stray `l001`/`o001` and rest-server does not start; nothing is chowned. After
the deploy, verify: `stat -c '%U:%G %a' /data/backups` prints `restic:restic
700`, `bcachefs subvolume list /data` still shows `backups 2`, and the result
survives a reboot (the unit re-asserts it). Rollback before P1 is `cp -a`
back. After P1, set `target.enable = false` (the unit reverts to
`luser:users`), deploy, then copy back.

## 5. Media: h001 → h004 → B2 like any service

- `containers/immich/service.nix`: `backup.extraPaths = [ { path =
  "/drives/wd10/immich/media"; requires = "wd10"; exclude = [ "thumbs"
  "encoded-video" ]; onMove = "present"; } ]`, plus `exclude = [ "mlcache" ]`.
- `containers/paperless/service.nix`: `/drives/wd10/paperless/media` (exclude
  `documents/thumbnails`) and `/drives/wd10/paperless/consume`, both
  `requires = "wd10"`, `onMove = "restore"` (650M); plus `exclude = [
  "data/index" ]`.
- h001: `ringofstorms.backup.subjects.h001-archives.paths = [
  "/home/luser/backups" ]` (48G).
- `hosts/h001/mods/restic-backup.nix` keeps running alongside until P6 deletes
  it, along with its `restic_h001_env` consumer.
- First push is about 639G minus thumbs and encoded video, over the tailnet to
  h004 (both on 10.12.14.0/24, so the path is direct). Start it by hand off-hours
  with `systemctl start fleet-backup-svc@immich`. Nightly runs after that are
  incremental.
- **B2:** `svc-immich`, `svc-paperless` and `svc-h001-archives` are new, empty
  B2 repos, so the first copy **re-uploads about 485 GiB once** (B2 ingress is
  free; uplink time only). Approved (§0.10). The old `7f023d4a` media history
  is not copied (§9).
- Retention defaults to `standard` (= the old job's 7/5/12/3). Raise it to `long`
  in the UI if wanted.
- Dropped from the previous revision: the h004-side media job, the export of
  `/drives/wd10` to h004, and the `host-h001` subject.

## 6. fleet-edge state on h005

h005 declares `ringofstorms.backup.subjects.fleet-edge`:

| Path | Found 2026-11-01 | In? |
|---|---|---|
| `/var/lib/private/fleet-edge-overrides/` | `placements.json` 4.6K, `state.json`, `audit.log`, `placements-audit.log` (all 0600, DynamicUser); `backup*.json` from P2 lands here | yes |
| `/var/lib/fleet-edge-forwards/forwards.json` | 21 B | yes |
| `/var/lib/private/fleet-edge/metrics.db` | 232M, live SQLite | yes (§0.9), via a hook copy |
| `/var/lib/private/fleet-edge/metrics.db.pre-beszel-import` | 23M, static | yes |

- `metrics.db` is live, and host subjects get no SQLite online copy (§3.4).
  `hooks.pre` runs `sqlite3 metrics.db ".timeout 30000" ".backup
  /var/lib/private/fleet-edge/backup/metrics.db"`; the subject includes
  `backup/` and excludes the live `metrics.db{,-wal,-shm}`. `hooks.post`
  removes the copy. Restore copies it back over `metrics.db` with fleet-edge
  stopped.
- The other included files are written by atomic rename; no hook.
- Resolution goes through h005's own `/api/backup`, with the cache as fallback
  when fleet-edge is down. **Disaster restore needs no fleet-edge:** stop
  `fleet-edge-overrides`, run `fleet-restic -r
  rest:http://100.64.0.17:8000/svc-fleet-edge/ restore latest --target /` with
  the hydrated subject secret, then start the unit. systemd re-chowns a
  DynamicUser `StateDirectory` on start (to verify in P5).
- The policy is in the same directory, so the backup also preserves
  `backup.json`.

## 7. joe (low trust)

**Decision: joe may back up to h004 as a client. It can never be a target or a
pusher** (the `target` module asserts `trust == "high"`). Reasons:
- joe's credential reaches only its own subjects. With `privateRepos`, any other
  repo answers 401. With append-only, joe cannot delete history, not even its
  own (403).
- Its subject secrets are `sub`-granted to joe and the targets only, so joe
  gains no high-trust secret. The alternative before this design, the fleet B2
  key, was unacceptable.
- What a compromised joe can still do: fill h004's disk (rest-server has no
  usable quota; `--max-size` returns 507 and bricks writes), and write garbage
  or poisoned snapshots into its own repos. Mitigations: per-subject growth is
  visible in the UI stats. A repo written by a low-trust host is flagged
  `writtenBy: low` in the target record, and restoring it onto a high-trust host
  is the same trust decision `cnt move` placement already makes.

Conditions:
- `backup.lowTrustClients = [ "joe" ]` on the target adds `100.64.0.12` to the
  `:8000` rule (`firewallHighTrustIps` omits low trust).
- Readers get `GET /api/backup/<subject>` for their own subjects only. The full
  view is for writers, so joe learns no other service names.
- `localai` sets `backup.exclude = [ "models" "backends" ]`.
- joe is not always on; `Persistent = true` runs a missed 03:00 job at boot.

## 8. Phases

Each phase deploys on its own and leaves every caller migrated. Phases land in
order. A target change for a service after P3 is a UI edit, not a phase. Adding
a second target or pusher is one module line, one registry grant and a
registration.

### P1: target tier on h004

- **Scope:** §4.4 migration, then `backup/target.nix` (rest-server, htpasswd
  render, prune unit idle until repos exist, `RequiresMountsFor` /
  `ConditionPathIsMountPoint`, firewall + assertions), the `ensure-backups-subvolume`
  ownership change, and one canary subject `svc-canary` (secret, `init`).
- **Code (written 2026-11-04, not deployed):**
  - `flakes/fleet-agent/backup/target.nix`: options `enable`, `dataDir`,
    `requiresMount`, `lowTrustClients`, `subjectCredentials` (`svc-<x>` →
    hydrated secret path), `prunePreset` (default `long` until P2), read-only
    `allowedIps{,6}`, `owner`. Emits rest-server (`8000`, append-only,
    privateRepos, htpasswd in `/run`), `render-htpasswd` (skips unhydrated
    secrets, fails on a malformed one), `ExecReload` HUP,
    `fleet-backup-target-prune` (+ timer 06:00, `User=restic`,
    `LoadCredential`), and the `:8000` rule (v4 + v6).
  - `flakes/fleet-agent/agent-module.nix` imports it.
  - `containers/lib.nix` `backupTargetIps`.
  - `hosts/h004/flake.nix` enables it; `hosts/h004/nfs-data.nix` owner,
    ordering, stray-entry guard. `hosts/h004/firewall.nix` is unchanged: the
    rule lives in the module (§2.8).
  - `containers/tests/backup-plan.nix`.
  - Canary (2026-11-04): h004's Zitadel sub is `394968645089886211`.
    Registry key `machines/backup/restic_svc-canary_2026-11-04` (`sub`
    grants: h004, lio), `subjectCredentials.svc-canary` in
    `hosts/h004/flake.nix`, and the `extraSecrets` entry in
    `hosts/h004/sec-agent.nix` (`hardDepend = [ "render-htpasswd" ]`).
    The secret value is not set yet.
- **Risk: low.** No client writes, and the directory is emptied first. New
  exposure: `:8000` from the allow-list only. Unverified until now: socket
  activation under the module's hardening, and `render-htpasswd` reading root
  0400 secrets.
- **Deploy order:**
  1. §4.4 on h004 (copy, diff, `rm`). Risk: deleting before the diff is clean.
  2. Deploy h004 (pull the new `fleet-agent` input). Risk: if step 1 was
     skipped, `ensure-backups-subvolume` fails and rest-server stays down
     (intended); the ssh rule is untouched.
  3. Check `restic-rest-server.socket` listens, `stat` = `restic:restic 700`,
     empty htpasswd, `curl` from lio → 401, from h005 → 401, from o002 → timeout.
  4. Add the canary key (registry, `sec` deploy), the h004 consumer, redeploy
     h004, `restic init` as `restic`, then the live checks below.
  5. Reboot h004 once; re-check `stat` and the socket.
- **Verify:**
  - `nix eval --impure --expr 'import ./containers/tests/backup-plan.nix'`:
    the allow-list is non-empty, contains lio, excludes o002, h004 and every
    low-trust host, equals the ssh list, and adds joe only via
    `lowTrustClients`. Passes (2026-11-04).
  - Live, as `svc-canary`:
    - `init`/`backup` from lio works; from an unlisted host it times out.
    - `DELETE …/snapshots/<id>` → 403; another subject's credential → 401.
  - The htpasswd file holds only `$2y$` lines; `htpasswd -vi` passes with the
    real password and fails with a wrong one.
  - `stat` shows `restic:restic 700` after a reboot.
  - With `/data` unmounted, rest-server does not start.

### P2: policy, UI, registration, stats

- **Scope:** `flakes/fleet-edge/internal/backup` (records, rows, presets,
  audit, the three allowlists, per-subject reader `GET`), the nginx location,
  the dashboard table, *turn off*, *clear* (API plus the target-side `local`
  executor), the target heartbeat and local stats units, `cnt backup-policy
  list|set`, and `b2PricePerTbMonth`.
- **Files:** `flakes/fleet-edge/{main.go,internal/backup/*,flake.nix}`,
  `hosts/h005/fleet-edge.nix`, `flakes/fleet-agent/backup/target.nix`, `cnt`.
- **Risk: low–medium.** A new authenticated write API on h005, but no backup
  path consumes it yet.
- **Code (written 2026-11-04, not deployed):**
  - `flakes/fleet-edge/internal/backup/backup.go`: rows (`default` row),
    targets, presets, `backup.json`/`backup-targets.json` (0600, atomic),
    `backup-audit.log`; routes `GET /api/backup` (writers, targets),
    `GET|PUT /api/backup/<subject>` (readers: own subjects, no `offsite`),
    `POST /api/backup/<subject>/clear`, `POST|PUT /api/backup/targets/<id>`
    (heartbeat returns presets, offsite list, pending clears), loopback
    `/internal/backup.json`. Wired in `main.go`/`backup.go` (`--backup`).
  - Dashboard: table on `/services` (`internal/server/backup.go`) and the
    editor at `/backup/` (`internal/backupui`, served by `overrides`):
    target, local/B2 preset, offsite (pusher only), turn off, clear (typed
    subject name). nginx gates it with oauth2-proxy `auth_request`
    (`allowed_groups=admin`) and overwrites `X-Auth-Request-*`; the service
    trusts them from loopback only, requires `uiGroup` (`admin`) or
    `uiUsers` to write, a per-user HMAC CSRF token and same-origin POST.
    Writes use the store's `put`/`clear` (409 on a stale revision) and are
    audit-logged with the UI user.
  - `flake.nix` `overrides.backup.*`; `hosts/h005/fleet-edge.nix` enables
    it with the nginx location. `targets.h004` registered
    with sub `394968645089886211`.
  - `cnt backup-policy list|set|clear|heartbeat`
    (`fleet-agent/internal/containers/backuppolicy.go`).
  - `backup/target.nix`: heartbeat (5 min, root, machine key), stats (hourly,
    `restic`), local clear executor (after each heartbeat); prune reads
    presets from the reply, else `prunePreset`.
  - Not yet: `lastCopied`/`b2Bytes`/`complete` and the `b2` clear executor
    (pusher, P4+); the client resolver (P3).
- **Verify:** `go test ./internal/backup/` covers:
  - 403: wrong-peer registration, a reader `PUT`, a low-trust reader asking
    for another subject.
  - 409: a stale or unknown target, `offsite` on a non-pusher, an unknown
    preset, a revision conflict, `clear b2` with no offsite repo.
  - 400: a bad `confirm` or `scope`.
  - one audit line per request.
  - `go test ./internal/backupui/`: CSRF missing/forged, wrong origin,
    header spoof off loopback, non-allowed user (403); set
    target/preset/offsite; offsite on a non-pusher and stale revision (409);
    clear needs the typed name; one audit line per write.

  Live: the canary row renders, its size matches `restic stats`, and a hand
  calculation agrees with $/mo.

### P3: schema, client, container cutover (h001, lio, h003)

- **Scope:**
  - §3 schema in `lib.nix`: `backup.*`, `checkBackupPaths`, and the
    `backupHook` → `backup.hooks.pre` migration in every `service.nix`.
    Service excludes move. No `extraPaths` yet.
  - `backup/client.nix`: resolver, per-subject loop, stamps, host subjects,
    `stampDir`. `host-module.nix` delegates to it, its client `forget` is
    **deleted**, and `repository`/`passwordFile`/`pruneOpts` are removed.
  - `cnt`: stamped `-r` restore, preflight, `restore --extra`.
  - One registry key per subject (18), with consumers in
    `hosts/{h001,lio,h003}/sec-agent.nix`, and the targets.
  - The `restic_h001_env` consumers on lio and h003 are removed. h001 keeps its
    copy for its host job.
- **Order:**
  1. Stop and mask `fleet-backup` on the three hosts.
  2. On h004, for each subject: `restic init --copy-chunker-params --from-repo
     <old> --from-password-file <tmpfs>` as `restic`, then `restic copy
     --from-repo <old> --tag svc:<name>` (about 31 GiB down from B2).
  3. Deploy and unmask.
  4. First runs.

  The old password and key come from the password manager into a tmpfs file
  that is removed afterwards. h001's host job is untouched and keeps writing
  `--tag h001` to the old repo.
- **Risk: medium.** The retention handover: the target pruner must already run
  with presets, or nothing bounds the repos. 43G is re-read on h001. A missing
  grant shows as a 401 and a missed night, visibly.
  - **Rollback:** restore the env consumer and revert. The old repo still holds
    everything.
- **Verify:**
  - Pruner `--dry-run`: one group per repo, with `keep 7 daily, 5 weekly, 12
    monthly, 3 yearly`.
  - Client log has **no** `Applying Policy` line.
  - `cnt restore-check forgejo` (3 PG dumps) and `puzzles` (2 SQLite).
  - While h001's run is in flight, `svc-puzzles` → `svc-forgejo` and `svc-sec`
    → `svc-secrets` both answer 401.
  - A real `cnt move hello-nixos`, plus a move whose destination lacks the
    grant (must fail in preflight).
  - API down: the cached run works; cache deleted: the run fails.
  - Every `init`/`copy` is run with `</dev/null` and distinct password files,
    and exits 0.

### P4: pusher tier on h004

- **Scope:**
  - `backup/pusher.nix`: copier, B2 prune, B2 stats, `offsite-b2.json`, and
    the *clear* `b2` executor.
  - `restic_b2_h004_<date>`: a new B2 app key with `namePrefix = "svc-"`.
  - `init` each `<B2>/svc-<name>` with chunker params from the local repo.
  - `offsite = true` per service in the UI.
- **Files:** `flakes/fleet-agent/backup/pusher.nix`, `hosts/h004/{flake.nix,sec-agent.nix}`,
  `containers/sec/registry.nix`.
- **Risk: medium.** This is the first spend: a full first upload of about 31
  GiB, then about $0.21/mo. B2 deletions are limited to the new `svc-*` repos,
  and the key cannot reach the old repo's path.
- **Verify:**
  - The first copy's B2 raw-data size is within a few hundred bytes of local's;
    a re-run adds 0 B.
  - Each B2 repo opens only with its own subject's password.
  - Shallow-B2 fixture: the gate passes. The same fixture with one uncopied
    snapshot fails.
  - A→B→C: `original` chains, and raw IDs intersect in 0.
  - `clear a b2` leaves `b` byte-identical and flips only `a.offsite`.
  - With the new key, the old repo's prefix answers 401/403.

### P5: media, archives and fleet-edge as subjects

- **Scope:**
  - §5 `extraPaths` for immich and paperless.
  - `h001-archives` on h001 and `fleet-edge` on h005 (§6).
  - Their three or four subject keys; `init` on h004 (copied chunker, no
    history seed, §9).
  - `offsite = true`.
  - The old h001 host job **keeps running** in parallel, so offsite media is
    never older than one night.
- **Files:** `containers/{immich,paperless}/service.nix`,
  `hosts/h001/floating-containers.nix`, `hosts/h005/*`, the registry, and
  `sec-agent.nix` on h001 and h005.
- **Risk: medium–high.** The largest transfer: about 639G to h004, then about
  485 GiB to B2 (approved, §0.10). The wd10 empty-dir guard is the safety net.
  B2 storage roughly doubles until P6b.
- **Verify:**
  - `svc-immich`'s local size is within a few percent of `du` minus excludes.
  - With wd10 unmounted (test on a scratch path), the empty-dir guard fails the
    subject.
  - `cnt move` preflight for immich refuses a destination without media
    (`present`).
  - `cnt restore paperless --extra all --into /tmp/x` round-trips.
  - fleet-edge disaster drill on a scratch directory.
  - Completeness record clean for all new subjects.

### P6: retire the old fleet-wide credential

- **Gate:** `offsite-b2.json` is clean for every `offsite` subject, including
  `svc-immich`, for 7 consecutive days.
- **Scope, in this order:**
  1. Delete `hosts/h001/mods/restic-backup.nix` and its `sec-agent.nix` entry.
  2. Create a **read-only** B2 key scoped to the old repo's prefix
     (`listFiles`, `readFiles`). Store it in the password manager only.
  3. Delete the `restic_h001_env_2026-10-01` registry entry and deploy `sec`.
  4. Delete the hydrated copy on **every** host that ever hydrated it (any
     high-trust host could) and confirm it is absent.
  5. Revoke the old B2 app key in Backblaze.
- **Risk: medium.** Revocation is irreversible. The old repo stays intact and
  readable through the step-2 key.
- **Verify:**
  - Fetching the old secret from a high-trust host fails.
  - `restic snapshots` with the old key fails.
  - The legacy repo still lists with the break-glass key.
  - The pusher's key still copies.
  - `grep -rn restic_h001_env hosts/ containers/` is empty.

### P6b: delete legacy repo `7f023d4a`

- **Gate (all):**
  1. P6 done.
  2. `offsite-b2.json` is clean for **every** subject with `offsite = true`
     (including `svc-immich`, `svc-paperless`, `svc-h001-archives`,
     `svc-fleet-edge`): each expected snapshot is present on B2 by
     `(.original // .id)` with matching `time,hostname,paths,tags,tree`, and
     `check --read-data-subset` passed.
  3. That has held for a few consecutive days (3 by default) after the last
     subject's first full copy finished.
  4. `restic ls latest` from B2 alone succeeds for one container subject and
     for `svc-immich`, using break-glass passwords only.
- **Scope:** delete the whole `7f023d4a` prefix in B2 (no tag-scoped prune; no
  current subject lives there), then drop the legacy password and read-only
  key from the break-glass record.
- **Risk: medium, irreversible.** Pre-cutover history, including media, is
  gone.
- **Verify:** the bucket lists only `svc-*`; B2 storage drops by about 492 GiB.

### P7: joe

- **Scope:** §7. `backup.lowTrustClients = [ "joe" ]` on h004, joe's subject
  keys, `localai` excludes, `containers.backup.enable` on joe.
- **Risk: low–medium.** A low-trust host gains a write path to h004 that is
  limited to its own append-only repos.
- **Verify:**
  - joe → its own repo works; joe → `svc-forgejo` answers 401.
  - joe's `GET` for another subject → 403.
  - The `:8000` rule lists `100.64.0.12`.

### P8: docs

- **Scope:** remove the old story:
  - `containers/README.md` "Nightly restic";
  - `hosts/h001/readme.md` restic row;
  - `hosts/h004/readme.md` (its lines are corrupted with an NFS-table prefix;
    rewrite it);
  - `ideas/restic_backups.md` (records the opposite decision);
  - `ideas/h004_erasure.md` ("backups live on B2, not h004");
  - `containers/sec/README.md` (break-glass kit and cold restore).
- **Risk: low.** Each earlier phase already updates the docs it changes.

## 9. Legacy repo `7f023d4a`

- From P3, nothing prunes its `fleet`/`svc:*` rows. From P6, nothing writes it
  and no host can reach it. Only the break-glass read-only key can.
- It holds the pre-cutover container history and the h001 media history
  (`--tag h001`). None of this is copied into the new repos. The containers'
  `svc:*` history is seeded in P3. The media history is not, because it is mixed
  with paperless and archive paths in single snapshots; it is dropped (§0.7).
- **Untouched during the migration:** no prune, `rewrite`, key change or delete
  on it until P6b. Its existing key keeps working until P6 step 5.
- **Deletion** is P6b, gated on the completeness check, not on a time window.
- **Cost:** about 1.0 TB stored until P6b (491.7 GiB legacy + about 516 GiB
  new) ≈ $7/mo. After that, about $3.6/mo.
- **Break-glass record** (`containers/sec/README.md`, break-glass kit): each pusher's bucket key, one
  password per subject, and the legacy password + read-only key until deletion.

## 10. Decisions taken (formerly open)

1. **Legacy media history:** not seeded. `7f023d4a` is kept untouched during
   the migration and deleted a few days after the completeness gate (§0.7,
   P6b). Pre-cutover media history is lost then.
2. **The rest of wd10** (about 1.04T): out of scope; the user sorts it
   manually (§0.8).
3. **fleet-edge `metrics.db`:** included (§0.9, §6).
4. **One-time ~485 GiB media re-upload to B2:** approved (§0.10).

Unverified until P1 runs on h004: socket activation under the module's
`PrivateNetwork`/`PrivateUsers` hardening; `render-htpasswd` under its unit;
rest-server on an empty htpasswd; the stats pass time on `svc-immich` (hourly
may need to become daily); systemd re-chowning the restored DynamicUser state
(§6).

## Appendix A: measurements (loopback, rest-server 0.14.0, restic 0.18.1)

**A.1 `privateRepos` is path-component based.**

| User | Path | Result |
|---|---|---|
| `svc-puzzles` | `/svc-puzzles/extra/config` | 404 (allowed, no repo) |
| `svc-puzzles` | `/svc-puzzles-x/config`, `/nonuser/config` | 401 |
| `svc-sec` | `/svc-secrets/config` (exists; 200 to its owner) | 401 |
| `svc-secrets` | `/svc/config`, `/config` | 401 |
| `svc-secrets` | `/svc-secrets/../svc/config` | 401 |
| `svc-secrets` | `//svc-secrets/config` | 307, then allowed |

**A.2 Append-only.**

| Request | Result |
|---|---|
| `DELETE /<own>/locks/<id>` | 200 |
| `DELETE /<own>/snapshots/<id>`, `/index/<id>`; re-`POST` a snapshot | 403 |
| `forget` on own repo | 403 per snapshot, **exit 0** |
| `prune` with garbage | `Fatal`, exit 1, repo still `check`-clean |
| `key add` / `key remove` | works / 403 |
| any request to another user's repo | 401, "Is there a repository…" |
| `.htpasswd` change without SIGHUP | ignored |

**A.3 restic copy, chunker, passwords.**

- The first copy into an empty repo is a full upload, even with copied chunker
  params: 20,005,756 → 20,005,811 B.
- A repeat copy adds 0 B. 5 MB of new data adds 5,002,880 B.
- Backing up the same files at a new path into a repo that inherited the
  chunker: 2,366 B. Without the inherited chunker: 20,005,172 B.
- Copies get new IDs and keep the source ID in `original` across hops. Raw IDs
  intersect in 0.
- The gate's dry-run must run on the **local** repo. On the destination it
  missed an uncopied snapshot.
- Only the last `-p` counts, and it is the destination's. The source password
  must go in `--from-password-file`. The `-p`-twice form with no TTY exits 1
  ("empty password"). A wrong source password exits 12.
- `forget` with the default grouping put 18 services into 4 groups and removed
  nothing. `--group-by ''` removed 3 of 4.
- A bare `http://` repo is parsed as a local path. `rest:http://` with
  `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` works, and the stored URL
  contains no credentials.
- A file `ReadOnlyPaths` bind does not pin the old inode across `rename(2)`.
  `htpasswd -niB` with the password on stdin needs no TTY.
