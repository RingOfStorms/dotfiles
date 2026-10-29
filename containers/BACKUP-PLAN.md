# Container backups: a local backup target instead of a B2 key per host

Today every container host that backs up holds the *whole* offsite credential:
`machines/high-trust/restic_h001_env_2026-10-01` carries `RESTIC_REPOSITORY`,
`RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
(`containers/sec/registry.nix:210`), and the grant is the `device_high_trust`
**role**, so any high-trust host can hydrate it with no registry change
(`ROUTING-PLAN.md` §9.1). Ten host configs bind that role — h001, h003, h004,
h005, lio, o002, oren, juni, gp3, and oracle's bootstrap install, which has no
entry in `hosts/fleet.nix`. Three of them run the container backup job (h001,
lio and h003 set `ringofstorms.containers.backup.enable`). Any host that hydrates
it can `restic forget --prune` the entire fleet's history, and that is not
hypothetical: h001's nightly run does exactly that (§2.2) and has removed
snapshots from the shared repo. The repo holds 164 snapshots, 597583 blobs,
491.7 GiB stored (repo `7f023d4a`). The container jobs are 154 snapshots /
31.2 GiB of that; the rest is h001's host job.

Target: **container hosts write to whichever host is currently marked a backup
target, and know nothing about B2.** Which hosts *can* take backups is hardware
fact, declared by each capable host; which one a given service *uses* is runtime
state in the fleet-edge UI (a default plus per-service overrides), and `offsite`
is a second per-service flag because it costs money. Clients resolve the target
at backup time and build the repository URL from it — the secret carries only
credentials, so changing a target is a UI edit, not a re-deploy. The transport
stays the restic REST protocol, so snapshot bytes never pass through
`fleet-agent`, and `fleet-restic`, the stamp files and `cnt move` keep working.

Status: **design only, nothing deployed.** Every rest-server behaviour below was
measured against 0.14.0 on loopback fixtures; the h004 deployment itself has
not been built or run yet (marked *unverified* below).

---

## 1. Premise check

The requirement assumed an h004→B2 copy already exists and only needs routing to.
It does not:

- **No h004 job writes to B2.** h004's hydrated secrets are
  `atuin-key`, `github_read_token`, `headscale_auth`, `nix2gitforgejo`,
  `nix2github` — no restic env file, no `restic` binary, no `fleet`/`cnt`
  binary, nothing listening on `:8000`. The old rsync-based
  `flakes/common/nix_modules/backup.nix` was deleted in `f877cf5a`.
- **`/data/backups` is empty of anything live**: a bcachefs subvolume (id 2,
  created 2026-10-22) holding `l001` (316 K) and `o001` (549 M) from 2026-06-25.
- **h004 has no containers module**, so it is not a `cnt move` target and gets
  no `fleet-backup` today.

So the copier is new work, and phases 1–4 change only *where* container hosts
write. One requirement refinement is worth recording: the target is chosen at
runtime, which means it cannot be baked into a secret — a `RESTIC_REPOSITORY`
line on disk is exactly what would make the choice immutable (§3.5).

## 2. Assessment

### 2.1 One key, fleet-wide write access

The env file is a single secret, granted by role, hydrating a B2 bucket key plus
the repo password. A compromised h001, lio or h003 (or anyone who reads
`/var/lib/secrets_manager_hydrated/restic_h001_env_2026-10-01`, mode `-r--------`
root) can delete the fleet's entire history and every other host's snapshots.
Nothing in the design limits blast radius below "any high-trust host". Grants are
whole-key: there is no field-level grant to hand out "password but no bucket key".

### 2.2 Append-only is the right control, with sharp edges

Two regimes, and conflating them is the trap. Production today is **not** an
append-only repo: h001's hydrated env file carries
`s3:https://s3.us-west-002.backblazeb2.com/…` and no `rest:` URL, read by
`fleet-backup.service` through `EnvironmentFile`. S3 has no append-only mode, so
client-side `forget --prune` runs there and **succeeds**. After the cutover the
same code points at an append-only rest-server, where it becomes a silent no-op.
The measurements below are labelled with the regime they belong to.

**Regime A — today, clients prune against S3.** Live journals
(`journalctl -u fleet-backup`, read 2026-10-29):

- h001's `fleet-backup` applies the keep-set on every full run —
  `Applying Policy: keep 7 daily, 5 weekly, 12 monthly, 3 yearly snapshots`,
  once per tag group. Recent runs end `keep 8 snapshots` and delete nothing,
  which is the keep-set doing its job, not a failure.
- It has also deleted, and that is the point. On 2026-10-22 11:38 the run logged
  `remove 1 snapshots:` naming `731895a9`, tags `fleet,svc:puzzles`, then
  `running prune` and `total prune: 16 blobs / 248.549 KiB`. A *container* host
  deleted a container snapshot from the repo the whole fleet shares — §2.1's
  mechanism observed, not hypothesised.
- h001's media unit (`restic-backups-h001.service`) prunes nightly too:
  2026-10-28 `remove 1 snapshots … total prune: 4461 blobs / 3.054 GiB`,
  `unused size after prune: 2.788 GiB (0.57 % of remaining size)`. Its
  `pruneOpts` carry `--tag h001` (`hosts/h001/mods/restic-backup.nix:56-66`), so
  it does not touch the `fleet`/`svc:*` snapshots — two jobs, one repo,
  partitioned by tag.
- h003 and lio both print `Applying Policy` (3 and 6 occurrences in the retained
  window) and have removed nothing — their series are younger than the keep-set.

So retention is *live* today, and it is live **from the clients**: any host with
the env file can delete the fleet's history, which is §2.1's blast radius
demonstrated rather than argued. A compromised client does not need to wait for a
bug; `forget --prune` is already the nightly routine.

**Regime B — after the cutover, the same code against an append-only
rest-server 0.14.0.** Measured on loopback fixtures, not yet on h004:

| Request | Result |
|---|---|
| `DELETE /fleet/locks/<id>` | **200** (lock breaking is allowed) |
| `DELETE /fleet/snapshots/<id>`, `/index/<id>`, `POST` an existing snapshot id | **403** |
| no auth / unknown user | 401 |
| `restic forget --tag fleet --keep-last 1` | `Remove(...) failed: 403` **per snapshot, exit 0** |
| `restic prune` with nothing unreferenced | `unused size after prune: 0 B`, **exit 0** |
| `restic prune` with garbage | `Remove(<index/…>) failed: 403`, `Fatal`, **exit 1**; repo stays `check`-clean |
| `restic key add` / `key remove` | add works; remove → 403 (a client cannot revoke a key) |

Consequences, and this is why the *container* client prune must be **deleted**,
not left in place:

- **Over append-only it becomes a silent no-op.** `host-module.nix:399-402` runs
  `restic forget --retry-lock 2h --prune --tag fleet --group-by tags …` on every
  full run. Against a rest-server it prints a 403 per snapshot and exits 0, so
  retention would stop the day the target changes and nothing would report it.
  Today that line is the only thing bounding the container snapshots, which makes
  the cutover a change to retention and not just a change of address — the
  target-side pruner (§3.2) must exist first, in the same deploy.
- **h001's media `pruneOpts` are a different case** and stay until the media job
  itself moves (§3.2, §6): it writes to S3, where deletion works.
- Monitoring must not trust the exit code of `forget`. The target's pruner is a
  local `restic forget --prune` against the **filesystem path** (verified working:
  `2 / 2 files deleted`), and it must fail the unit when the repo is broken.
- Lock deletion being allowed is what keeps `--retry-lock 2h` and `cnt move`
  working; a crashed client leaves a lock that ages out.
- Snapshot counts are only evidence of retention if you know which regime produced
  them. The 164-snapshot figure in §2.1 is a pruned repo under a 7/5/12/3
  keep-set, not an unpruned one.

### 2.3 One target today: h004, and that is a single point of failure

h004 is the only host with capacity for it: `/data` is 51 T, 25 T used, **26 T
free**, and a full fleet copy is ~31 GiB compressed. Its pool is bcachefs with
replication 2 (data and btree `Required/total 1/2`, durability 2), so the repo
survives one disk failure. `/data/backups` is additionally a subvolume, mode
0700, so the NFS export of `/data/nixarr` cannot reach it (`subtree_check`, see
`hosts/h004/nfs-data.nix` C2 header).

Single target = single point of failure. If the one enabled target is down at
03:00 the backup is skipped (`ConditionPathExists` + `Persistent=true` +
`RandomizedDelaySec=15m` retries it), and a `cnt move` needs a target holding the
snapshot reachable when it runs. The design allows *n* targets (§3.3) and the
policy picks one, but h004 is the only host with the capacity for a second, so
for now the trade is real: dropping per-host credentials concentrates
availability risk on one host. The offsite copy is what protects against losing
that host, which makes §2.5 matter more, not less. A second target on the same
physical machine would be worse than useless — it would look like redundancy.

### 2.4 Encryption at rest is client-side only

`/data` is **not** encrypted: `bcachefs show-super /dev/sdb` has no encryption
field and the feature list carries none; only h004's *root* is (impermanence +
USB key, `hosts/h004/flake.nix:52-63`). `/data` itself is `drwxrwxrwx`. restic's
own AES-256 repo encryption is therefore the entire confidentiality boundary for
the backup copy, and its password lives on every client. The repo dir is
`restic:restic` 0700 under a `luser`-owned 0700 `/data/backups`, so only root
and the service user can read it — but anyone with root on h004, or any holder
of the repo password who can reach the pool, reads every service's data. Put
that in the threat model; it is also an argument for the pool being encrypted
next time it is rebuilt, which this plan does not attempt.

### 2.5 Cost: the media job is 15× everything else in the repo

| Slice | Stored |
|---|---|
| Whole repo (164 snapshots) | 491.7 GiB |
| `--tag fleet` (container services) | **31.2 GiB** |
| `--tag h001` (10 snapshots: immich media) | **484.9 GiB** |

At B2's $6.95/TB/mo that is **$3.34/mo** today, of which **$0.21/mo** is the
fleet's container data. The container copy is a rounding error; the whole bill
is h001's 639 G immich media. Any plan that keeps "one repo, everything in it"
keeps paying for the media. Per-service opt-in bounds *future* growth, and moving
h001's media job to h004 (26 T free) would cut the bill to near zero at the cost
of having no offsite copy of the media at all — a user decision (§6).

## 3. Recommendation

### 3.1 Transport: `services.restic.server` on each target, one shared repo each

```nix
# what h004's `backupTarget.enable` emits (agent-module.nix, §3.8)
services.restic.server = {
  enable = true;
  listenAddress = "8000";        # bare port: the module asserts this (socket activation)
  dataDir = "/data/backups/restic";
  appendOnly = true;
};
```

- `listenAddress` must be a **bare port**; the module asserts
  `lib.substring 0 1 cfg.listenAddress != ":"` and the socket unit takes
  `[ "8000" ]`, i.e. the socket listens on all addresses and **the firewall is
  the ACL** (§3.6). Restricting the bind address is not expressible through the
  module.
- One repo **per target**, URL path `fleet`, one htpasswd user per container
  host: `rest:http://100.64.0.17:8000/fleet/`. That URL is what the target's
  record publishes (§3.3); nothing else in the system knows it. Every target
  needs the *same* user set and the same repo password — otherwise a service
  pointed at a target it has never written to fails auth on its first run — so
  adding a container host is an *n*-target change, not one host's secret.
  Measured on one shared repo: each user sees the other's snapshots; cross-host
  dedup works (`2.252 KiB (1.666 KiB stored)` for a 3.8 MiB re-read); h003
  restored a snapshot written by h001 (`Restored 4 files/dirs`); `snapshots
  latest --tag svc:y` still resolves. So `svc:<name>` history keeps following
  the service across a move, which is what `cnt move` depends on.
- `--private-repos` per-host repos are rejected: the second host gets `Is there
  a repository at …?`, so history and dedup split, `cnt move` needs a `--repo`
  flag plus a `restic copy`, and `restoreScript` needs changes. Defer.
- **`/data` is `nofail`** (`hosts/h004/data-pool.nix:50`), so a boot with a
  missing pool continues and a rest-server started anyway would create
  `/data/backups/restic` **on the root filesystem** and accept the whole fleet's
  backups there. Set
  `systemd.services.restic-rest-server.serviceConfig.RequiresMountsFor = [
  "/data" ]` (and the same on the prune and copy units, which otherwise prune a
  directory that is not the pool). `ConditionPathIsMountPoint=/data` is the
  blunt version if the unit should refuse rather than wait.
- Nothing creates the *repository*: the module has no `initialize`, so
  `restic init -r /data/backups/restic/fleet` is a one-time manual step in
  phase 1, run as `restic` so the files are owned by the service user. Same for
  `.htpasswd` (`htpasswd -B`, one line per host) — the module only pre-creates
  that file when `privateRepos` is set. Directory creation is manual too: the
  `users` activation script runs long before `/data` exists, so `createHome`
  cannot be relied on; `install -d -m700 -o restic -g restic
  /data/backups/restic` once, or a tmpfiles rule gated on the mount.
- Add `ExecReload` (§3.5) — the module has none.

### 3.2 Who prunes: each target, locally, against its own filesystem path

A root unit on the target runs, per repo:

```sh
restic unlock
restic forget --prune --tag fleet --group-by tags <retention>
```

with `RESTIC_REPOSITORY=/data/backups/restic/fleet` (**a path, not the URL**).
Append-only is enforced by the REST server only; a local process with read/write
on the files is the admin. This is the only prune *that works* on the target —
one per tag partition, one per target, none on the clients.

Two client prunes exist and they are not the same thing:

- `host-module.nix:399-402` — the container job's `forget --tag fleet`. This is
  the one the target's pruner replaces, and the one that must be **deleted in the
  same deploy** that points clients at the target. Left in place it becomes
  per-snapshot 403s with exit 0, so retention would vanish silently (§2.2).
- `hosts/h001/mods/restic-backup.nix:56-66` — h001's media job, tagged `--tag
  h001`, writing to B2 over S3. S3 is not append-only, so that prune *works* and
  must **stay**. It only loses `pruneOpts` on the day the media job moves to a
  target (§6); at that point the target's pruner needs a second invocation with
  `--tag h001`, because the tag partitions do not prune each other.

Clients keep `--retry-lock 2h` either way (locks are deletable, so a crashed host
does not wedge the repo).

Retention lives in one place — the target's own module, emitted by
`backupTarget` — not per host. Per-service retention is not supported: a
service's snapshots are rows in the same repo and `forget` groups by tags, so a
per-service keep-set would need one `forget` per tag — cheap to add later, not
needed now. Two targets means two pruners with the same keep-set, which is a
duplication worth having: a target must be able to prune alone, because it may be
the only one left holding a series.

### 3.3 Policy: targets are capability records, the choice is runtime state

Two different things, kept apart:

**Capability (declared in Nix, one record per host).** A host that can accept
backups says so in its own module — rest-server config, port, repo path,
firewall rule — and that module also registers a *target record* with fleet-edge
at boot:

| Field | Example | Meaning |
|---|---|---|
| `id` | `h004` | Stable key the policy refers to; the hostname |
| `url` | `rest:http://100.64.0.17:8000/fleet/` | Becomes `RESTIC_REPOSITORY` verbatim |
| `offsite` | `true` | This target runs a copier, so services here can opt in (§3.4) |
| `enabled` | `true` | Operator switch: drain and hide a target without undeploying the server |
| `declaredBy` | `100.64.0.17` | Record is only accepted from that peer |

Registration is a POST from the host itself through the existing `fleet-edge`
plumbing, not a hand-edited JSON file: it is derived config and must vanish when
the host stops declaring itself. A timer re-registers every few minutes, and a
record `declaredBy` a peer that has not re-registered within ~1 h is rendered
*stale* and is not selectable for new writes. Without the heartbeat a target that
was decommissioned months ago would stay selectable forever, which is exactly the
failure the UI must not offer.

**Policy (runtime state, edited in the fleet-edge UI).** Per service, with a
fleet default row:

- `target` — a target `id` from the enabled, non-stale set, **or the literal
  `none`** meaning "not backed up". Modelling it as a value of `target` rather
  than a third flag keeps `none` and "nothing resolved" from disagreeing, and
  gives the UI one thing to display. `cnt move` refuses such a service (§3.7);
  that refusal is what keeps the value honest.
- `offsite` — `true|false`; refused at `PUT` time if the chosen target
  advertises no copier, so a target change cannot silently drop the cost flag.

Where it lives: `flakes/fleet-edge/internal/backup`, a new package beside
`overrides` and `placements`, on the same loopback listener:

- Two 0600 files in the existing `StateDirectory`: `backup-targets.json`
  (registrations, replaced on each POST) and `backup.json` (policy rows plus the
  `default` row), atomic write under one mutex, audit log `backup-audit.log`
  (one JSON line per request, refusals included) — the shape of
  `placements.json`.
- Routes on the `:443` nginx vhost (`hosts/h005/fleet-edge.nix:213-240` shape):
  `POST /api/backup/targets/<id>` (registration; the caller's peer IP must equal
  the record's), `GET /api/backup` (the resolved view: targets + policy),
  `PUT /api/backup/<svc|default>` (`{target, offsite, revision}`). The mux entry
  is `{"/internal/backup.json", "/api/backup", bk.Handler()}` in
  `flakes/fleet-edge/main.go:230-241`; `/internal/backup.json` is *not* for
  clients — it is read by fleet-edge's own dashboard, exactly as
  `FLEET_EDGE_OVERRIDES_URL` points `internal/server` at
  `http://127.0.0.1:8098/internal/overrides.json`
  (`flakes/fleet-edge/flake.nix:461`). Clients use the public `/api/backup`,
  proxied by a new `locations."/api/backup"` block on `127.0.0.1:8098` copied
  from `/api/placements` including `deny 100.64.0.5`, the 16k body cap and
  `identityClear`.
- Auth: `internal/authority.Authenticate` throughout. `PUT` needs a writer sub
  (`lio`, `juni`, `gp3`, `oren` — `hosts/fleet.nix:54-59`) plus `AllowWrite`;
  `GET` needs any container host's machine token; `POST` needs the target's own.
  `PUT` naming an unknown, disabled or stale target is a 409.
- The dashboard gains a target column and a form; this is the first action
  `internal/server` grows, so keep it the only one.

**Clients resolve the target at backup time, over the public API.** There is no
loopback path for a container host: `/internal/*` is never proxied by h005's
nginx and a container host is not h005. So the resolver is an authenticated
`GET /api/backup` through `h005:443` with a Zitadel machine token — the same
`edgeClient` shape `cmdExpose` already uses
(`flakes/fleet-agent/internal/containers/edgeapi.go:100-150`), which means readers
need a machine-token grant, not a new transport. Read-only, so
`internal/authority` grants it to every container host (the set is derivable from
the same allow-list as §3.6) while `PUT` stays writer-only.

`fleet-backup` resolves `target` per service once per run and builds
`RESTIC_REPOSITORY` from `url`. If the API is unreachable it uses the last good
copy cached at `/var/lib/fleet-backup/target.json` (0600) and records
`target=<id>` and `repo=<url>` in `/var/lib/fleet-containers/backup-last/<svc>`;
with no cache the run fails rather than guessing — a backup written to the wrong
host is worse than a missed night, because the stamp would then lie about where
the data is. `offsite` never reaches the client.

Adding `target=<id>` and `repo=<url>` to the stamp is safe: `parseStamp`
(`move.go:68`) is a `strings.Fields` key/value loop that ignores keys it does not
know and only requires `time` and `snapshot`, so an older `cnt` keeps reading new
stamps; the target-aware move must read both new fields (§3.7).

### 3.3a Changing a service's target

Snapshot bytes do not move; consequences in the order they matter:

1. **The series splits.** Two targets are two repositories — different chunker
   keys, different blob names. `restic copy --from-repo <old> --tag svc:<name>`
   migrates history when it is worth it (measured: tag-scoped, dedup preserved,
   62 M → 62 M); without it the new series starts at the switch. Only an explicit
   `cnt restore --latest` selects the newest snapshot across targets (§3.7).
2. **The old target stays readable.** Nothing deletes it: it remains registered
   and `enabled` so explicit restores can reach older snapshots, with its own
   retention still pruning on schedule. Retiring it is an explicit operator step
   after the keep-window passes with no reads — never automatic, because a repo
   pruned to empty looks exactly like a new one.
3. **A move becomes two-target.** `cnt move` must read the source's final backup
   from its stamped target and repo and write the destination's first backup to
   its resolved target; if they differ, both must be enabled and reachable. Both
   are preflight checks (§3.7), so it refuses before downtime rather than
   mid-switch.

### 3.4 The offsite copier: the target pulls, per tag

Today h004 is the only target, so this is h004's unit; a second target would
carry its own copy. Emitted by its `backupTarget` option, not hand-written:

```sh
restic copy --from-repo /data/backups/restic/fleet \
            --from-password-file /var/lib/fleet-backup/repo-password \
            --tag svc:<name>          # one invocation per opted-in service
```

- Runs **on the target**, from the filesystem path of its own repo, so append-only
  is not in the way and no client is involved. `copy` re-reads and re-uploads,
  preserving dedup inside B2 (`--copy-chunker-params` only matters at `init`).
  The B2 side comes from an `EnvironmentFile` (`RESTIC_REPOSITORY`,
  `RESTIC_PASSWORD`, `AWS_*`) as `fleet-backup` does today; the local repo's
  password is a root-only file. Both hydrated by the target's `sec-agent.nix`.
- The list of tags to copy is the `offsite: true` set from the policy export,
  filtered to services whose `target` is *this* target. A service pointed
  elsewhere is simply not this target's business — the copier never reads another
  host's repo.
- Seeding: `restic init --copy-chunker-params --from-repo <B2 repo>
  --from-password-file <B2 pw>` gives the new B2 repo the same chunker, so
  cross-repo dedup of the media job survives if it stays.
- New B2 repo, not the existing one. The current repo is h001's media history
  (`--tag h001`, 484.9 GiB of 491.7); sharing it means any `forget --prune` on
  the media tag endangers the container copy. Separate repo also means a separate
  bucket key (§3.5) and separate retention.
- Only the target holds the bucket key. `restic_h001_env_2026-10-01` narrows to
  "h001's own host job" (which still needs B2 directly unless §6 moves it); a new
  `restic_offsite_<date>` key is scoped to h004's sub.
- Backup of the backup: the local repo is the only copy between 03:00 and the
  copy run. Order the timers (prune → copy) and make the copier fail loudly; a
  stale `lastCopied` is the number to watch, not `lastBackup`.

Now that the target is runtime state, the copier must also be *re-read* on
change: it re-fetches the policy each run (same authenticated `GET /api/backup`
the clients use, with the target host's machine token), so opting a service in or
out needs no deploy. If that call fails the copier does nothing for that run and
leaves `lastCopied` stale rather than guessing a tag list — copying the wrong
service costs money, so the failure is the safe side.

### 3.5 Secrets: credentials only, no repository

Because clients resolve the target, the per-host secret **must not contain
`RESTIC_REPOSITORY`** — a baked URL is exactly the thing that makes the target
unchangeable. One registry key per host:
`machines/high-trust/restic_rest_<host>_<date>`, `fields = [ "value" ]`,
`access = [ { type = "sub"; value = "<host machine userId>"; } ]` (add
`device_high_trust` only while a host still needs the old file). Contents, names
only:

```
RESTIC_PASSWORD=<repo password, shared by every target>
RESTIC_REST_USERNAME=<host>
RESTIC_REST_PASSWORD=<host password, from htpasswd -B>
```

Two consequences worth stating. **One repo password fleet-wide**: a service that
changes target must find its password valid at the new one, so every target's repo
is `init`ed with the same password; per-target passwords would make the target
choice and the credential coupled, and a target change would then need a secret
rotation and a `restic key` dance. Accept the weaker blast radius (any host with
the password can decrypt any target's repo, §2.4) — the htpasswd user is what
distinguishes hosts. And **the URL lives in the policy, not on disk**: the only
persisted copy is the client's `target.json` cache, which is a resolved answer,
refreshed every run.

`RESTIC_REST_USERNAME` / `RESTIC_REST_PASSWORD` are real in restic 0.18.1 (present
in the built binary); URL userinfo also works but lands in the repo URL, which is
stored in every snapshot and printed by `restic snapshots`.

Wiring is one `configChanges` entry per host, pointed at the new secret:
`configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH"`
stays as written, only the key it names changes. The existing static
`containers.backup.repository` option (`host-module.nix:627-631`) goes away —
a repo set at build time is the thing this design removes. The `fleet-restic`
wrapper (`host-module.nix:1253-1260`, inside the block opened at 1245)
keeps `set -a; . $file`, then exports `RESTIC_REPOSITORY` from the resolved
target unless the caller passed `-r`/`--repo` (so a hand-run
`fleet-restic -r <url> …` against any target still works for forensics), and the
same resolution feeds `fleet-backup`'s `backupScript` — one resolver, two callers.

**h001 binds one env file to two units** — `services.restic.backups.h001` (media,
B2) and `ringofstorms.containers.backup` (containers, target) both take
`restic_h001_env_2026-10-01` (`hosts/h001/sec-agent.nix:65-68`). Stripping
`RESTIC_REPOSITORY` from that file would break the media job, which still needs a
static S3 URL. So h001 ends up with **two** secrets and two
`configChanges` lines: the existing one for `services.restic.backups.h001`, and
`restic_rest_h001_<date>` (credentials only) for the containers job. Every other
container host needs only the latter.

Rotation: **`.htpasswd` is read once at process start.** Adding a user or rotating
a password had no effect until restart or SIGHUP (verified). The module has no
`ExecReload`, so add:

```nix
systemd.services.restic-rest-server.serviceConfig.ExecReload =
  "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
```

and `systemctl reload restic-rest-server` as the documented rotation step.
Clients cannot revoke a key (`key remove` → 403), so the htpasswd line is the only
per-host kill switch: revoking a host = delete its line, reload, rotate the repo
password — which, being shared, means a re-`init` of every target or a full
`restic key` rotation across them. Plan it; do not improvise it in an incident.

### 3.6 Firewall on a target (h004 shown)

h004's firewall is one generated ssh rule plus `allowedTCPPorts = lib.mkForce [ ]`
(`hosts/h004/firewall.nix`). Add beside it:

```nix
# 7 addresses from firewallHighTrustIps { exclude = [ "o002" "h004" ]; }
iifname "tailscale0" ip saddr { 100.64.0.13, 100.64.0.4, 100.64.0.3, 100.64.0.18,
                               100.64.0.1, 100.64.0.2, 100.64.0.15 } tcp dport 8000
  accept comment "generated: restic rest-server, high-trust tailnet only"
```
derived from `fleetLib.firewallHighTrustIps { hosts = fleet.hosts; exclude = [
"o002" "h004" ]; }` — the same call the ssh rule uses, so the port opens to
exactly the hosts that can already ssh in (h001, h003, h005, juni, lio, oren,
gp3; o002 is excluded, and joe/i001/hass are low-trust and therefore absent).
Three caveats. `firewallHighTrustIps`
filters on `trust == "high"`, so a low-trust container host that gains backups
(joe, §6) is silently omitted and needs its IP added by hand. Because the socket
binds all addresses (§3.1), this rule is the entire access control: the LAN
interface must stay closed, which it does (`allowedTCPPorts` forced empty). Add
an assertion in the shape of `sshGuardAssertion` — non-empty and containing lio's
overlay IP — or a `fleet.nix` typo silently closes the target. A second target
must open the *same* port to the *same* set, so the allow-list is generated once
inside the `backupTarget` option rather than copied per host; a host that is
missing from one target's list fails at the network layer, which looks like a
restic error and reads like a bug.

### 3.7 `cnt move` restores its exact final source snapshot

`flakes/fleet-agent/internal/containers/move.go:394-406` already reads the fresh
stamp from the final backup taken immediately after stopping the source and
passes that exact snapshot ID to `restoreScript`; step 5 passes the same ID to
`restoreCheck` (`move.go:423-424`). Preserve that selection when adding targets:

- `backupCheckScript` — `/etc/fleet-containers/backup` exists **and**
  `command -v fleet-restic`. Unchanged; the marker is the host module's
  (`host-module.nix:1263`), not the repo's. Add one condition: the service
  resolves to a target (§3.3). A `none` service refuses here, before any
  container is stopped. Preflight both the source's final-backup target and the
  destination's first-backup target for availability (§3.3a).
- **Final backup stamp** — the backup taken after stopping the source records
  `target=<id>` and `repo=<url>` alongside `time`, `snapshot` and `host` in
  `/var/lib/fleet-containers/backup-last/<svc>`. Read that fresh stamp, not a
  subsequent policy lookup or a search for a newer `svc:<name>` snapshot.
- `restoreScript` — `fleet-restic restore <snapshot> --target "$tmp"` on the
  **destination host**, then the SQLite overlay from
  `/var/lib/fleet-backup/staging/<svc>/sqlite/<svc>`. It currently passes no
  `-r` (`move.go:188`), so the wrapper's default repository decides where it
  reads from. Pass the stamped repo explicitly:
  `fleet-restic -r <stamped-repo> restore <stamped-snapshotID> …`. This uses
  exactly the final backup's `(target, snapshotID)` pair, regardless of the
  destination's policy target; the wrapper honours `-r`/`--repo` (§3.5).
- `restoreCheck` — `restoreCheckScript` (`move.go:546`) restores with
  `--include '*.db' --include '*.sqlite' …` into a scratch dir and then runs
  `PRAGMA integrity_check` / `gzip -t` per file. For a move it must take the
  **same stamped repo and snapshot ID** as `restoreScript`, checking exactly
  that `(target, snapshotID)` pair rather than resolving `latest`. The standalone
  `restore-check` default (`move.go:633`) is not the move's selection rule.

Concurrent or clock-skewed snapshots could otherwise replace the source's final
state, so a move never chooses the newest snapshot across targets.

**Newest across targets is only for an explicit `cnt restore --latest`.** That
operation queries enabled targets for the `svc:<name>` series with
`restic snapshots --tag svc:<svc> --json` against each target URL and selects the
newest snapshot, recording its target. Reads use the destination host's htpasswd
user, valid at every target (§3.1); no extra daemon credential is needed.

A move refuses when either required backup target is unavailable or the source's
final backup cannot produce a fresh stamp; it does not fall back to an older
snapshot. Retention bounds explicit historical restores (§3.2), not selection of
the move's final source state.

No target is a move destination: a backup target needs no `fleet`/`cnt` binary.

### 3.8 fleet-agent vs the host module: keep the daemon out of the data path

- **Client side stays in `containers/host-module.nix`.** `fleet-backup` already
  runs hooks, SQLite `.backup`s, stamps and per-service flocks; routing the
  snapshot through the `fleet-agent` daemon would move a root-heavy, per-service
  job into a `DynamicUser` daemon for no gain, and `cnt move` would gain a
  network hop in its critical path. Client changes are exactly two: *resolve the
  target* (§3.3) and *delete the container job's prune* (§3.2) — the second is
  not cosmetic, because that prune is the only retention the container snapshots
  have today.
- **Target side lives in `flakes/fleet-agent/agent-module.nix`**, next to the
  existing `fleet-agent-{bcachefs,fail2ban,smart}` companion units, as a
  `backupTarget` option set that a capable host enables: phase 1 emits the
  rest-server config, the `RequiresMountsFor` bindings, the allow-list assertion;
  phase 2 the registration unit; phase 3 the prune timer (it must land with the
  client cutover, §2.2); phase 5 the copier. One home, so nothing migrates between
  files later, and h004's `flake.nix` gains one line instead of a module.
- **rest-server is the data plane; the daemon never touches snapshot bytes.** No
  backup payload, restore stream or `restic` invocation goes through
  `fleet-agent`. Its only role is `cnt move` orchestration (§3.7): it reads the
  final source backup's target, repo and snapshot ID from the fresh stamp, then
  the restore's bytes flow rest-server → `fleet-restic` → disk exactly as today.
  That is also why routes, quotas and the append-only ACL stay in the restic REST
  protocol instead of growing an RPC surface — a second data path would have to
  re-earn the same authentication, dedup and restore semantics and would be a
  worse copy of rest-server.
- The policy API (§3.3) is the only fleet-edge state here; its consumers are the
  clients (resolution), the copier (opt-ins) and `cnt move` (target preflights).

## 4. Migration off the current B2 repo

Ordered so nothing is lost and the window with two writers is short:

1. **Freeze the container writers.** Stop `fleet-backup.timer` on h001, lio and
   h003 and mask `fleet-backup.service` for the duration, so a manual `start`
   cannot land a run mid-migration. Unmask in the same session that flips each
   host. h001's `restic-backups-h001.timer` keeps running throughout: it writes
   the `h001` tag to B2 and is not part of this migration (§3.2).
2. **Keep the B2 repo read-only** — `ROUTING-PLAN.md` §9.3 break-glass depends on
   it, and §9.3's independent copy is unrelated. Do not delete it in this plan.
3. **Create the target.** `install -d -m700 -o restic -g restic
   /data/backups/restic` (do not rely on `createHome`: `/data` mounts after the
   activation script, §3.1), write `.htpasswd` with `htpasswd -B` one line per
  host, then as `restic`: `restic init -r /data/backups/restic/fleet`,
  optionally `--copy-chunker-params --from-repo <B2>` so the two repos share a
  chunker. Then let the host register itself (`systemctl start
  fleet-backup-target-register`) and set the `default` policy row's `target` to
  it in the UI — until that row exists, no client can resolve a target and the
  phase-3 cutover has nowhere to go.
4. **Seed history** (optional, no new uploads): `restic copy --from-repo <B2>
   --from-password-file <B2 pw> --tag svc:<svc>` per service, from any host with
   both credentials. Measured: copies only the named tag and preserves dedup
   (62 M → 62 M). Without it, each service's series restarts at the cutover; with
   it, retention and `restore-check latest` have history on day one.
5. **First full run on h001** (43 G, 18 services), then
   `cnt restore-check forgejo` (3 PG dumps) and `cnt restore-check puzzles`
   (2 SQLite). Then lio and h003 — their `/srv/containers` hold 20 K and 0
   bytes, so their first runs cost nothing.
6. **Move retention to the target**, in the same change that removes the
   container job's client-side `forget` (`host-module.nix:399-402`). That line is
   the only thing bounding the container snapshots today (§2.2); pointed at an
   append-only target it becomes a 403-per-snapshot no-op, so between removing it
   and enabling the target's pruner nothing bounds the repo. h001's media
   `pruneOpts` are **not** part of this: that job keeps writing to S3, where
   deletion works, until §6 decides otherwise.
7. **Narrow the B2 write key.** lio and h003 no longer need `restic_h001_env…` at
   all; h001 keeps it for the media job, so a write key legitimately survives
   there. "No container host holds B2 credentials" is only true if §6 moves the
   media job too — this plan does not assume that.
8. **Enable the offsite copier** for the services opted in, after the local copy
   has proven itself for a week.

Rollback at any step before 7 is "put the old env file back": hosts keep their
stamps, snapshots, and `fleet-restic`. Once a service has written to two targets
(§3.3a) rollback means re-pointing the policy, not moving bytes — which is the
whole point of keeping the old target readable.

## 5. Phases

| Phase | Scope | Files | Risk |
|---|---|---|---|
| **1** | h004 becomes a backup target: `backupTarget` option (in `agent-module.nix`) emitting `services.restic.server` (port 8000, `dataDir=/data/backups/restic`, `appendOnly`, `ExecReload`, `RequiresMountsFor=/data`), `/data/backups/restic` 0700 bootstrap, firewall rule for the container hosts + allow-list assertion, eval test for the allow-list | `flakes/fleet-agent/agent-module.nix`, `hosts/h004/{firewall.nix,flake.nix}`, new `containers/tests/backup-plan.nix` | Low: nothing writes to it yet |
| **2** | Target + policy registry: `internal/backup` with target registration (`POST /api/backup/targets/<id>`) and policy rows (`target`, `offsite`, `default`), atomic state, audit, a target-aware `GET /api/backup`, the registration unit that POSTs the record from the target, one more listener entry in `main.go`, h005 `/api/backup` nginx location, dashboard target column + form, a `cnt backup-policy` subcommand modelled on `cmdExpose` (`edgeapi.go`) | `flakes/fleet-edge/internal/backup/{backup.go,backup_test.go}`, `flakes/fleet-edge/main.go`, `flakes/fleet-edge/internal/server/`, `hosts/h005/fleet-edge.nix`, `flakes/fleet-agent/agent-module.nix`, `flakes/fleet-agent/internal/containers/{main.go,backup_policy.go}` | Low: no data path |
| **3** | Client cutover *and* the retention handover in one deploy: the target's local prune unit + timer (`restic forget --prune` on the filesystem path, §3.2) goes live, then the container client's `forget` (`host-module.nix:399-402`) is deleted, the static `containers.backup.repository` option is removed, and clients resolve the target via authenticated `GET /api/backup` (with a `target.json` cache); lio and h003 move to their new credentials-only `restic_rest_<host>_<date>` key (§3.5) | `flakes/fleet-agent/agent-module.nix` (prune unit), `containers/host-module.nix` (resolver + `fleet-restic` wrapper + options), `containers/sec/registry.nix`, `hosts/{lio,h003}/{sec-agent.nix,flake.nix}`, `hosts/h003/containers.nix`, `hosts/lio/flake.nix` | High: the container snapshots' only working retention moves from the clients to the target in this step, so do both halves together or the repo goes unbounded |
| **4** | h001 cutover: same env change for the container job, first full run, restore checks. The media job's `pruneOpts` are untouched — it still writes to S3, where deletion works (§3.2) | `hosts/h001/{floating-containers.nix,sec-agent.nix}` | Medium: 43 G re-read into a new repo |
| **5** | Target copier: `offsite`-driven unit (one `restic copy` per tag), `restic_offsite_<date>` secret scoped to the target | `flakes/fleet-agent/agent-module.nix`, `containers/sec/registry.nix`, `hosts/h004/flake.nix` | High: the first thing that spends money, and the first copy of data to a second place that is not a client |
| **6** | Docs: `ROUTING-PLAN.md` §9.1/§9.3, `containers/README.md` §"Nightly restic" (its enable list is stale: lio and h003 are on, joe is off), `ideas/restic_backups.md` (it records the opposite decision: "Direct to Backblaze B2 … the earlier local `rest-server` design was dropped"), `ideas/h004_erasure.md` (its EC row asserts "critical fleet backups live on Backblaze B2, not `h004`"), `hosts/h004/readme.md` (every line of it is currently corrupted with an NFS-table prefix; fix or rewrite it here) | docs | Low |

Each phase is one deployable cutover: phase *n* leaves the tree working with
every caller migrated. Phase 1 stands a target up, 2 makes it selectable, 3 moves
the writers *and* the retention, 4 finishes h001, 5 spends money, 6 removes the
old story. Nothing in a later phase has to remember to delete a shim from an
earlier one. A change of target after phase 3 is not a phase at all — it is a UI
edit.

What each phase is verified by, in the style of `containers/tests/edge-vhosts.nix`
(`nix eval --impure --expr 'import ./containers/tests/backup-plan.nix'`, a list
of `{ ok, msg }` with `throw` on the first failure):

| Phase | Verification |
|---|---|
| 1 | `backup-plan.nix` asserts the backup allow-list is non-empty, contains lio's overlay IP, excludes o002 and h004, and equals the ssh list minus the port; live: `restic init` over `rest:http://100.64.0.17:8000/fleet/` from lio succeeds, the same from a non-listed host times out at the firewall, and `DELETE /fleet/snapshots/<id>` returns 403 |
| 2 | `go test ./internal/backup/` (target upsert from wrong peer → 403, stale target not selectable, `PUT` to unknown/disabled target → 409, `revision` conflict → 409, audit line, unauthenticated GET → 401, `PUT` by a reader → 403); `cnt backup-policy list` shows the resolved view; a second target registration then a change of a service's target and back |
| 3 | pruner `--dry-run` first: `restic forget --prune --tag fleet --group-by tags <keep>` on the target's filesystem path reports the same keep-set the clients report today (`keep 7 daily, 5 weekly, 12 monthly, 3 yearly`), then for real and `restic check` is clean; `cnt restore-check <svc>` for one service on lio and on h003 after their first run; `sudo fleet-restic snapshots --tag fleet` shows history under the policy target; `systemctl start fleet-backup` exits 0 **and its log has no `Applying Policy` line** — that absence is the evidence the client prune is gone; stop the API and confirm the cached `target.json` keeps the run working, delete the cache and confirm it fails rather than guesses |
| 4 | h001: full run, then `cnt restore-check forgejo` (3 PG dumps) and `cnt restore-check puzzles` (2 SQLite), then a real `cnt move` of `hello-nixos` exercising both preflights (§3.7) after the repository change; the media job's `restic-backups-h001` log still shows its own `Applying Policy` line — evidence it was left alone |
| 5 | copier leaves `lastCopied` fresh and a B2 `restic snapshots --tag svc:<n>` shows the new ids; a service with `offsite: false` gains no B2 snapshot that night |
| 6 | docs only: `grep -rn "restic_h001_env" containers/ hosts/ ideas/` no longer claims lio or h003 hold B2 credentials, and h001's remaining reference says *media job only* |

## 6. Open questions

- **Does h001's 639 G immich job move to h004 at all?** `--tag h001` is 484.9
  GiB of the 491.7 stored — 98 % of the bill. Moving it makes B2 optional
  everywhere (≈ $0 offsite) and puts media on the same host as its backup;
  leaving it keeps an offsite copy of the only irreplaceable data in the fleet,
  for $3.34/mo. Not a technical call.
- **Several targets, or one?** The model supports *n* targets and the policy
  picks one; h004 is the only host with the capacity today (§2.3), so the second
  target is hypothetical. It is worth having the mechanism anyway, because it is
  what makes draining h004 for a rebuild a UI change rather than a re-deploy of
  every client's env file — but do not invent a second one to justify it.
- **Shared repo per target vs per-host repos.** Chosen: one repo per target,
  shared by every host that writes there (history follows moves, dedup works;
  `cnt move` explicitly passes the final backup's stamped repo, §3.7) at the cost
  of every container host reading every other's snapshots on the same target —
  the same trust tier they already share. Revisit if a low-trust host is ever
  added.
- **Retention split.** One keep-set for all `fleet` tags per target, and a
  separate one for the B2 copy (the offsite copy should be at least as deep as
  the local one, or an offsite restore is a gamble). Numbers unset; the current
  `7/5/12/3` daily/weekly/monthly/yearly is a reasonable start.
- **`joe`**: low-trust today and the only container host with no backup. A
  rest-server user on a target is far safer than the B2 key it would have needed,
  but `localai` also needs `/srv/containers/localai/{models,backends}` excluded
  first, and `firewallHighTrustIps` filters on `trust == "high"` so a low-trust
  host must be added to the target's allow-list by hand (§3.6). Deferred until it
  should be a move target.
- **What does `none` do to an existing series?** Nothing, deliberately: it stops
  new snapshots and leaves the old series to age out under the target's retention,
  and `cnt move` refuses until the service is pointed at a target again. That is
  the only behaviour that does not make a selectable UI value silently delete
  data, so the doc states it rather than asking; the option text says it too.
- **Quota per user.** `--max-size` is checked before writes and returns `507
  Insufficient Storage` (verified with a 1 MB cap: `unable to create lock in
  backend`), so a tight value bricks a host's backups. If a quota is wanted it
  must be generous and monitored, not a guard rail.
- **What if h004 is down at 03:00?** The unit has
  `ConditionPathExists = bcfg.environmentFile` (`host-module.nix:413`) plus
  `Persistent = true` / `RandomizedDelaySec = 15m` (`host-module.nix:1281-1282`),
  so the run is skipped and retried rather than failing loudly; the dashboard's
  stale flag is the only signal, and there is no alert (`ROUTING-PLAN.md` §9.1
  open items). This plan does not add one, but it makes the *target* a second
  thing whose availability matters, so the alerting work should cover the
  target-side prune and copy units and h004's `:8000` too.
- **Does the h004 repo itself need an offsite copy of the repo metadata?** The
  B2 copy is per-service and content-addressed; the local repo's `config`,
  `keys` and `index` are not in it. Postgres dumps and SQLite copies restore
  without them, but the copies are keyed to the repo password — the password in
  the password manager (§9.3) plus the bucket key is the minimum break-glass
  set, and it changes when the per-host htpasswd users do.
- **Unverified**: the h004 deployment itself — the socket-activated listener
  under the module's `PrivateNetwork`/`PrivateUsers`/`RestrictAddressFamilies =
  "none"` hardening, and the firewall rule as written — has only been tested on
  loopback fixtures with `systemd-socket-activate`, not on h004. Phase 1's whole
  job is to prove it there before any host's data depends on it.
