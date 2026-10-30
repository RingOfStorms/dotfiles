# Container backups: local backup nodes, one repo per service, and no B2 key on any client

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
node, and know nothing about B2.** Which hosts *can* take backups is opted in per
host (`backupNode`, because it needs the disk, the server and a bucket key);
which one a given service *uses* is runtime state in the fleet-edge UI (a default
plus per-service overrides), and `offsite` is a second per-service flag because it
costs money. Clients resolve the node at backup time and build the repository URL
from it — the secret carries only credentials, so changing a node is a UI edit,
not a re-deploy. The transport stays the restic REST protocol, so snapshot bytes
never pass through `fleet-agent`, and `fleet-restic`, the stamp files and
`cnt move` keep working.

Isolation is part of the node, not an afterthought: **one repository per backup
subject** (a service, or a host-only series), reachable only by that subject's
credential (§3.1), and **only a backup node may hold a B2 key** — the offsite copy
is made by the node itself, never by a client (§3.4), and h004 is the first such
node rather than the only possible one (§3.3c).

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
- **h004 has no containers module**, so it runs no services and is not a `cnt
  move` destination; it also gets no `fleet-backup` today.

So the copier is new work, and phases 1–4 change only *where* container hosts
write. One requirement refinement is worth recording: the node is chosen at
runtime, which means it cannot be baked into a secret — a `RESTIC_REPOSITORY`
line on disk is exactly what would make the choice immutable (§3.5).

## 2. Assessment

### 2.1 One key, fleet-wide access: the isolation failure

The env file is a single secret, granted by role, hydrating a B2 bucket key plus
the repo password. A compromised h001, lio or h003 (or anyone who reads
`/var/lib/secrets_manager_hydrated/restic_h001_env_2026-10-01`, mode `-r--------`
root) can read and delete the fleet's entire history and every other host's
snapshots. Nothing in the design limits blast radius below "any high-trust host".
Grants are whole-key: there is no field-level grant to hand out "password but no
bucket key".

The same failure survives a change of address. Point three hosts at one
rest-server repo, one htpasswd user each, one repo password, and every host still
reads and writes every other host's snapshots: rest-server's append-only mode
stops *deletion*, but nothing stops a host from listing, reading or appending to
another service's series. "The container hosts already share a trust tier" is true
and is not the requirement: a compromised **app container** — the thing that
handles untrusted input all day — must not be able to reach another service's
backup at all, and a host's backup credential that leaks must be worth exactly one
backup series, not the fleet's.

That is the constraint the rest of §3 is built around: **one repository per
backup subject, reachable by exactly one credential, append-only, and pruned
only by the node that holds it.**

The cutover must also revoke the old fleet-wide credential (§4 step 7), not just
remove its consumers: after the node's **new, separate prefix-scoped B2 key**
works, remove the `device_high_trust` grant (or the secret entry), deploy `sec`,
delete every former consumer's hydrated copy, and revoke the old B2 application
key in Backblaze. Otherwise any high-trust host can still fetch the old env and
bypass the new per-subject boundary. That old *key* is not the media repo's
*password*, and the two are treated differently: the key goes, while the password
stays valid on the node — the offsite copy is encrypted with it (§3.4), so
rotating it would strand 484.9 GiB in B2 that nothing could open.

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
rest-server 0.14.0.** Measured on loopback fixtures, not yet on h004. The repo
path is now per subject (§3.1), so the table names two paths: `<own>` is the
caller's own repo, `<other>` a different subject's.

| Request | Result |
|---|---|
| `DELETE /<own>/locks/<id>` | **200** (lock breaking is allowed) |
| `DELETE /<own>/snapshots/<id>`, `/index/<id>`, `POST` an existing snapshot id | **403** |
| no auth / unknown user | 401 |
| `restic forget --tag svc:x --keep-last 1` on `<own>` | `Remove(...) failed: 403` **per snapshot, exit 0** |
| `restic prune` with nothing unreferenced | `unused size after prune: 0 B`, **exit 0** |
| `restic prune` with garbage | `Remove(<index/…>) failed: 403`, `Fatal`, **exit 1**; repo stays `check`-clean |
| `restic key add` / `key remove` on `<own>` | add works; remove → 403 (a client cannot revoke a key) |
| any method on `/<other>/…` as a valid but different user | **401**, message `Is there a repository at the following location?` — indistinguishable from "no such repo" |
| `/<own>/<child>/…` | allowed (a path under the username is the user's own) |

Consequences, and this is why the *container* client prune must be **deleted**,
not left in place:

- **Over append-only it becomes a silent no-op.** `host-module.nix:406-409` runs
  `restic forget --retry-lock 2h --prune --tag fleet --group-by tags …` on every
  full run. Against a rest-server it prints a 403 per snapshot and exits 0, so
  retention would stop the day the node changes and nothing would report it.
  Today that line is the only thing bounding the container snapshots, which makes
  the cutover a change to retention and not just a change of address — the node's
  pruner (§3.2) must exist first, in the same deploy.
- **h001's media `pruneOpts` are a different case** and stay until the media job
  itself moves (§3.2, §4 step 6): it writes to S3, where deletion works.
- Monitoring must not trust the exit code of `forget`. The node's pruner is a
  local `restic forget --prune` against the **filesystem path** (verified working:
  `2 / 2 files deleted`), and it must fail the unit when the repo is broken. The
  same unit's B2 pass is the only deletion the design performs off the node's own
  disk, which is why it takes the bucket key (§3.4).
- Lock deletion being allowed is what keeps `--retry-lock 2h` and `cnt move`
  working; a crashed client leaves a lock that ages out.
- Append-only is a *second* line, not the first: it stops the owner of a repo from
  destroying its own history, and `--private-repos` (§3.1) is what stops it
  reaching anyone else's. Neither replaces pruning on the node, which is the only
  place deletion is supposed to happen.
- Snapshot counts are only evidence of retention if you know which regime produced
  them. The 164-snapshot figure in §2.1 is a pruned repo under a 7/5/12/3
  keep-set, not an unpruned one.

### 2.3 One node today: h004, and that is a single point of failure

h004 is the only host with capacity for it today: `/data` is 51 T, 25 T used,
**26 T free**, and a full fleet copy is ~31 GiB compressed. Its pool is bcachefs
with replication 2 (data and btree `Required/total 1/2`, durability 2), so the
repo survives one disk failure. `/data/backups` is additionally a subvolume, mode
0700, so the NFS export of `/data/nixarr` cannot reach it (`subtree_check`, see
`hosts/h004/nfs-data.nix` C2 header).

One node = single point of failure. If the one enabled node is down at 03:00 the
backup is skipped (`ConditionPathExists` + `Persistent=true` +
`RandomizedDelaySec=15m` retries it), and a `cnt move` needs the node holding the
snapshot reachable when it runs. The design allows *n* nodes (§3.3, §3.3c) and the
policy picks one, but h004 is the only host with the capacity for it today, so
the trade is real: every repo — and with §3.1's per-subject split, every service's
whole history — lives on one machine. The offsite copy is what protects against
losing that host, which makes §2.5 matter more, not less. A second node on the
same physical machine would be worse than useless — it would look like redundancy.
What the design buys is that adding one is a *host* change (`backupNode = true`),
not a redesign: no client knows a node's name, so a second node is a Nix deploy
plus a UI edit, and the answer to "the only node is down" exists in the design
even though it is not available in the hardware.

### 2.4 Encryption at rest: restic's own, and no second layer

**Decided: the backup directory gets no additional encryption.** `/data` is not
encrypted (`bcachefs show-super /dev/sdb` has no encryption field; only h004's
*root* is, impermanence + USB key, `hosts/h004/flake.nix:52-63`) and `/data`
itself is `drwxrwxrwx`. A LUKS or per-directory layer in front of
`/data/backups` would add a key that has to be present at every boot and every
restore, for a threat — someone with physical access to h004's disks — that the
accepted model already concedes.

The boundary is therefore three things, and nothing else:

1. **restic AES-256**, per repo, with a **distinct password per repo** (§3.5). A
   stolen disk, a wrong htpasswd user, or one leaked repo password yields that one
   subject's ciphertext and nothing else.
2. **Filesystem**: `/data/backups` is 0700 and each repo dir is `restic:restic`
   0700, so a non-root process on the node cannot read the files at all.
3. **The password store**: repo passwords live in `sec` (§3.5), not on the node.

Consequently **root on the node reads everything on the node** — including every
service's repo after supplying the passwords it can hydrate — and that is
accepted, not overlooked: the node is the party that must prune, copy and
restore, and pretending otherwise would only add ceremony. The practical
consequence is that a node's root is in the same trust tier as the backup data it
holds; it must never hold an untrusted workload, which is why h004 has no
containers module (§1).

### 2.5 Cost: h001's media is 98 % of the B2 bill

| Slice | Stored |
|---|---|
| Whole repo `7f023d4a` (164 snapshots) | 491.7 GiB |
| `--tag fleet` (container services) | **31.2 GiB** |
| `--tag h001` (10 snapshots: immich media) | **484.9 GiB** |

At B2's $6.95/TB/mo that is **$3.34/mo** today, of which **$0.21/mo** is the
fleet's container data. The container copy is a rounding error; the whole bill is
h001's 639 G immich media. Splitting that 31.2 GiB across one B2 repo per subject
*does* cost one real thing on the day it happens: each subject's B2 repo starts
empty, so its first copy uploads that subject's data in full — roughly the
31.2 GiB total, one upload of it, not a metadata-only pointer write. Chunker
seeding does not avoid that: `--copy-chunker-params` shares chunk *boundaries*
between repos, but an empty destination holds no blobs to dedup against, so the
first copy writes all of them (measured: 20,005,756 bytes of source copied into
an empty repo whose chunker was copied from that source produced 20,005,811
bytes of destination — a full upload). After that first pass the copy is
incremental and cheap, because the destination now holds the blobs; and because
an ID matches only within the repo that stores it, the permanent loss is
cross-subject dedup, which the local side already gave up (§3.1, §3.4).

**Decided: the media job moves to h004**, so B2's only remaining consumer is the
node's copier (§3.4) and the container set. That is what makes "a B2 key held only
by backup nodes" achievable — the constraint was never the media's size, it was
that h001 had to hold the bucket key to reach it. **The media stays offsite**, and
it stays in the repo it is already in: `7f023d4a` becomes the media's offsite repo
rather than a legacy repo to be replaced (§3.4). That costs $3.34/mo at today's
size and buys an offsite copy of the only irreplaceable data in the fleet, for no
new bytes and no re-upload — the ~1 KB figure is this case specifically, and it
needs both conditions: the destination already holds the blobs *and* the local
repo was seeded with the destination's chunker, so a copy back into `7f023d4a` is
index and metadata only (§3.4 quotes both measurements). The container side is
the opposite case and costs one full upload of ~31 GiB the first time (§4 step 4),
after which it settles to storage only, ~$0.21/mo. Total B2 ≈ **$3.55/mo**,
unchanged in substance from today; the one-time upload is bandwidth, not money.
The alternative — a fresh media repo, or no media copy — is rejected in §3.4's
table: the fresh repo re-uploads 484.9 GiB, and dropping the copy leaves a 639 G
single-copy dataset that is the whole reason the fleet backs up at all.

## 3. Recommendation

### 3.1 Transport: one append-only private repo per subject

```nix
# what h004's `backupNode = true` emits (agent-module.nix, §3.8, §3.3c)
services.restic.server = {
  enable = true;
  listenAddress = "8000";        # bare port: the module asserts this (socket activation)
  dataDir = "/data/backups/restic";
  appendOnly = true;
  privateRepos = true;
};
```

- `listenAddress` must be a **bare port**; the module asserts
  `lib.substring 0 1 cfg.listenAddress != ":"` and the socket unit takes
  `[ "8000" ]`, i.e. the socket listens on all addresses and **the firewall is
  the ACL** (§3.6). Restricting the bind address is not expressible through the
  module.
- **`privateRepos` is the isolation mechanism**, and the boundary is
  *path-component* based, not prefix based. rest-server admits a request only if
  the URL path either **is** a `<username>` component or lies **under** one.
  Measured on loopback fixtures (rest-server 0.14.0):

  | User | Path | Result |
  |---|---|---|
  | `svc-puzzles` | `/svc-puzzles/extra/config` | 404 (path allowed; repo absent) |
  | `svc-puzzles` | `/svc-puzzles-x/config` | **401** |
  | `svc-puzzles` | `/nonuser/config` | **401** |
  | `svc-sec` | `/svc-secrets/config` | **401** (a repo that exists, as its owner: 200) |
  | `svc` | `/svc-secrets/config` | **401** |
  | `host-h001` | `/host-h0010/config` | **401** |
  | `svc-secrets` | `/svc/config`, `/config` | **401** (ancestors are not yours) |
  | `svc-secrets` | `/svc-secrets/a/b/config` | 404 (children are) |
  | `svc-secrets` | `//svc-secrets/config` | 307 (trailing-slash normalisation, then allowed) |
  | `svc-secrets` | `/svc-secrets/../svc/config` | **401** |

  So: **repo path = username = subject**, exactly one component, and no two
  subjects may have names where one is a prefix of the other in a way that
  matters (`svc-sec` cannot reach `svc-secrets` — measured, 401, against a repo
  that exists and returns 200 to its owner). Do not create repos at deeper paths
  and do not put two subjects under one component: a shared parent would let every
  sibling under it through on a plain username match.
- **Naming**: `svc-<name>` for a service, `host-<hostname>` for a host job. The
  colon in `svc:puzzles` is illegal in a username (`htpasswd` refuses
  `username contains illegal character ':'`), so the tag spelling and the repo
  spelling differ; the tags stay as they are for snapshot naming.
  Each subject's URL is `rest:http://100.64.0.17:8000/<subject>/` — that is what
  the node's record publishes (§3.3) plus the subject path the client appends.
- **A repo belongs to exactly one subject, and one subject may have several
  repos** (a service's own series, a host's media series). That is the point of
  the split: `svc-puzzles`' credential reaches `svc-puzzles` and nothing else, so
  an app container that exfiltrates its backup credential gets one series, and a
  wrong `-r` is a 401 rather than a silent read of a neighbour's data. The same
  holds at B2: one repo, one password, one bucket prefix per subject (§3.4).
- **What this costs**: no cross-host or cross-subject dedup, locally or at B2
  (dedup only ever matches blobs the *same* repo already stores — equal IDs in
  two repos are two stored copies, §3.4 quotes the number), plus one full first
  upload per empty repo — the container data is 31.2 GiB fleet-wide, so that is
  ~31 GiB moved once, after which the duplication costs ~$0.21/mo of storage. And
  no `latest` across writers; `cnt move`'s selection was never "newest across
  hosts" (§3.7). What it removes is the `--tag svc:<name>` history-follows-the-
  service property: a service's series now lives in `svc-<name>` and stays there
  regardless of which host runs it. A move therefore reads the *same repo* from
  the destination, which is why `cnt move` needs the stamped repo and not a tag
  search.
- **`/data` is `nofail`** (`hosts/h004/data-pool.nix:50`), so a boot with a
  missing pool continues and a rest-server started anyway would create
  `/data/backups/restic` **on the root filesystem** and accept every subject's
  backups there. Set
  `systemd.services.restic-rest-server.serviceConfig.RequiresMountsFor = [
  "/data" ]` (and the same on the prune and copy units, which otherwise prune a
  directory that is not the pool). `ConditionPathIsMountPoint=/data` is the
  blunt version if the unit should refuse rather than wait.
- **Nothing creates a repository**: the module has no `initialize`, so each
  `restic init -r /data/backups/restic/<subject>` is a one-time step in phase 1/3,
  run as `restic` so the files are owned by the service user. The directory below
  `dataDir` is created by `init` itself (mode 0700, measured); the parent is
  `install -d -m700 -o restic -g restic /data/backups/restic`. The module
  pre-creates an **empty** `.htpasswd` when `privateRepos` is set; the node fills
  it from the subject secrets at every start (§3.5a), not by hand, and the file
  the server actually reads lives in `/run` because `htpasswd-file` points there
  (§3.5a) — the `${dataDir}` stub is never opened. `createHome` cannot be relied
  on for the directory because the `users` activation script runs long before
  `/data` exists.
- **`.htpasswd` is read once at process start** (§3.5): the server needs an
  `ExecReload`, which the module does not have, and the file must be re-rendered
  before that SIGHUP — §3.5a wires both with `reloadPropagatedFrom`.

### 3.2 Who prunes: the node, per repo, from the policy's preset

A root unit on the node loops over the repos it holds, and over the B2 repos it
copies into:

```sh
# local: every repo in the data dir, by its filesystem path
for repo in /data/backups/restic/*/; do
  subject=$(basename "$repo"); preset=$(policy_preset local "$subject")
  RESTIC_PASSWORD_FILE=/var/lib/fleet-backup/passwords/"$subject" \
  RESTIC_REPOSITORY=${repo%/} restic forget --prune --group-by '' $(preset_args $preset)
done
# remote: the same, one B2 repo per subject, its own password, whole repo
for subject in $(policy_offsite_subjects); do
  preset=$(policy_preset b2 "$subject")
  RESTIC_PASSWORD_FILE=/var/lib/fleet-backup/b2-passwords/"$subject" \
  RESTIC_REPOSITORY=$(b2_repo_url "$subject") restic forget --prune --group-by '' \
    $(preset_args $preset) $(b2_tag_scope "$subject")
done
```

`b2_repo_url` is per subject — `b2:<bucket>:svc-<name>`, the same name as the
local repo (§3.4) — so a prune addresses exactly one service's offsite history
and cannot reach another's. There is no shared B2 repo for containers: with one,
this loop and *clear* (§3.3b) would both be whole-repo operations against
everybody's data, and a tag filter is not a boundary anyone can enforce inside a
repo.

**Per repo, no tags — except for the media's B2 repo**, where
`b2_tag_scope host-h001` emits `--tag h001` because that series lives inside
`7f023d4a` alongside the pre-cutover history (§3.4); for every other subject it
emits nothing and the repo is pruned whole. That is the single exception, and it
is why *clear* for the media is also `--tag h001`-scoped and can never remove
`7f023d4a` itself (§3.3b). `preset_args` maps the preset name to its `--keep-*`
arguments from §3.3b's table, which the node also publishes in its node record,
so the number the UI shows and the number the pruner runs are the same number. The
preset is resolved **per run** from the policy (the node re-fetches it, §3.4), so
changing a service's retention in the UI is a UI edit, not a deploy.

The same `preset_args b2 <subject>` is what the completeness gate runs, as a
`--dry-run` against the **local** repo, to decide which local snapshots B2 is
supposed to hold (§3.4). That reuse is deliberate: it is the only way "B2 is
complete" and "B2's retention" cannot disagree, since both are computed from the
one resolved preset per run. It also means a `retentionB2` shallower than
`retentionLocal` is a supported configuration rather than a contradiction — the
gate expects the shallower keep-set, so pruning at B2 below local's horizon never
looks like data loss.

**`--group-by ''` is required, not cosmetic.** `forget` groups by `host,paths` by
default, and that grouping is per *writer*: measured on a loopback repo holding
18 services it produced **4 separate policy groups** and removed nothing at
`--keep-last 1`, while `--group-by ''` collapsed them to one group and removed 3
of 4 snapshots. With one repo per subject there is one writer per repo, so the
flag is usually a no-op — it stays because `cnt move` and a re-`init`ed host can
put two `paths` sets in one subject's repo, and the keep-set must still mean "this
subject's history", not "each writer's history". Getting it wrong there is the
silent failure where a prune removes nothing and looks healthy.

The local `RESTIC_REPOSITORY` is **a path, not the URL**. Append-only is enforced
by the REST server only; a local root process with read/write on the files is the
admin. The B2 pass has to go through the URL, because there is no other way to
reach it — and that is the only place the node's bucket key is used for
*deletion*, which is why that key carries a **prefix** grant (over `svc-*` and
`7f023d4a`, not the whole bucket) and is held by nodes only (§4 step 7, §3.3c).
Neither pass exists on any client.

Two client prunes exist today and they are not the same thing:

- `host-module.nix:406-409` — the container job's `forget --tag fleet`. This is
  the one the node's pruner replaces, and the one that must be **deleted in the
  same deploy** that points clients at the node. Left in place it becomes
  per-snapshot 403s with exit 0, so retention would vanish silently (§2.2).
- `hosts/h001/mods/restic-backup.nix:56-66` — h001's media job, tagged `--tag
  h001`, writing to B2 over S3. S3 is not append-only, so that prune *works*. It
  disappears with the job itself when the writer moves to h004 (§4 step 6); its
  `7/5/12/3` keep-set becomes the `host-h001` row's `long` preset, for both local
  and B2 (§4 step 6), so retention is not interrupted by the move.

Clients keep `--retry-lock 2h` either way (locks are deletable, so a crashed host
does not wedge the repo).

Retention lives in one place — the node's own module, emitted by `backupNode` —
and its *values* come from the policy per service, because each subject is a repo
with its own row (§3.3b). Two layers, stated once: the node owns the preset
*table* (so a keep-set is a reviewed number, not a free-text field, and the UI
cannot offer one the pruner will not run), the policy owns the *choice* per
service and per copy. Two nodes means two pruners with the same table, which is a
duplication worth having: a node must be able to prune alone, because it may be
the only one left holding a series.

### 3.3 Policy: a node is a capability record, the choice is runtime state

Two different things, kept apart:

**Capability (declared in Nix, one record per host).** A host opts in as a backup
node in its own config (`backupNode = true`, §3.3c) — rest-server config, port,
repo path, firewall rule, prune and copier units — and that module also registers
a *node record* with fleet-edge at boot:

| Field | Example | Meaning |
|---|---|---|
| `id` | `h004` | Stable key the policy refers to; the hostname |
| `url` | `rest:http://100.64.0.17:8000/` | Base URL; the client appends `<subject>/` (§3.1) |
| `offsite` | `true` | This node runs a copier and holds a B2 key, so services here can opt in (§3.4) |
| `presets` | `{short = […]; standard = […]; long = […];}` | The keep-sets this node's pruner can run (§3.2, §3.3b) |
| `stats` | `{svc-puzzles = {localBytes, b2Bytes, lastBackup, lastCopied};…, unassociatedBytes}` | Last measurement pass (§3.3b); `unassociatedBytes` is what B2 holds that no subject repo accounts for, the number §4 step 9's gate reads |
| `enabled` | `true` | Operator switch: drain and hide a node without undeploying the server |
| `declaredBy` | `100.64.0.17` | Record is only accepted from that peer |

Registration is a POST from the host itself through the existing `fleet-edge`
plumbing, not a hand-edited JSON file: it is derived config and must vanish when
the host stops declaring itself. A timer — `fleet-backup-node-register.timer`
driving the matching `.service` oneshot — re-registers every few minutes and
carries the stats, and a record `declaredBy` a peer that has not re-registered
within ~1 h is rendered *stale* and is not selectable for new writes. Without the
heartbeat a node that was decommissioned months ago would stay selectable forever,
which is exactly the failure the UI must not offer; the same staleness is what
makes a silent node's sizes render as stale rather than as zero (§3.3b).

**Policy (runtime state, edited in the fleet-edge UI).** One row per service, plus
a fleet `default` row. The fields are §3.3b's table; the two that decide
behaviour are:

- `target` — a node `id` from the enabled, non-stale set, **or the literal
  `none`** meaning "not backed up" (*turn off* in the UI, §3.3b). Modelling it as
  a value of `target` rather than a third flag keeps `none` and "nothing
  resolved" from disagreeing, and gives the UI one thing to display. `cnt move`
  refuses such a service (§3.7); that refusal is what keeps the value honest.
- `offsite` — `true|false`, the B2 checkbox; refused at `PUT` time if the chosen
  node advertises no copier, so a node change cannot silently drop the cost
  flag.

Where it lives: `flakes/fleet-edge/internal/backup`, a new package beside
`overrides` and `placements`, on the same loopback listener:

- 0600 files in the existing `StateDirectory`: `backup-targets.json`
  (registrations, replaced on each POST) and `backup.json` (policy rows plus the
  `default` row), atomic write under one mutex, audit log `backup-audit.log`
  (one JSON line per request, refusals and *clear* requests included) — the shape
  of `placements.json`.
- Routes on the `:443` nginx vhost (`hosts/h005/fleet-edge.nix:213-240` shape):
  `POST /api/backup/targets/<id>` (registration, stats included; the caller's
  peer IP must equal the record's), `GET /api/backup` (the resolved view: nodes
  + policy), `PUT /api/backup/<svc|default>` (`{target, offsite, retentionLocal,
  retentionB2, revision}`). The mux entry is
  `{"/internal/backup.json", "/api/backup", bk.Handler()}` in
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
  `GET` needs any container host's machine token; `POST` needs the node's own.
  `PUT` naming an unknown, disabled or stale node, or a preset name the node did
  not publish, is a 409.
- **The destructive actions are not `PUT`s.** *Clear* (§3.3b) is
  `POST /api/backup/<svc>/clear` with `{scope: "local"|"b2"|"both", confirm}`: it
  records the request in `backup-audit.log` (who, scope, resolved sizes) and then
  asks the **node** to act — the node is the only party that can, because
  append-only forbids any client credential from deleting (§3.1) and the node
  holds both the filesystem path and the bucket key. The node picks the request
  up on its next registration/poll, deletes that scope's repo(s) in the documented
  order (`both` = local then B2, §3.3b), writes `offsite = false` itself when the
  scope includes `b2`, and reports the result in `stats`; `confirm` must repeat
  the service name and the scope. A request naming a service whose repo the node
  does not hold is refused there as a 409-equivalent rather than succeeded
  silently. fleet-edge never touches a repo, so it needs no restic binary and no
  bucket key — that is the point of routing the delete through the node instead of
  through the edge.
- The dashboard gains the §3.3b table: target, B2 checkbox, retention presets,
  sizes, cost, last backup / last copied, and *turn off* plus the three clear
  scopes. Every other fleet-edge action stays where it is; this is the first
  action `internal/server` grows, so keep it the only one.

**Clients resolve the node at backup time, over the public API.** There is no
loopback path for a container host: `/internal/*` is never proxied by h005's
nginx and a container host is not h005. So the resolver is an authenticated
`GET /api/backup` through `h005:443` with a Zitadel machine token — the same
`edgeClient` shape `cmdExpose` already uses
(`flakes/fleet-agent/internal/containers/edgeapi.go:100-150`), which means readers
need a machine-token grant, not a new transport. Read-only, so
`internal/authority` grants it to every container host (the set is derivable from
the same allow-list as §3.6) while `PUT` stays writer-only.

`fleet-backup` resolves `target` per service once per run, then builds
`RESTIC_REPOSITORY` as the resolved node's `url` plus the **service's own repo path**
(`svc-<name>/`) and loads that repo's password and htpasswd credentials (§3.5). If
the API is unreachable it uses the last good copy cached at
`/var/lib/fleet-backup/target.json` (0600) and records `target=<id>` and
`repo=<url>` in `/var/lib/fleet-containers/backup-last/<svc>`; with no cache the
run fails rather than guessing — a backup written to the wrong host is worse than
a missed night, because the stamp would then lie about where the data is.
`offsite` never reaches the client.

The **subject is derived from the service, never from the host**: a service's repo
is `svc-<name>` wherever it runs, which is what keeps `cnt move` a read of the same
repo from the destination. A host job (h001's media series, and whatever else runs
outside the container module) uses `host-<hostname>` and its own unit.

Adding `target=<id>` and `repo=<url>` to the stamp is safe: `parseStamp`
(`move.go:68`) is a `strings.Fields` key/value loop that ignores keys it does not
know and only requires `time` and `snapshot`, so an older `cnt` keeps reading new
stamps; the node-aware move must read both new fields (§3.7).

### 3.3a Changing a service's node

The service's repo does not change when its node does, so this is cheaper than it
was: same subject name, different host holding it.

1. **The repo forks by node.** `svc-puzzles` on node A and `svc-puzzles` on node B
   are two repositories with the same name — different keys, independent histories,
   and a client pointed at B needs B's copy of that subject's password (they are
   per repo, §3.5). Migrating history is one command with both passwords,
   `restic copy --from-repo <A path> --from-password-file <A pw>` plus
   `-r <B path> -p <B pw>`, and it is a **full upload of that subject into B's
   empty repo**: B has no blobs yet, and even a destination seeded with the *same*
   inherited chunker has to be written before a later copy can dedup against it
   (measured: 20,004,490 bytes into an empty repo sharing the source's chunker, as
   against 1,317 for the same copy into a repo that already held the blobs).
   Without it the series at B starts at the switch. Only an explicit
   `cnt restore --latest` looks at more than one node (§3.7).
2. **The old node stays readable.** Nothing deletes it: it remains registered and
   `enabled` so explicit restores can reach older snapshots, with its own
   retention still pruning on schedule. Retiring it is an explicit operator step
   after the keep-window passes with no reads — never automatic, because a repo
   pruned to empty looks exactly like a new one. The old repo also keeps its
   `offsite`/`retentionB2` until someone clears it (`clear <svc> local` on that
   node, §3.3b), which is why *clear* has to be a distinct, confirmed action
   rather than a side effect of the move.
3. **A move becomes two-node.** `cnt move` reads the source's final backup from
   its stamped node and repo and writes the destination's first backup to the
   destination's resolved node; if they differ, the destination needs a credential
   for **both** — read on the source's `svc-<name>`, write on its own — and both
   nodes must be enabled and reachable. Both are preflight checks (§3.7), so it
   refuses before downtime rather than mid-switch.
4. **Because a credential is per repo, a node change is a secret change** unless
   the operator copies the subject's repo (password included) to the new node.
   That is the deliberate cost of §3.1's isolation: there is no fleet-wide password
   that magically works everywhere.
5. **The offsite repo follows the subject, not the node.** B2's path is keyed by
   subject (`b2:<bucket>:svc-<name>`, §3.4), so the destination node's copier
   writes the same repo the source node was writing — that is what keeps one
   continuous offsite series across a move. Two things make that safe rather than
   racy: the copier only copies services whose resolved `target` is *itself*
   (§3.4), so the policy edit that moves the service is also what stops the old
   node copying; and the destination needs that subject's **B2** repo password
   hydrated in its own `sub` before its first copy, exactly like the local one.
   Until it does, `offsite` is set but not written, and `offsite-b2.json` for that
   subject goes stale — visible in the UI, not silent.

### 3.3b The per-service UI: where the data lives, what it costs, and how it ends

One row per service, one `default` row, and no per-login quota. (A rest-server
`--max-size` is checked before a write and answers `507`, so a tight value bricks
a host's backups rather than protecting anything; the numbers below are for
*seeing* spend, not capping it.) Each row:

| Field | Values | Notes |
|---|---|---|
| `target` | a node `id`, or `none` | §3.3; `none` is *turn off* |
| `offsite` | `true` / `false` | "the B2 checkbox": the node copies this repo off site |
| `retentionLocal` | `short` / `standard` / `long` | preset name, resolved by the node (§3.2) |
| `retentionB2` | same three, or `local` = "follow `retentionLocal`" | default `local`, so the offsite copy is never shallower than the local one |
| local size, B2 size, est. $/mo | read-only | from the node's stats unit, below |
| last backup, last copied | read-only | the stamps and the copier's per-repo state |

**Retention presets are named keep-sets, and `standard` is today's policy.** The
node owns the table and publishes it in its node record, so the UI can only
offer numbers the pruner can actually run, and a preset change is one deploy that
the UI immediately reflects:

| Preset | `restic forget` arguments | Rough local window |
|---|---|---|
| `short` | `--keep-daily 3 --keep-weekly 2 --keep-monthly 1` | ~1 month |
| **`standard`** (default) | `--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 3` | the current fleet policy, unchanged |
| `long` | `--keep-daily 14 --keep-weekly 8 --keep-monthly 24 --keep-yearly 5` | ~2 years, for the media |

`standard` is the default for every service, including every service migrated in
§4 step 6, precisely so the cutover does not change anyone's retention. Two
preset layers are deliberate: local and B2 are separate repos with separate
pruners, so "keep a year here, three years off site" is a legitimate choice, and
the `local` alias means an operator who does not care gets the sensible coupling
(B2 at least as deep as local) without having to restate it.

**A shorter `retentionB2` is allowed, and the completeness gate accounts for
it.** Two ways to reconcile that with the gate, and the choice is the gate:
**make it retention-aware, and do not forbid the shallow setting.** The shallow
setting is the whole point of a separate preset layer — "keep a year locally,
three months off site" is a legitimate trade of offsite depth for cost, and the
paragraph above sells exactly that freedom — so a UI rule rejecting it would
contradict the feature and push the same choice into ad-hoc repo edits. It would
also be the wrong place to enforce a *consistency* property: retention and
completeness are both computed by the node from one resolved preset per run
(§3.2), so making them agree is a change in the gate, while a UI constraint has
to duplicate the preset ordering (`short` ⊂ `standard` ⊂ `long`) somewhere the
pruner never reads and an API caller can bypass. Deciding it in the gate also
makes the invariant checkable rather than merely forbidden.

What follows is that *"every local snapshot is at the destination"* cannot be
the gate as written (§3.4). The B2 pruner deletes snapshots that are still
perfectly present locally — that is retention working, not a failed copy — so a
gate comparing the two raw sets would fail forever on a correct pipeline and
block §4 step 9 (§5). Measured on 0.18.1: ten local snapshots copied off site
and pruned at B2 to the real `short` preset (`--keep-daily 3 --keep-weekly 2
--keep-monthly 1`) leave 7 local keys legitimately absent, and a set-difference
gate reports all 7 missing. A six-snapshot variant pruned to `--keep-daily 2`
reports 4.

The fix is to compare against **what B2's preset would keep**, not what local
holds: run the B2 preset's selection against the **local** series —
`restic forget --dry-run --json <B2 preset args> --group-by ''` on the local
repo — and require only those keys at the destination. Same six-snapshot
fixture, same prune: the expected set is the 2 snapshots the destination holds,
and the gap is empty. The dry-run must be run **on the local repo**, not on the
destination: computing keeps *on the destination* is circular, because
`forget --dry-run` there selects from whatever already arrived, so it reports an
empty gap even when a real snapshot never made it (measured: with a seventh
local snapshot never copied, the destination-side dry-run reported 0 missing
while the local-side one correctly named the missing key). Verified across the
four retention relations — equal, B2 deeper than local, B2 shallower, and a
prune lag where B2 holds fewer rows than its own preset would keep (that one
correctly reports the lag rather than passing quietly).

The UI keeps `local` as the default so the common case stays coupled, and does
**not** reject a shallower B2 preset: the rule is enforced where it can be
checked, in the gate, and the shallow choice remains a legitimate way to trade
offsite depth for cost.

**Size and cost come from measured numbers, never estimates of what restic might
use.** Three sources, each with an owner:

1. **Local size** — `restic stats --mode raw-data` on the node, per repo, against
   the filesystem path. Raw-data is the number that matches what the disk holds
   (`restore-size` counts plaintext and would understate a compressed repo);
   `--mode files-by-contents` is not used because it re-reads the tree.
2. **B2 size, per subject repo** — the same command against that subject's B2
   repo URL (`b2:<bucket>:svc-<name>`, or `7f023d4a` for the media, §3.4), with
   one figure per row and the total being a sum over subjects rather than a
   bucket-wide number. For the media the per-subject figure is the `h001`-tagged
   series, so it is measured by feeding that series' IDs to `stats` (`restic
   snapshots --tag h001 --json`, then `restic stats --mode raw-data <ids…>`)
   rather than by subtracting the legacy rows — `stats` takes snapshot IDs, not a
   tag filter, and subtracting two repo-wide figures would fold the legacy rows
   into the answer. Beside it sits the one number that is not a
   subject's own: **bytes B2 holds that no repo accounts for** — today the
   pre-cutover `--tag fleet` rows inside `7f023d4a` — because that is the figure
   that has to reach zero before §4 step 9 deletes anything (§3.4). The row's
   number is what the UI shows and what that gate reads.
3. **Rate** — one constant, `b2PricePerTbMonth = 6.95`, set in Nix and served
   with the policy so the UI never hardcodes a price. Cost is
   `size × rate / 1 TiB`, per service and summed; it is a displayed estimate, not
   a bill, and the UI says "estimated" for that reason. Backblaze's minimum
   retention charge and any egress on restore are out of scope for the number.

The node collects all of it on a slow timer (`fleet-backup-stats.timer`; hourly,
because the media's stats pass reads its index and takes minutes the first time)
into `/var/lib/fleet-backup/stats.json`, and publishes it
on the same registration channel as the node record —
`POST /api/backup/targets/<id>` carries the sizes, so fleet-edge stores them and
the UI needs no path to a node. Reading them client-side would mean every
dashboard load pulling bytes from the backup node with a machine token, and
the node is not an API server for the edge. If a node has not reported for ~2 h,
its sizes render stale with the timestamp, never as zero: "no number" and "0 B"
must not look alike, which is also why *clear* re-reads the sizes after it runs.

**Two destructive actions, which are not the same action.**

- **Turn off** = stop new backups, keep everything. It writes
  `target = none`; the service's repos stay, and the node keeps pruning them
  under the preset. Nothing is deleted, no confirmation beyond the ordinary form
  submit, and it is reversible by picking a node again. This is exactly §6's
  `none`, and it is the value the UI shows when a service has no node.
- **Clear** = end one copy of a subject's data, and it takes a **scope**: `local`,
  `b2`, or `both`. It is a separate action from *turn off*, with a typed
  confirmation that names both the service and the scope (`clear svc-puzzles
  local`), an audit line in `backup-audit.log` with the operator's identity, the
  scope and the resolved sizes at the time, and **executed by the node, never by
  the client or the dashboard** — a client asks, the node acts. That is required,
  not stylistic: append-only means no client credential can delete anything
  (§3.1), and the node is the only party that holds both the filesystem path and
  the bucket key. A `clear` naming a service whose repo is on another node is a
  409 rather than a silent success, because this node cannot see a repo it does
  not hold.
  - `local` — deletes the subject's local repo and leaves its `target` alone, so
    the next scheduled run finds no repo and re-`init`s an empty one (§3.1); the
    UI shows it as empty until then, and the shift from a full history to nothing
    is on the audit line. That is the difference from *turn off*, which keeps the
    repo and its history: `local` is for a corrupt repo or a deliberate restart of
    the series, not for pausing a service.
  - `b2` — deletes exactly one subject's offsite data, and nothing else can be in
    it: `svc-<name>` is its own repo (§3.4), so the delete addresses one service.
    For every container subject that means the repo itself goes: restic has no
    "delete repository", so the node deletes the objects under that subject's
    bucket prefix with the bucket key — the same prefix its `-r` URL names, which
    is why that key's grant is a prefix and not the whole bucket (§4 step 7).
    For the media the B2 repo is `7f023d4a`, which is shared with the pre-cutover
    legacy rows and is not this subject's repo to delete, so `clear host-h001 b2`
    is `forget --prune --tag h001` — the rows the subject owns, and nothing more.
    It **may never delete `7f023d4a`**, which §4 step 9 also only ever prunes by
    tag. Both forms **also set `offsite = false`** in the same audited operation:
    leaving it true would have the next copier run recreate a repo that was just
    deleted, so clearing B2 and un-checking the B2 box are one action, not two.
    Turning `offsite` back on later starts a fresh offsite series from whatever the
    local repo holds then — it does not resurrect the deleted bytes.
  - `both` — both of the above in one request, local first, then B2, so a partial
    failure leaves the offsite copy (the recoverable direction) rather than no
    copy at all. `offsite = false` for the same reason as `b2`.
  - `b2` and `both` are refused with a 409 when the subject has no offsite repo
    (its `offsite` is already false and no B2 path exists) — a clear that
    silently no-ops makes the operator think the bytes are gone.

### 3.3c Naming: a *node*, not a target

The word "target" survives in two places only: the `target` **policy field** (the
generic "where does this snapshot go", also the key in the stamp and in
`/var/lib/fleet-backup/target.json`), and route/file names that are already
written that way (`POST /api/backup/targets/<id>`, `backup-targets.json`). The
machine itself is a **backup node**, and the Nix switch is opt-in and new —
nothing named `backupTarget` exists in the tree today:

```nix
# the node's own config; the only thing a host does to become a candidate
ringofstorms.fleet.backupNode = true;
```

That one line means three things, and they are the reasons it is a host setting
and not a fleet-wide list:

1. It emits the rest-server, prune, copier and stats units (§3.1, §3.2, §3.4).
2. It makes the host register a node record, so the UI offers it as a node
   (§3.3). No registration, no selection.
3. It asserts the host has the `restic_offsite_<host>_<date>` grant, because a
   **backup node may hold a B2 key** — that is the whole permission model now:
   *only backup nodes hold one*, and h004 is the first, not the only.

So "only h004 may hold a B2 key" everywhere in this document means "only a
`backupNode` may", and a non-node host reaches B2 nowhere. Two consequences worth
stating: the firewall allow-list (§3.6) is what a second node *receives* — the
clients already have the rule and nothing on a client changes — and designating a
node is a deploy (it needs the key and the units), while *choosing* one for a
service stays a UI edit (§3.3).

### 3.4 The offsite copier: on a backup node, per repo, and the media kept in the repo it is already in

**Only a backup node ever holds a B2 credential** (§3.3c). No container host has
one, and a host that is not opted in as a node never will; the copier runs on the
node and is emitted by its `backupNode` option, not hand-written:

```sh
# a container subject -> its own B2 repo, svc-<name> (one repo per subject)
node_copy svc-<name>

# the media series -> the SAME repo it is already in, 7f023d4a (§4 step 8)
node_copy host-h001
```

`node_copy` is `restic copy --from-repo <repo> --from-password-file <repo pw> -r
<destination> -p <dest pw>` plus the completeness bookkeeping below; the point of
naming it is that the two halves of its work — *copy* and *know that the copy is
complete* — are one operation.

- **Per repo, because the repos are per subject.** There is no `--tag` filter any
  more: copying `svc-<name>`'s repo copies that service's whole history and
  nothing else, and `--from-password-file` is what lets one copier read repos
  whose passwords all differ (§3.5). Runs **on the node** from the filesystem
  path, so append-only is not in the way and no client is involved.
- **One B2 repo per subject, named like the local one.** The destination is
  `b2:<bucket>:svc-<name>` — the same name the local repo has, in the same
  bucket, one `config` and one key set each. This is not a preference: a shared
  repo would make the pruner (§3.2, no tags, whole repo) and *clear* (§3.3b)
  delete other services' history, since neither can address a subset of a repo
  except by tag, and tags are not a security boundary. Per-subject B2 repos are
  also the only shape in which "who can delete what" matches the local layout
  and §3.1's isolation rule.
- **The media keeps the repo it is already in.** `host-h001` is the one subject
  whose B2 repo is `7f023d4a` rather than a fresh `svc-`-named path, because that
  repo already holds its 484.9 GiB and its history (§4 step 8). It is pruned
  `--tag h001` and was copied in under the same tag, so the subject's series is
  exactly the tagged set; the legacy rows are removed once by §4 step 9. The
  price of a third shape was rejected on cost, not taste:

  | Option | Bytes at B2 | Verdict |
  |---|---|---|
  | Per-subject `svc-<name>` repos; media keeps copying into `7f023d4a` | 31.2 GiB uploaded once (one full first copy per empty repo, §3.4) + the 484.9 GiB already there, which is re-used rather than moved | **chosen** |
  | Media copied into a fresh repo, `7f023d4a` deleted | 484.9 GiB re-uploaded; `--copy-chunker-params` cannot avoid it, because the fresh repo starts empty and an empty destination dedups against nothing — the same reason each `svc-*` repo uploads its first copy (§4 step 4) | rejected: a day of uplink, and a window with no independent media copy |
  | Media copied into `7f023d4a` *as a second repo in the same bucket path* | impossible | a bucket path is one repo — one `config`, one key set |

  **Decided: reuse `7f023d4a` for the media and remove the duplication, not the
  repo.** The node copies `host-h001` into `7f023d4a` on every run, so the media's
  offsite copy is a repo the node's own prune can govern (§3.3b). What is left
  over inside that repo is the pre-cutover fleet history: the `--tag fleet` /
  `svc:*` snapshots whose blobs no current subject password opens, and which the
  per-subject B2 repos will hold a governed copy of. Removing those rows is §4
  step 9 — a scoped `forget --prune` inside `7f023d4a`, gated on every
  `offsite: true` subject's B2 repo being verified complete, because **deleting is
  only safe once the new copy is provably whole.**
- **The media's B2 prune is the one that is tag-scoped, and that is deliberate.**
  `7f023d4a` holds two things until step 9: the media's own series, starting from
  the seeded history (§4 step 4), and the legacy rows. So the node prunes it with
  `--tag h001` (the tag the media job has always written) instead of pruning the
  whole repo, and the legacy rows never age out by accident. Every other B2 repo
  is one subject and is pruned whole. This is the single exception, and it ends
  when step 9 removes the legacy rows.
- **"Verified complete" is a number, not a feeling, and it is counted by
  `original`, not by `id`.** A copy writes a **new** snapshot ID at the
  destination and keeps the source's ID in the `original` field, which a second
  copy preserves again — so a two-hop A→B→C ends with C's `original` equal to
  A's `id`, and the literal IDs at local and destination *never* intersect
  (measured on 0.18.1: A `045d2045…`, B `78531b81…`, C `f11b07e2…`, intersection
  0; the copy back into `7f023d4a` is the same, the destination keeps its own
  `4b02ef3d…` while the local copy of it is `2ec1cfd0…`). Comparing raw IDs
  therefore fails every correct copy and would block §4 step 9 forever. The gate
  compares `(.original // .id)` on both sides — `[.[] | (.original // .id)]`,
  then set-difference of the expected set against the destination.
  **The expected set is what the B2 preset would keep, not every local
  snapshot**: `retentionB2` may be shallower than `retentionLocal` (§3.3b), and
  then the B2 pruner deletes rows that are still present locally, so a
  whole-local set would fail forever on a correct pipeline. Compute it by
  running the B2 preset against the **local** series — `restic forget --dry-run
  --json <B2 preset args> --group-by ''` on the local repo — and require those
  keys at the destination. Running that dry-run *on the destination* instead is
  circular: it selects from what already arrived, so it reports an empty gap even
  when a snapshot never made it (§3.3b quotes both measurements). The test is
  still a subset, not equality: a destination legitimately holds rows the local
  repo has never seen (the legacy `--tag fleet` rows in `7f023d4a`), and they
  must not fail the gate.
  Each matched key must also agree on `time`, `hostname`, `paths`, `tags` and
  `tree` — the ID proves *a* snapshot arrived, the tuple proves it is *this*
  one, and the trees are what makes it byte-identical (§3.4). The node records
  the result per subject, with the destination's snapshot count and its own
  raw-data size, in `/var/lib/fleet-backup/offsite-b2.json` (0600): are all of
  the snapshots B2's preset would keep (by that key) present and identical at the
  destination, and does the destination account for the bytes we think it holds.
  The count is a **recorded number, not a comparison**: the two sides differ
  legitimately, by the legacy rows in `7f023d4a`, so the pass condition is the
  key subset plus the metadata tuple, never `count_local == count_destination`.
  `restic check --read-data-subset=…` on a sample is the third check.
  Deleting anything — a legacy row, a bucket, an old repo — requires this record
  clean and a week old (§4 steps 8-9); the record exists so the gate can be
  *checked* rather than remembered, and so the UI's "B2 size" column (§3.3b) is a
  measurement.
  The handover inside `7f023d4a` is therefore **a copy plus a scoped prune**, not
  a merge: a repo is not a folder of snapshots that can be merged, and
  `7f023d4a`'s snapshots are encrypted with *its* keys, so the only way to give
  the repo a series the node can govern is for the node to hold that repo's
  password and copy into it. `restic copy --from-repo …/host-h001
  --from-password-file <host-h001 pw> -r <7f023d4a> -p <7f023d4a pw>`
  writes snapshots with the same trees and **new IDs** — the source ID survives
  in each copy's `original` field, and that field is what the completeness gate
  matches on (§3.4) — and because `7f023d4a` already holds the media's blobs —
  the local repo was seeded from it, and more importantly the destination itself
  is the repo the data came from — the copy adds index and metadata only
  (measured: 964 bytes into a 60 M destination).
  Two conditions make that true and both are required: the destination must
  already hold the blobs, **and** the local repo must cut the same chunks, since
  a populated destination still re-uploads everything when the chunkers differ
  (measured: +20,005,366 instead of +1,317). This is the *only* place in the plan
  where that holds — see the next bullet for the empty-repo case. The copied
  snapshots keep the media job's `h001` tag, so the B2 prune sees one continuous
  series — the old rows and the new ones — and `restic diff` between a copied
  snapshot and its local source is empty, which is the check that the handover is
  byte-identical.
- **One chunker for the whole container family, taken from the old B2 repo.**
  Each hop is a full upload into an empty repo the first time and incremental
  after that — old B2 → local `svc-<name>`, then local → that subject's B2 repo.
  The copied chunker is taken at all three ends (`restic init
  --copy-chunker-params --from-repo <old B2> --from-password-file <old B2 pw>`
  for each local `svc-*`, then for each B2 `svc-<name>` from the local repo,
  §4 step 4) for uniformity, but it is the **local** repo's chunker that earns
  its keep, because that is the only one a client `backup` writes into — a copy
  never re-chunks. Measured on 0.18.1: a blob is addressed by the hash of its
  **plaintext**, so its ID is key-independent (27/27 IDs shared between two repos
  with different keys), and `restic copy` transfers blobs by that ID without
  re-chunking — copying a `chunker_polynomial`-modified source into a
  default-chunker repo preserved 17/17 — so a copy's incrementality does not
  depend on the two chunkers matching at all (a repeat copy between mismatched
  repos added 0 bytes, then 5,002,699 for 5 MB of new source). What the copied
  parameters are for is dedup against the **inherited history**: the same files
  backed up at a fresh path into a repo that already
  holds them cost 2,366 bytes when the repo inherited the chunker and 20,005,172
  when it did not — the whole file set again. (Each `init` otherwise picks a
  **random** polynomial — `y1`/`y2` differ — which is why the params are copied
  around at all.) None of that makes a first copy cheap: nothing is stored until
  it is written, and an empty destination has nothing to match against, measured
  as a 20,005,756-byte source → 20,005,811 bytes of destination, even with copied
  params (a differently-seeded empty repo took 20,005,801). What makes a copy
  *incremental* is the destination already holding those blobs — that is the
  property the first pass creates. The same copy run again added **0** bytes, and
  after 5 MB of new source data one more copy added 5,002,880. So: the first copy
  into a new `svc-<name>` repo is a full upload of that subject's data, and every
  copy after it moves only new chunks. At ~31 GiB for all 18 container services
  that first pass is one upload of ~31 GiB in total, and the steady state is
  ~$0.21/mo of storage — bought, not regretted. Two *subjects'* repos do not dedup
  against each other, and the reason is *not* that they are separate repos: the
  same data backed up under one chunker shared 13 of 15 blob **IDs**, so IDs travel
  fine — but equal IDs in two repos are two stored copies, because dedup only ever
  matches against blobs the writing repo already holds. The loss is the dedup on
  whatever two subjects happen to share; §3.1 restricts each subject to its own
  repo anyway, so the isolation is bought with that dedup, and it is the same trade
  §3.1 already made on the local side.
- **`host-h001` is seeded from `7f023d4a` instead**, with the media repo's own
  password, because that is the repo it is copied into and the media history
  already lives there. The copy back into `7f023d4a` is index-and-metadata either
  way *provided the chunker is inherited* — copying the params is the mandatory
  half — but the seed is what gives the local repo the media's own snapshots, so
  the series continues instead of restarting, and it saves the node a from-scratch
  first backup of a 484.9 GiB dataset.
- The list of repos to copy is the `offsite: true` set from the policy export,
  filtered to services whose `target` is *this* node, plus the host repos the node
  runs itself (`host-h001`). A service pointed elsewhere is not this node's
  business — the copier never reads another node's repo. Each node copies its own
  repos to the same bucket, and the destination path is the subject's, not the
  node's: a service moved between nodes keeps writing one offsite repo (§3.3a).
- **Only backup nodes hold bucket keys.** `restic_h001_env_2026-10-01` is retired
  from h001 when the media job moves (§4 step 7); the first node gets a new
  `restic_offsite_h004_<date>` key scoped to its `sub` only, containing the B2
  application key and **the B2 repo password for each subject**, because B2 repos
  use their own passwords and are not the local repos' (§3.5). A second node gets
  its own key and its own `sub`: node credentials are never shared between nodes,
  even though they reach the same bucket. The password manager's break-glass copy
  (`ROUTING-PLAN.md` §9.3) keeps an independent set, now one entry per node.
- **Break-glass reads B2, not the local repos.** The bucket keeps: one
  `svc-<name>` repo per opted-in subject, the media's copy inside `7f023d4a`, and
  — until §4 step 9 — the legacy `fleet`/`svc:*` rows. The break-glass record
  therefore names the bucket key, the media's repo password, and **one password
  per subject repo** (they are all different, §3.5); a single "the B2 password" is
  no longer a thing. Deleting the legacy rows is what makes the record small
  again, which is a reason to do step 9 *carefully*, not a reason to skip it.
- Backup of the backup: the local repo is the only copy between the backup run and
  the copy run. Order the timers (local backup → prune → copy) and make the copier
  fail loudly; a stale `lastCopied` is the number to watch, not `lastBackup`, and
  it is a column in the UI (§3.3b) for exactly that reason.

Now that the node is runtime state, the copier must also be *re-read* on change:
it re-fetches the policy each run (same authenticated `GET /api/backup` the
clients use, with the node's machine token), so opting a service in or out needs
no deploy. If that call fails the copier does nothing for that run and leaves
`lastCopied` stale rather than guessing a repo list — copying the wrong service
costs money, so the failure is the safe side. "Doing nothing" is also what
`target = none` means for a repo already copied: the repo stays in B2 and keeps its
`retentionB2` preset until an explicit `clear <svc> b2` or `clear <svc> both`
(§3.3b) removes it. Turning `offsite` off stops copying and deletes nothing; the
two are different actions on purpose.

### 3.5 Secrets: one key per repo, credentials only, no repository

Because clients resolve the node, the per-subject secret **must not contain
`RESTIC_REPOSITORY`** — a baked URL is exactly the thing that makes the choice
unchangeable. One registry key per repo:
`machines/high-trust/restic_repo_<subject>_<date>` (e.g.
`restic_repo_svc-puzzles_2026-11-01`, `restic_repo_host-h001_2026-11-01`),
`fields = [ "value" ]`, and `access` is an explicit **`sub` for the one consumer
and nobody else** — no `device_high_trust`, which is what made the current file
fleet-readable (§2.1). Contents, names only:

```
RESTIC_PASSWORD=<this repo's password>
RESTIC_REST_USERNAME=<subject, e.g. svc-puzzles>
RESTIC_REST_PASSWORD=<this subject's rest-server login password, PLAINTEXT>
```

**`RESTIC_REST_PASSWORD` is the plaintext password, not the htpasswd line.**
restic sends it as the HTTP basic-auth password on every request, so it must be
the same string the node's render hashed into the `.htpasswd` line; the `$2y$…`
`.htpasswd` is the *server-side* form of that same password and belongs only on
the backup node (§3.5a). Putting the hash in the secret is a guaranteed 401, and
putting the plaintext in `.htpasswd` makes the file useless — bcrypt verify fails
on a line that is already a hash. The two forms differ, and each has exactly one
home:

| Form | Where | Who reads it |
|---|---|---|
| plaintext | the subject's `restic_repo_<subject>_<date>` secret (root, 0400 hydrated) | the client, as `RESTIC_REST_PASSWORD`; the node's render (§3.5a) |
| bcrypt `$2y$…` | `/run/restic-rest-server/htpasswd` on the node, derived from the same secret at unit start | rest-server only |

So there is no separate "node-only secret" to keep in sync: **the node derives the
htpasswd entry from the same secret it holds** (§3.5a), which is why the secret is
one `sub`-scoped key per repo and why the node needs that subject's key hydrated
even for a repo it only serves. A hand-written node-only secret was the
alternative and it is a second copy of a credential that must match byte for byte;
drift there is a 401 that looks like a missing repo.

Four consequences worth stating.

- **Distinct repo password per subject.** This is the isolation, not a detail: a
  leaked `RESTIC_PASSWORD` opens one repo (§2.4). The cost is real and accepted —
  a service that changes node needs the *new* node's copy of that repo and
  therefore its password re-hydrated (§3.3a point 4); there is no fleet-wide
  password that works everywhere. The login password is a *second*, independent
  secret in the same file and gets the same treatment: two subjects must not share
  one, or revoking one revokes both.
- **The URL lives in the policy, not on disk**: the only persisted copy is the
  client's `target.json` cache, which is a resolved answer, refreshed every run.
- **The scheme matters.** A bare `http://host/…` is parsed by restic as a *local
  path* and fails with `invalid backend`; `RESTIC_REPOSITORY` must read
  `rest:http://100.64.0.17:8000/svc-puzzles/`. Measured: with that URL plus
  `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` and `RESTIC_PASSWORD`, `init`,
  `backup` and `snapshots` all work on a bare URL with no userinfo — and the URL
  restic prints and stores carries **no credentials**. URL userinfo also works but
  lands in the repo URL, which is stored in every snapshot. Never use it.

Wiring is one `configChanges` entry per host, pointed at the secret(s) for the
repos that host may read:

```nix
configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";
```

stays as written, only the keys it names change. A host's key set is **exactly the
repos of the services the policy currently places on it**, plus any repo it is
about to inherit through `cnt move` (§3.7). That is the whole point of §2.1: a
container host's credential set is not the fleet's, so a leaked host credential
reads one or two series, not thirty. Do not widen it to "everything this host
could ever host" — `cnt move` writes placement at runtime (`move.go:455`), so a
union would grow with every possible move and undo the isolation.

Two things make that workable. A service's **htpasswd user exists on every backup
node** (each node renders the same set of lines from the subject secrets it holds,
§3.5a) so a service can authenticate wherever it lands, and a username without
that repo's password grants nothing. And a **move declares its grant**: `cnt move`
requires the destination's key set to already include the moved service's repo,
failing in preflight when it does not (§3.7), so the grant is a reviewed registry
change rather than a runtime surprise.

The static `containers.backup.repository` option (`host-module.nix:634-638`) goes
away: a repo set at build time is the thing this design removes. The `fleet-restic`
wrapper (`host-module.nix:1263-1271`) keeps `set -a; . $file`, then exports
`RESTIC_REPOSITORY` from the resolved node unless the caller passed `-r`/`--repo`
(so a hand-run `fleet-restic -r rest:http://…/<subject>/ …` still works for
forensics and for `cnt move`'s stamped-repo restore, §3.7), and the same resolution
feeds `fleet-backup`'s `backupScript` — one resolver, two callers.

**h001's B2 secret dies with the media job.** `restic_h001_env_2026-10-01`
(B2, `AWS_*`, `RESTIC_REPOSITORY` = S3 URL) exists only because the media job
writes to B2 (`hosts/h001/sec-agent.nix:65-68`). Once the writer moves to h004
(§4 step 6), h001 keeps only `restic_repo_svc-<name>_<date>` keys for its container
services and **no B2 key at all**; bucket keys exist only on backup nodes (§3.4).
Until that step it stays exactly as it is, because stripping `RESTIC_REPOSITORY`
from it would break the media job.

Rotation: **`.htpasswd` is read once at process start.** Adding a user or rotating
a password had no effect until restart or SIGHUP (verified). The module has no
`ExecReload`, so the server needs one — and because §3.5a makes the render a
separate root unit, the reload is two steps expressed once:

```nix
systemd.services.restic-rest-server = {
  reloadPropagatedFrom = [ "render-htpasswd.service" ];   # §3.5a
  serviceConfig.ExecReload =
    "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
};
```

so `systemctl reload render-htpasswd` is the documented rotation step: it re-runs
the render and then SIGHUPs the server. `systemctl reload restic-rest-server`
alone re-reads the file but does not re-render it, which is why the render unit is
the one to reload.

Clients cannot revoke a key (`key remove` → 403), so the htpasswd entry is the only
per-subject kill switch, and it is a good one — one line, one subject, no effect
on anyone else's repo. It follows the secret now, so the kill switch *is* the
secret's `access` list: drop the consumer's `sub`, deploy `sec`, delete the
hydrated copy, `systemctl reload render-htpasswd`, and that login is dead. What
remains is that subject's repo password, which only that subject's key held —
rotate it with a local `restic key` operation on the
node, or `init` a fresh repo. Because the blast radius is one repo, that is a
small operation; plan it, but it is no longer a fleet-wide incident.

### 3.5a The htpasswd line is derived, and the plaintext is never the stored form

§3.5's split has a consequence that reaches back into the registry: **the
plaintext REST password must exist in exactly one place** — the subject's secret,
read by the client — and the server must hold only its bcrypt form. So the node
does not receive a hand-written `.htpasswd`; it *derives* it at unit start:

```sh
# render-htpasswd, run as root at boot and on reload. A separate unit, not an
# ExecStartPre of the server: that unit is User=restic + PrivateUsers (module,
# measured) and the secrets are root 0400, so anything inside it gets EACCES.
set -euo pipefail
shopt -s nullglob   # no hydrated secrets yet -> empty file, not a literal glob
dest=/run/restic-rest-server/htpasswd
tmp=$(mktemp /run/restic-rest-server/.htpasswd.XXXXXX)   # 0600 under UMask=0077
trap 'rm -f "$tmp"' EXIT   # an aborted render leaves no partial temp behind
for env in /var/lib/secrets/hydrated/restic_repo_*; do
  subject=$(basename "$env")
  unset RESTIC_REST_PASSWORD RESTIC_REST_USERNAME   # no bleed between subjects
  . "$env"
  # Both must be non-empty. `set -u` catches unset; `:?` catches *defined but
  # empty*, and empty is the dangerous one: an empty password hashes to a valid
  # `$2y$` line, and an empty username yields `:$2y$…`, which the `case` guard
  # below would accept because it compares against that same empty string.
  : "${RESTIC_REST_USERNAME:?$subject has no RESTIC_REST_USERNAME}"
  : "${RESTIC_REST_PASSWORD:?$subject has no RESTIC_REST_PASSWORD}"
  # `-i` puts the password on stdin and only the username on argv, so the
  # plaintext never reaches `ps`; `printf` is a builtin, so it spawns nothing.
  line=$(printf '%s\n' "$RESTIC_REST_PASSWORD" | htpasswd -niB "$RESTIC_REST_USERNAME")
  case "$line" in
    "$RESTIC_REST_USERNAME":\$2y\$*) ;;
    *) echo "render-htpasswd: no bcrypt line for $subject" >&2; exit 1 ;;
  esac
  printf '%s\n' "$line" >> "$tmp"
done
chown restic:restic "$tmp"          # the server reads it as restic, not as root
mv -f "$tmp" "$dest"                # rename(2): never a partial file
```

Two things must be wired, and neither is the module's default: the server has to
be pointed at the rendered file, and something has to render it.

```nix
services.restic.server.htpasswd-file = "/run/restic-rest-server/htpasswd";

let renderHtpasswd = pkgs.writeShellApplication {
      name = "render-htpasswd";
      runtimeInputs = [ pkgs.apacheHttpd pkgs.coreutils ];  # htpasswd, chown, mktemp
      text = '' …the script above… '';
    };
in {
  systemd.services.render-htpasswd = {
    wantedBy = [ "multi-user.target" ];
    before = [ "restic-rest-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";                       # mktemp gives 0600, and mv keeps it
      RuntimeDirectory = "restic-rest-server";
      ExecStart = "${renderHtpasswd}/bin/render-htpasswd";
      ExecReload = "${renderHtpasswd}/bin/render-htpasswd";
    };
  };
  systemd.services.restic-rest-server = {
    requires = [ "render-htpasswd.service" ];
    after = [ "render-htpasswd.service" ];
    reloadPropagatedFrom = [ "render-htpasswd.service" ];  # re-render, then SIGHUP
  };
}
```

`writeShellApplication` is what puts the script on a real bash and `htpasswd` on
its `PATH`, so the unit depends on neither `pkgs.apacheHttpd` being in
`environment.systemPackages` nor an absolute interpreter path in the source
above.

`reloadPropagatedFrom` is the whole reload story: `systemctl reload
render-htpasswd` runs the script again (the render unit's own `ExecReload`), and
systemd then reloads the server, whose `ExecReload` is the `kill -HUP` that makes
rest-server re-read the file (§3.5). Without the propagation the render would
update the file while the server kept the old one in memory, which is the bug
§3.5 measured. Running the render in a root oneshot rather than in the server's
`ExecStartPre` is not stylistic either: that unit is `User = "restic"`,
`PrivateUsers = true`, `ProtectSystem = "strict"`
(`services/backup/restic-rest-server.nix:100-116`), so a render inside it cannot
read root-0400 secrets, and its `/run` is a private namespace it does not own.

`htpasswd-file` is load-bearing for a second reason beyond the path: setting it
adds the file to the server's `ReadOnlyPaths`
(`services/backup/restic-rest-server.nix:122`), so the server gets read-only
access to exactly the auth file and nothing else. The `mv` and that bind look
like a conflict and are not: a *file* `ReadOnlyPaths` entry is an
`MS_BIND`-then-remount-`ro` of one inode, and after a `rename(2)` over the path
the mount simply no longer covers it — measured in a user namespace with the
module's exact sequence: inside the namespace the append is refused
`EROFS`, then a rename from outside makes the path show the **new** inode and
content, and the path is no longer a mountpoint at all. So the server never
pins a stale file, which is the property the SIGHUP reload needs. What the bind
does *not* give is protection from a later replacement: the mount is gone after
the first render, so re-`mv`ing the file is unconstrained by it — irrelevant
here, since the file lives in a `RuntimeDirectory` that only root can write, but
not something to rely on if the path ever moves to a writable directory.

With those in place, the *only* plaintext lives in the hydrated secret files
(root, 0400, the same distribution problem §3.5 already solves), the rendered
`.htpasswd` holds bcrypt and nothing else, and adding or revoking a subject is a
secret deploy plus `systemctl reload render-htpasswd` — which re-renders and, by
propagation, SIGHUPs the server (§3.5), so there is no window where the file and
the running server disagree. The abort matters as much as the feed: `pipefail`
plus the `$2y$` guard fail the unit *before* the rename, so a subject whose
password does not hash leaves the last good file in place instead of writing a
`svc-x:` line with no hash — a line that authenticates nobody while looking like
a valid file, which is precisely the failure a `| cut -d: -f2-` pipeline
produces. A hand-written `.htpasswd` was the alternative and it is worse: it is a
second copy of a credential store, it is the one thing on the node that must match
the secrets exactly, and a drift between them is a 401 that looks like a missing
repo. The render lives in `/run` (not `/data`), is rebuilt on every start and
reload, and a subject with no secret gets no line — the fail-closed direction,
which also means the first boot (no secrets hydrated yet) produces an empty file
rather than a missing one.

The migration path is therefore "add the plaintext to the subject's secret", not
"notice the mismatch": a subject whose secret predates this (or whose operator
hand-edited one line) fails the phase-1 check, §5, at the point where it is cheap.

### 3.6 Firewall on a node (h004 shown)

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
overlay IP — or a `fleet.nix` typo silently closes the node. A second node must
open the *same* port to the *same* set, so the allow-list is generated once
inside the `backupNode` option rather than copied per host; a host that is
missing from one node's list fails at the network layer, which looks like a
restic error and reads like a bug. Note the direction: this is what a node
*accepts*. A node's own outbound path is B2 over 443, which needs no rule here and
no client change, so adding a node is a one-host deploy (§3.3c).

### 3.7 `cnt move` restores its exact final source snapshot

`flakes/fleet-agent/internal/containers/move.go:389-403` already reads the fresh
stamp from the final backup taken immediately after stopping the source and passes
that exact snapshot ID to `restoreScript`; step 5 passes the same ID to
`restoreCheck` (`move.go:423-424`). Preserve that selection, and make the
repository explicit:

- `backupCheckScript` — `/etc/fleet-containers/backup` exists **and**
  `command -v fleet-restic`. Unchanged; the marker is the host module's
  (`host-module.nix:1263`), not the repo's. Add one condition: the service
  resolves to a node (§3.3). A `none` service refuses here, before any container
  is stopped.
- **Final backup stamp** — the backup taken after stopping the source records
  `target=<id>` and `repo=<url>` alongside `time`, `snapshot` and `host` in
  `/var/lib/fleet-containers/backup-last/<svc>`. Read that fresh stamp, not a
  subsequent policy lookup and not a search for a newer snapshot.
- **`restoreScript` must pass the stamped repo.** It runs on the **destination**
  (`move.go:406`) and calls `fleet-restic restore <snapshot> --target "$tmp"` with
  **no `-r`** (`move.go:188`), so today the wrapper's default repository decides
  where it reads from. With per-subject repos that default is the *destination's*
  repo — the right repo only if the move stays on one node. Make it explicit:
  `fleet-restic -r <stamped-repo> restore <stamped-snapshotID> --target "$tmp"`,
  with the *stamped subject's* credentials loaded, not the destination's default.
  The wrapper honours `-r`/`--repo` (§3.5); when `-r` is given it must also stop
  exporting its own `RESTIC_REPOSITORY`, or the flag and the environment will fight.
- **The SQLite overlay comes from the restored snapshot, and that is correct.**
  `move.go:190` reads `"$tmp"/var/lib/fleet-backup/staging/<svc>/sqlite/<svc>`,
  i.e. the copy inside the restore target — `backupScript` snapshots both
  `/srv/containers/<svc>` and `$staging/<svc>` (`host-module.nix:395-397`), so the
  consistent copies travel with the snapshot. Do not "helpfully" point it at the
  live `/var/lib/fleet-backup/staging/<svc>`: on the destination that directory
  belongs to whichever backup ran last there and can be newer than the snapshot,
  which would silently override the restored state with data from another host.
- **`restoreCheck` takes the same pair.** `restoreCheckScript` (`move.go:553-558`)
  restores with `--include '*.db' --include '*.sqlite' …` into a scratch dir and
  then runs `PRAGMA integrity_check` / `gzip -t` per file. For a move it must use
  the **same stamped repo and snapshot ID** as `restoreScript`, i.e. the same
  `-r`, rather than resolving `latest`. The standalone `restore-check` default
  (`move.go:633-640`, `latest --tag svc:<svc>`) is not the move's selection rule,
  but it does have to resolve the subject's own repo: with one repo per subject the
  tag no longer disambiguates anything.
- **Preflight is three checks, and they are the grant's documentation.** Before the
  source is stopped (`move.go:356-362`): the destination must have **read on the
  stamped source repo**, **write on its own destination repo** for that subject
  (they may be different nodes), and **its key set must already include the
  moved service's repo** — since §3.5 grants exactly the services placed on a host,
  a move to a host without that grant fails here, in preflight, instead of at the
  restore. A `restic snapshots <id>` against the stamped repo and a lock
  create/delete against the destination repo are the two probes; per-subject
  credentials make a missing grant a clean 401 rather than a silent wrong read.
- **The grant is a registry change made with the move.** The destination's key set
  must contain the moved service's repos before `cnt move` runs; that is a
  reviewed `containers/sec/registry.nix` + `configChanges` edit, applied to the
  destination host, not something the agent can do for itself. Order: edit the
  grant, deploy the destination, then move.

Concurrent or clock-skewed snapshots could otherwise replace the source's final
state, so a move never chooses the newest snapshot across nodes.

**Newest across nodes is only for an explicit `cnt restore --latest`.** That
operation queries the enabled nodes' `svc-<name>` repos with
`restic snapshots --json` against each node's URL and selects the newest snapshot,
recording its node. Reads use the destination host's htpasswd user and that
subject's password, valid at every node holding a copy (§3.1); no extra daemon
credential is needed, and a node that has never held the subject answers 401,
which the query treats as "absent".

A move refuses when either required repository is unreadable/unwritable or the
source's final backup cannot produce a fresh stamp; it does not fall back to an
older snapshot. Retention bounds explicit historical restores (§3.2), not selection
of the move's final source state.

No backup node is a move destination: a node needs no `fleet`/`cnt` binary.

### 3.8 fleet-agent vs the host module: keep the daemon out of the data path

- **Client side stays in `containers/host-module.nix`.** `fleet-backup` already
  runs hooks, SQLite `.backup`s, stamps and per-service flocks; routing the
  snapshot through the `fleet-agent` daemon would move a root-heavy, per-service
  job into a `DynamicUser` daemon for no gain, and `cnt move` would gain a
  network hop in its critical path. Client changes are exactly three: *resolve
  the node* (§3.3), *append its own `svc-<name>/` and load that repo's
  password* (§3.1, §3.5), and *delete the container job's prune* (§3.2) — the
  last is not cosmetic, because that prune is the only retention the container
  snapshots have today.
- **Node side lives in `flakes/fleet-agent/agent-module.nix`**, next to the
  existing `fleet-agent-{bcachefs,fail2ban,smart}` companion units, as a
  `backupNode` option that a capable host enables: phase 1 emits the rest-server
  config, the `.htpasswd` render, the `RequiresMountsFor` bindings, the allow-list
  assertion and the preset table; phase 2 the registration and stats units; phase
  3 the prune timer (it must land with the client cutover, §2.2); phase 5 the
  copier; the scoped *clear* executor (`local`/`b2`/`both`) lands with the UI's
  clear. One home, so nothing migrates between files later, and h004's `flake.nix`
  gains one line instead of a module.
- **rest-server is the data plane; the daemon never touches snapshot bytes.** No
  backup payload, restore stream or `restic` invocation goes through
  `fleet-agent`. Its only role is `cnt move` orchestration (§3.7): it reads the
  final source backup's node, repo and snapshot ID from the fresh stamp, then the
  restore's bytes flow rest-server → `fleet-restic` → disk exactly as today. That
  is also why routes, quotas and the append-only ACL stay in the restic REST
  protocol instead of growing an RPC surface — a second data path would have to
  re-earn the same authentication, dedup and restore semantics and would be a
  worse copy of rest-server.
- **The admin actions are node-local for the same reason.** Prune, copy, stats and
  *clear* are root units on the node (§3.2, §3.4, §3.3b), not RPCs: they need the
  filesystem path and the bucket key, which nothing else has. fleet-edge stores
  policy and measurements and never runs restic; the daemon is not in that path
  either, so a fleet-edge outage costs policy edits, not backups.
- The policy API (§3.3) is the only fleet-edge state here; its consumers are the
  clients (resolution), the node (which repos to copy, prune, measure and clear)
  and `cnt move` (node and repository preflights).

## 4. Migration off the current B2 repo

Ordered so nothing is lost and the window with two writers is short. Two hard
constraints, and one of them now has an end date. **Nothing in B2 is deleted
until step 9's gate passes** — not a repo, not a snapshot, not a block; the
copies are made first, and "verified complete" is counted, not eyeballed (§3.4).
And h001 must not keep a bucket key after step 7. The old repo `7f023d4a` does
not survive as a *copy of everything*: step 8 hands the media over inside it and
step 9 may retire the unrelated legacy rows, which is how the fleet gets back to
**one** B2 repo per subject — 18 `svc-<name>` plus the media inside
`7f023d4a` — instead of one shared repo with tag-separated series (reuse and
removal are argued in §3.4).

1. **Freeze the container writers.** Stop `fleet-backup.timer` on h001, lio and
   h003 and mask `fleet-backup.service` for the duration, so a manual `start`
   cannot land a run mid-migration. Unmask in the same session that flips each
   host. h001's `restic-backups-h001.timer` keeps running through steps 1-5: it
   writes the `h001` tag to B2 and only moves at step 6.
2. **Leave the old B2 repo untouched and readable.** It stays, with its 164
   snapshots (`--tag fleet` 31.2 GiB, `--tag h001` 484.9 GiB), as the
   break-glass copy and as the source for the history seed — and, for the media,
   as the destination too (§3.4). Between now and step 9 it is read-only in
   practice: h004's key is the only writer, and it writes only the media's own
   series.
3. **Create the node.** `install -d -m700 -o restic -g restic
   /data/backups/restic` (do not rely on `createHome`: `/data` mounts after the
   activation script, §3.1), let the node render `.htpasswd` from the subject
   secrets it holds (§3.5a — nothing hand-written, and no plaintext on disk), check
   that the render produced one line for each of the 18 services and `host-h001`,
   then let the host register itself and take a first measurement
   (`systemctl start fleet-backup-node-register fleet-backup-stats`)
   and set the `default` policy row's `target` to it in the UI. Do not `restic
   init` a subject repo here: step 4 does it with the right chunker params, and a
   repo cannot be re-seeded after the fact — the params are fixed at `init` and an
   existing repo keeps them. (That matters for chunk *boundaries*, and hence for
   the client's later backups deduping against inherited history; it does not spare
   the first upload, which is a full one either way — §3.4, §4 step 4.)
4. **Create and seed the per-subject repos, before any client can resolve the
   node.** A client whose `svc-<name>` repo does not exist gets `Is there a
   repository at the following location?` on its first run and fails (§3.1), so
   this is a gate, not an optimisation. Every local repo — and each subject's B2
   repo, which is a separate repo that needs its own `init` — takes the **old B2
   repo's** chunker: the same cutting params at all three ends are what let the
   *client's next backup* dedup against the history the repo already holds (§3.4).
   It does **not** make the first copy cheap, and the plan must not imply
   otherwise — `--copy-chunker-params` copies chunk boundaries, not stored data,
   so every new `svc-<name>` repo starts empty and its first copy is a **full
   upload of that subject's data**: ~31 GiB in total across the 18 services, moved
   once (measured, §3.4: 20,005,756 bytes of source into an empty repo seeded with
   that source's chunker → 20,005,811 bytes at the destination). Each `init` needs
   both passwords (the new repo's finished file, and the old B2 one from the
   password manager):

   ```sh
   restic init --copy-chunker-params \
     --from-repo <old B2 s3:https://…> --from-password-file /tmp/b2.pw \
     -r /data/backups/restic/svc-<name> -p /var/lib/fleet-backup/passwords/svc-<name>
   restic copy \
     --from-repo <old B2 s3:https://…> --from-password-file /tmp/b2.pw --tag svc:<name> \
     -r /data/backups/restic/svc-<name> -p /var/lib/fleet-backup/passwords/svc-<name>
   # the subject's own B2 repo, same chunker (copied from the local repo just made)
   restic init --copy-chunker-params \
     --from-repo /data/backups/restic/svc-<name> \
     --from-password-file /var/lib/fleet-backup/passwords/svc-<name> \
     -r b2:<bucket>:svc-<name> -p /var/lib/fleet-backup/b2-passwords/svc-<name>
   # ...then the first copy into it: a full upload of this subject's series
   restic copy \
     --from-repo /data/backups/restic/svc-<name> \
     --from-password-file /var/lib/fleet-backup/passwords/svc-<name> \
     -r b2:<bucket>:svc-<name> -p /var/lib/fleet-backup/b2-passwords/svc-<name>
   ```

   **The source password goes in `--from-password-file`, never a second `-p`.**
   Only the last `-p` is used, and it is the **destination's** password (measured:
   two `-p` flags, the final one opens the repo the command just wrote, the
   earlier one answers exit 12), so a second `-p` does not give the source a
   password — it just adds one that is never read. With distinct source and
   destination passwords and no TTY (`</dev/null`), the `-p`-twice form dies at
   `Fatal: an empty password is not allowed by default` (exit 1) before it reads
   the source at all, while the form above completes `init` and `copy` at exit 0
   and the source snapshot lands at the destination with a new ID. `init` and
   `copy --from-repo` both need the source password, so both lines take
   `--from-password-file`.

   `init` writes the new repo *and* reads the old one, so it needs both passwords.
   A wrong-but-present source password is a different failure from a missing one:
   `Fatal: wrong password or no key found` (exit 12, measured), not a chunker
   mismatch, and the same applies to the final `copy --from-repo`.
   Measured: the tag-scoped copy moves exactly the named series (62 M → 62 M) and
   uploads exactly that much; the last `copy` above uploads the subject's whole
   series once (~31 GiB for all 18 services); after that every run is incremental
   — 0 bytes when nothing changed, ≈ the raw size of the new data when it did
   (5 MB of new source → 5,002,880 bytes). Deferring that first B2 copy to the
   phase-5 copier (§5) changes only *when* the upload happens, not its size.

   **`host-h001` is the exception in both halves.** Its local repo is `init`'d with
   the *media* repo's password and the `7f023d4a` chunker and seeded with the
   media's `h001`-tagged history, and its offsite repo is **`7f023d4a` itself** —
   which already exists and must not be `init`ed again, because that same repo is
   copied back *into* `7f023d4a` (§3.4) and it already holds the blobs, which is
   what makes the media handover index-and-metadata rather than a 484.9 GiB
   re-upload — the one place that property exists, and it needs both halves: the
   destination is populated **and** this local repo took its chunker, since a
   populated destination still re-uploads everything when the chunkers differ.
   Every other subject gets its own empty `b2:<bucket>:svc-<name>` in this step, so
   phase 5 has somewhere to copy, and that first copy is a full upload (§3.4).
   Without the seed each series restarts at the cutover; with it, retention and
   `restore-check latest` have history on day one.
5. **First full run on h001** (43 G, 18 services), then
   `cnt restore-check forgejo` (3 PG dumps) and `cnt restore-check puzzles`
   (2 SQLite). Then lio and h003 — their `/srv/containers` hold 20 K and 0 bytes,
   so their first runs cost nothing. This step is also the isolation test: while
   h001's run is in flight, `svc-puzzles`' credentials against `svc-forgejo` must
   answer 401, and `svc-sec` against `svc-secrets` must answer 401 (§3.1).
6. **Move retention to the node**, in the same change that removes the
   container job's client-side `forget` (`host-module.nix:406-409`). That line is
   the only thing bounding the container snapshots today (§2.2); pointed at an
   append-only node it becomes a 403-per-snapshot no-op, so between removing it
   and enabling the node's pruner nothing bounds any repo. Every migrated service
   gets the `standard` preset (§3.3b), which is exactly the current `7/5/12/3`, so
   the keep-set is unchanged across the cutover; from then on it is a UI value.
   **Media writer move, in this same step.** Stop and mask
   `restic-backups-h001.timer`, then run an equal-path job on h004 writing
   `host-h001`, with `retentionLocal = long` and `retentionB2 = long` (§3.3b).
   That is the deeper direction of the old job's `7/5/12/3`: from the handover
   onward the node prunes the media's B2 repo (§3.4), and since `long`
   (`14/8/24/5`) keeps strictly more than `7/5/12/3`, switching the preset
   cannot remove a snapshot that was already there. **Hard precondition,
   verified: this is not a config change.** `/drives/wd10` is a **local 10 T ext4
   disk inside h001** (`hosts/h001/hardware-configuration.nix:40-43`) and h004
   exports **only** `/data/nixarr` (`hosts/h001/autofs.nix:1-13`; the guard and
   its sentinel are in `hosts/h001/floating-containers.nix:45-52`), so the media
   is not reachable from h004 today. The job needs either a new export + mount of
   `/drives/wd10`, or an overlay/bind that presents the same source paths to the
   backup unit, or a data move to h004's pool. **Do not assume the existing NFS
   gets you there**, and do not create the h004 job before that path exists — it
   would back up an empty tree.
7. **Retire the old fleet-wide B2 credential.** With the media writer gone
   (step 6) and the container jobs pointing at the node (steps 3-5), remove the
   `restic_h001_env_2026-10-01` `configChanges` consumers on h001, lio and h003,
   and confirm no unit references it. Create `restic_offsite_h004_<date>` scoped
   to h004's `sub`, carrying a **new, separate B2 application key** whose prefix
   grant is the subject repos the node writes — write on `svc-*` and on
   `7f023d4a` (the media's own series, and the step-8 handover), read on
   `7f023d4a`'s legacy rows for the history seed — plus one B2 repo password per
   subject, with `host-h001` reusing the media repo's existing password. One key
   per node, not one per repo: the repo boundary is the path and the password,
   and a key per subject would be 19 creds to rotate for no extra isolation.
   Enable the h004→B2 copier **per repo** — after a week of good local copies,
   not before (§3.4) — and verify h004's new key can read and copy to every one.
   **Revocation gate: only after that verification, in this order:**
   1. Remove the `device_high_trust` role grant for
      `machines/high-trust/restic_h001_env_2026-10-01` in
      `containers/sec/registry.nix:210-218` (or delete the entry), and deploy
      `sec`. Removing host consumers alone does not stop high-trust hosts fetching
      this role-granted secret.
   2. Delete the hydrated copies on **every former consumer**, not just h001,
      lio and h003: include any other high-trust host or bootstrap install that
      hydrated it, and confirm the old file is absent.
   3. Revoke the **old** B2 application key in Backblaze; do not revoke h004's
      new key.
   4. Keep the old repo password, and say so in the record. It is `7f023d4a`'s
      password, the node holds it deliberately, and step 8 needs it — rotating it
      would strand the 484.9 GiB the media's offsite copy is made of. The secret
      *file* goes; the password does not. What replaces the fleet-wide exposure is
      the per-repo split (§3.5): this password now opens exactly one subject's
      ciphertext, and every other B2 repo has its own.
   **Do not close step 7** until fetching the old secret from a high-trust host
   fails, B2 access with the old key fails (e.g. `restic snapshots` with the old
   env returns an authentication error), and the node's new key still reads and
   copies successfully. Run the old-key check in a controlled session before
   discarding its final verification copy; do not rehydrate it on former consumers.
8. **Fill the offsite back-fill, then hand the media over inside `7f023d4a`.**
   This is where the bulk upload happens, so it is also where it is verified.
   **Check the two destination shapes separately.** For a **new `svc-<name>`
   repo, which starts empty, the first copy is a full upload**: check the
   destination's raw-data size against the source's (`restic stats --mode
   raw-data`) and expect them within a few hundred bytes of each other — ≈ the
   source's raw size at the destination, and ≈ that much again in new bucket
   bytes. A first copy that reports a few KB is the `metadata only` bug this plan
   used to assume was correct (§3.4), not a success. For the **media handover into
   `7f023d4a`**, the opposite holds and is the check, because both conditions are
   met there: the repo already holds the blobs *and* the local repo inherited its
   chunker, so the copy adds index and metadata only (measured at 964 bytes) — if
   it moves hundreds of GiB instead, either the copy is not landing on the existing
   blobs or that local repo did not take the chunker, and both are bugs. Watch
   `lastCopied`, not `lastBackup`. Once every `offsite: true` subject is copying
   and `offsite-b2.json` has been stable for a week, the media handover (§3.4):
   the node copies `host-h001` into `7f023d4a` with the media repo's password, so
   the offsite series gains snapshots with new IDs and identical trees (each one
   carrying the local ID in `original` — that, not the ID, is what the
   completeness gate matches, §3.4); verify with an empty `restic diff <copied>
   <local>` for the newest snapshot, that every local `original` appears in
   `7f023d4a`'s `snapshots --json` with the same `time`, `hostname`, `paths`,
   `tags` and `tree`, and confirm the copied snapshots carry the media's `h001`
   tag, which is the tag the node's B2 prune scopes to. Nothing is deleted in this
   step. Update the break-glass entry (`ROUTING-PLAN.md` §9.3) to say what the
   bucket now holds: one `svc-<name>` repo per opted-in subject, the media
   subject's copy inside `7f023d4a`, and the legacy `--tag fleet`/`svc:*` rows
   that no subject password covers and that step 9 retires.
9. **Retire the legacy rows inside `7f023d4a`, and only those.** The repo itself
   is not deleted — it is the media's offsite home now (§3.4), and the node holds
   its repo password so its scoped prune can govern it. What goes is the
   pre-cutover history no current subject password opens: `forget --prune` with
   the legacy `fleet`/`svc:*` tags, run once, by hand, from a session that has
   the media password.
   **The deletion gate — four conditions, all of them, or nothing is deleted:**
   1. every `offsite: true` subject has its own complete `svc-<name>` B2 repo,
      with `offsite-b2.json` clean and a week old *per subject*;
   2. `restic ls` from B2 alone succeeds for one container subject and for the
      media, using only the break-glass passwords;
   3. `restic check --read-data-subset=5%` on `7f023d4a` is clean;
   4. the media's `h001`-tagged series inside `7f023d4a` is complete, i.e. the
      unassociated-bytes figure `offsite-b2.json` reports for that repo is zero.
   Until all four hold, **nothing in B2 is deleted**: the legacy rows cost what
   they cost, and they are the break-glass copy of the pre-cutover fleet. There
   is no "delete the bucket" step, no wholesale delete of `7f023d4a`, and no
   change to the media repo's password — rotating it would strand the offsite copy
   and the node's prune.

Rollback at any step knows exactly two axes, and they are the two buttons in the
UI (§3.3b). *Target*: before step 7, rollback is "put the old env file back" —
hosts keep their stamps, snapshots and `fleet-restic`, and B2 still holds the full
history. After step 7 it is re-pointing a service's `target` at a node that holds
its repo (§3.3a), not re-uploading, which is the whole point of keeping the old
node and its repos readable. *Data*: until step 9's gate passes no B2 data has
been deleted, and a *clear* is only ever run on a service whose repo is
re-derivable from another copy — it is a deliberate act with an audit line, not a
rollback tool, and it is the one action with no undo.

## 5. Phases

| Phase | Scope | Files | Risk |
|---|---|---|---|
| **1** | h004 becomes the **first backup node**: `backupNode` option (in `agent-module.nix`) emitting `services.restic.server` (port 8000, `dataDir=/data/backups/restic`, `appendOnly`, `privateRepos`, `htpasswd-file` into `/run`, `ExecReload`, `RequiresMountsFor=/data`), `/data/backups/restic` 0700 bootstrap, the root `render-htpasswd` oneshot that derives one bcrypt line per hydrated `restic_repo_*` key and the server's `reloadPropagatedFrom` on it (§3.5a), the retention-preset table published in the node's record, the firewall rule for the container hosts + allow-list assertion, and the assertion that `backupNode` implies the `restic_offsite_<node>_<date>` grant. Subject repos are **not** created here: §4 step 4 creates them in the cutover, with the old B2 chunker, so they can still be seeded | `flakes/fleet-agent/agent-module.nix`, `hosts/h004/{firewall.nix,flake.nix}`, new `containers/tests/backup-plan.nix` | Low: nothing writes to it yet |
| **2** | Policy, presets and the UI: `internal/backup` with node registration (`POST /api/backup/targets/<id>`, carrying the preset table and the latest stats), one row per service (`target`, `offsite`, `retentionLocal`, `retentionB2`) plus the `default` row, atomic state and audit; the node's stats unit that measures local and B2 sizes and reports them on registration (§3.3b); the `b2PricePerTbMonth` constant in Nix; the dashboard's per-service table (local size, B2 size, estimated $/mo, last backup, last copied) and the destructive actions, *turn off* plus scoped *clear* (`local`/`b2`/`both`) with a typed confirmation naming service and scope, the `b2`/`both` scopes also writing `offsite = false`; the node-side *clear* executor; `cnt backup-policy` modelled on `cmdExpose` (`edgeapi.go`); nginx `/api/backup` | `flakes/fleet-edge/internal/backup/{backup.go,backup_test.go}`, `flakes/fleet-edge/main.go`, `flakes/fleet-edge/internal/server/`, `hosts/h005/fleet-edge.nix`, `flakes/fleet-agent/agent-module.nix`, `flakes/fleet-agent/internal/containers/{main.go,backup_policy.go}` | Low: no data path, and *clear* has nothing to delete until phase 3 |
| **3** | Client cutover *and* the retention handover in one deploy: the node's per-repo prune unit + timer (`restic forget --prune --group-by '' <preset>`) goes live — two passes, one over the *local* repos' filesystem paths and one over the B2 repos' URLs, both per subject (§3.2) — then the container client's `forget` (`host-module.nix:406-409`) is deleted, the static `containers.backup.repository` option is removed, and clients resolve the node via authenticated `GET /api/backup` (with a `target.json` cache) and append their own `svc-<name>/`; lio and h003 move to per-repo `restic_repo_<subject>_<date>` keys (§3.5); every migrated row takes the `standard` preset, which is today's `7/5/12/3`, so retention is continuous | `flakes/fleet-agent/agent-module.nix` (prune unit), `containers/host-module.nix` (resolver + `fleet-restic` wrapper + options), `containers/sec/registry.nix`, `hosts/{lio,h003}/{sec-agent.nix,flake.nix}`, `hosts/h003/containers.nix`, `hosts/lio/flake.nix` | High: each repo's only working retention moves from the clients to the node in this step, so do both halves together or the repo goes unbounded |
| **4** | h001 cutover: same env change for the container job, first full run, restore checks (with its 18 per-service repos). Then the media job stops on h001 and is re-created on the node writing `host-h001`, with `retentionLocal = long`; reaching `/drives/wd10` from h004 needs a new export/mount or a data move first (§4 step 6) | `hosts/h001/{floating-containers.nix,sec-agent.nix}`, `hosts/h001/mods/restic-backup.nix` (deleted), `hosts/h004/…` (new media unit) | Medium: 43 G re-read into new repos, plus a real data-path change for the media |
| **5** | Node copier: `offsite`-driven unit writing **one B2 repo per subject** (`b2:<bucket>:svc-<name>`), a chunker-matched `restic copy` per subject (§3.4) whose first pass is a full upload of that subject's data (~31 GiB in total, once) and whose later passes are incremental, the per-subject `offsite-b2.json` figures that make "is B2 complete" a number — matched on `(.original // .id)` and checked against what the B2 preset would keep, so a `retentionB2` shallower than `retentionLocal` is a legitimate setting rather than a permanently failed gate (§3.3b, §3.4) — the media copied into `7f023d4a` under `--tag h001` (its only tag-scoped repo, and its scoped prune — no byte deletion, no wholesale repo delete), `restic_offsite_h004_<date>` scoped to the node's `sub` and carrying a new B2 application key plus one B2 repo password per subject (`host-h001` reusing the existing media password), and h001's old B2 key retired (§4 step 7) | `flakes/fleet-agent/agent-module.nix`, `containers/sec/registry.nix`, `hosts/h004/flake.nix`, `hosts/h001/sec-agent.nix` | High: the first thing that spends money and the first bulk upload offsite, and the first copy of data to a second place that is not a client; the only deletion in the whole plan is §4 step 9, behind a gate |
| **6** | Docs: `ROUTING-PLAN.md` §9.1/§9.3, `containers/README.md` §"Nightly restic" (its enable list is stale: lio and h003 are on, joe is off), `ideas/restic_backups.md` (it records the opposite decision: "Direct to Backblaze B2 … the earlier local `rest-server` design was dropped"), `ideas/h004_erasure.md` (its EC row asserts "critical fleet backups live on Backblaze B2, not `h004`"), `hosts/h004/readme.md` (every line of it is currently corrupted with an NFS-table prefix; fix or rewrite it here) | docs | Low |

Each phase is one deployable cutover: phase *n* leaves the tree working with
every caller migrated. Phase 1 stands a node up, 2 makes it selectable and
operable, 3 moves the writers *and* the retention, 4 finishes h001, 5 spends
money and hands the media over inside B2, 6 removes the old story. Nothing in a
later phase has to remember to delete a shim from an earlier one. A change of
node after phase 3 is not a phase at all — it is a UI edit.

Deleting the legacy rows inside `7f023d4a` is deliberately **not** a phase. It is
§4 step 9: a dated operator step behind a verification gate that no deploy can
produce, because it needs a week of B2-side reads to pass. The repo itself is not
deleted at all — it becomes the media's offsite home (§3.4). Adding a second node
is likewise not a phase: one `backupNode = true` (§3.3c), one registry grant, and
a registration the UI then offers.

What each phase is verified by, in the style of `containers/tests/edge-vhosts.nix`
(`nix eval --impure --expr 'import ./containers/tests/backup-plan.nix'`, a list
of `{ ok, msg }` with `throw` on the first failure):

| Phase | Verification |
|---|---|
| 1 | `backup-plan.nix` asserts the backup allow-list is non-empty, contains lio's overlay IP, excludes o002 and h004, and equals the ssh list minus the port; live, as one subject's user: `restic init` over `rest:http://100.64.0.17:8000/svc-<name>/` from lio succeeds, the same from a non-listed host times out at the firewall, `DELETE /svc-<name>/snapshots/<id>` returns 403 on its **own** repo (append-only), and — the isolation boundary — **`svc-a`'s credentials against `svc-b`'s repo return 401 with `Is there a repository at the following location?`**, indistinguishable from a nonexistent repo, which is the point. Password separation is the new check: the hydrated secret holds the **plaintext**, `/run/restic-rest-server/htpasswd` holds `$2y$`-prefixed bcrypt lines and no plaintext, `htpasswd -vbi /run/restic-rest-server/htpasswd svc-puzzles <<< 'not-the-password'` fails and the same with the subject's real plaintext passes (both on stdin, so neither lands in `ps`), and the file contains one line per subject *with a hydrated secret* — no line for a subject whose secret is absent, and the line vanishes after its secret is revoked and the unit restarts |
| 2 | `go test ./internal/backup/` (registration from the wrong peer → 403, stale node not selectable, `PUT` naming an unknown/disabled node → 409, unknown preset name → 409, `revision` conflict → 409, audit line per request, unauthenticated GET → 401, `PUT` by a reader → 403, `clear` with a missing or mismatched `confirm` → 400, unknown `scope` → 400, `clear` with scope `b2` on a subject whose `offsite` is already false → 409); the preset names the API accepts are exactly the ones the node published, so the UI cannot offer a keep-set the node will not run; `cnt backup-policy list` shows the resolved view; `turn off` on one service writes `target=none` and the next `fleet-backup` run logs a skip with no snapshot and no deletion; `clear` from a client's credentials → 403 (no route exists, and the client holds no node key); a `clear <svc> local` leaves the target set and the next run `init`s a fresh repo (new repo ID, one snapshot); a `clear <svc> b2` also writes `offsite=false` in the same audited operation, and the next copier run adds no offsite repo; the dashboard's per-service and total `$/mo` equal `size × rate` for one hand-computed row |
| 3 | pruner `--dry-run` first: `restic forget --prune --group-by '' <preset>` per repo on the node reports **one** policy group and the keep-set the clients report today (`keep 7 daily, 5 weekly, 12 monthly, 3 yearly` for `standard`); the failure mode to watch for is 4 groups and nothing removed, which is what the default grouping does (§3.2). Then for real and `restic check` is clean per repo; a service switched to `short` prunes to `short` on the next timer tick and only that repo's history shrinks in the size column; `cnt restore-check <svc>` for one service on lio and on h003 after their first run; `sudo fleet-restic -r rest:http://100.64.0.17:8000/<svc>/ snapshots` shows that service's history on the node the policy names and is 401 for any other `svc-*`; `systemctl start fleet-backup` exits 0 **and its log has no `Applying Policy` line** — that absence is the evidence the client prune is gone; stop the API and confirm the cached `target.json` keeps the run working, delete the cache and confirm it fails rather than guesses |
| 4 | h001: full run, then `cnt restore-check forgejo` (3 PG dumps) and `cnt restore-check puzzles` (2 SQLite), then a real `cnt move` of `hello-nixos` exercising **all three** preflight checks (§3.7), including the one that must *fail*: a move to a destination whose key set lacks the service's repo; the media series appears in `host-h001` on the node and the UI's local-size column for it is within a few percent of `du` on the media tree; every `init --copy-chunker-params`/`copy --from-repo` in §4 step 4 is run verbatim with **distinct** source and destination password files and stdin closed (`</dev/null`) and must exit 0 without prompting — the source password is passed as `--from-password-file`, never a second `-p`, since only the last `-p` counts and it is the destination's (measured: the `-p`-twice form exits 1 at `an empty password is not allowed`) |
| 5 | copier leaves `lastCopied` fresh per subject; **each subject has its own B2 repo** (`restic -r b2:<bucket>:svc-<name> snapshots` works with only that subject's password, and every other subject's password answers `wrong password or no key found`); **the first copy into each new (empty) `svc-<name>` repo is a full upload** — its `restic stats --mode raw-data` at B2 lands within a few hundred bytes of the local repo's, not at a few KB (§3.4); **subsequent copies are incremental** — a re-run with no new local snapshots grows the destination by 0 bytes, and a run after one new backup grows it by ≈ that backup's raw size; the media handover is the opposite shape and is checked as such, since `7f023d4a` is already populated: it grows by index and metadata only (964 bytes measured, §3.4), and if it grows by hundreds of GiB it is not landing on the existing blobs; two services set to different B2 presets (`short` and `long`) keep exactly those keep-sets after one prune tick, which is only possible because each is its own repo; `clear <a> b2` leaves `b`'s B2 repo, snapshot count and `lastCopied` byte-for-byte unchanged and flips only `a`'s `offsite`; a service with `offsite: false` gains no B2 snapshot that night; the media handover: `restic diff <copied> <local>` for the newest `host-h001` snapshot is empty, the copied snapshots carry the `h001` tag, `restic -r 7f023d4a snapshots` still exists after `clear host-h001 b2` (only its `h001` rows went), and `offsite-b2.json`'s byte count for `7f023d4a` minus the measured legacy bytes equals the local `host-h001` raw-data count after the scoped prune — that equality is the evidence no unassociated bytes remain |
| 5 (revocation gate, §4 step 7) | After the node's new, separate prefix-scoped key is verified working: `svc-*` and `7f023d4a` writable, an unrelated prefix (e.g. `scratch-`) refused by B2; the old role grant is removed and `sec` deployed; every former consumer's hydrated copy is absent; fetching `machines/high-trust/restic_h001_env_2026-10-01` from a high-trust host fails; B2 access with the old application key fails (`restic snapshots` with the old env → authentication error); the node's new key still reads and copies successfully; the old B2 *secret* is gone fleet-wide, while the media repo's password stays valid on the node and in the break-glass record — rotating it would strand the offsite copy |
| 5 (legacy-row deletion gate, §4 step 9) | Not before a week of fresh `lastCopied`, and the record is a week old: `restic check --read-data-subset=5%` on `7f023d4a` is clean; **every** `offsite: true` subject has its own `svc-<name>` B2 repo recorded complete in `offsite-b2.json`; `restic ls <latest>` succeeds from B2 alone for one container subject and for the media, using only the break-glass passwords; `offsite-b2.json` shows zero unassociated bytes for the media. Then, and only then, the legacy `fleet`/`svc:*` rows are forgotten; the bucket, `7f023d4a` itself and every `svc-<name>` repo are **not** deleted |
| 5 (completeness gate, §3.4) | The gate matches on `(.original // .id)`, never the raw ID: for a fixture copied A→B→C, jq selecting that field per row on A and C yields the same key, while the raw `.id` sets intersect in **0** — a raw-ID gate fails a correct copy, so assert the mapped gap is empty *and* the literal gap is not. The **expected set is the B2 preset applied to the local series** (`restic forget --dry-run --json <B2 preset> --group-by ''` on the local repo), not every local snapshot: with `retentionB2` shallower than `retentionLocal`, six copies pruned at B2 to `--keep-daily 2` leave four local keys legitimately absent, and a whole-local set fails forever. Fixture assertion for that: shallow-B2 fixture passes, and the same fixture with one extra local snapshot never copied **fails**; assert the destination-side dry-run variant misses that gap, so nobody "simplifies" it back. Real subject: expected keys minus destination keys = ∅ (subset — the media's extra legacy rows must not fail it), every matched key agrees on `time`, `hostname`, `paths`, `tags` and `tree`, and a prune lag (destination holds fewer rows than its own preset would keep) reports the lag rather than passing. Also assert a second hop preserves the chain: C's `original` = A's `id`, and a copy back into the repo that originated the history is no exception (destination keeps its own ID, the local copy carries it in `original`) |
| 6 | docs only: `grep -rn "restic_h001_env" containers/ hosts/ ideas/` returns nothing, `grep -rn "restic_repo_" containers/ hosts/` names exactly one key per subject, and `grep -rn "only h004" containers/` names no node as the sole B2 key holder |

## 6. Open questions

- **One repo per subject: decided, and what it costs.** Isolation is the
  requirement, so each service/host subject gets its own repo with its own
  password and its own htpasswd user (§3.1, §3.5), and at B2 each subject is its
  own repo and its own key (§3.4). Accepted losses: no cross-host or
  cross-subject dedup, locally or off site; no single `latest` across nodes; and
  an extra `restic init` + secret per new service, and one full first upload into
  each new empty repo. None of it matters against a 31.2 GiB container set: that
  upload is ~31 GiB moved once, and the duplication afterwards is ~$0.21/mo of
  storage; the media keeps its 484.9 GiB repo, so the bill is unchanged. Revisit
  only if a subject ever needs to share history with another (it would then be
  one subject, not two repos).
- **`joe`**: low-trust today and the only container host with no backup. A
  rest-server user on a backup node is far safer than the B2 key it would have
  needed, but `localai` also needs `/srv/containers/localai/{models,backends}`
  excluded first, and `firewallHighTrustIps` filters on `trust == "high"` so a
  low-trust host must be added to the node's allow-list by hand (§3.6). Deferred
  until it should be a move destination.
- **What does `none` do to an existing series?** Nothing, deliberately: it stops
  new snapshots and leaves the series to its preset, and a frozen series settles
  rather than disappearing — `forget` keeps the newest snapshots a keep-set names
  and only removes older ones, so no new snapshots means no further shrinking.
  `cnt move` refuses until the service is pointed at a node again. That is the
  only behaviour that does not make a selectable UI value silently delete data, so
  the doc states it rather than asking; the option text says it too. *Turn off* in
  the UI is exactly this value, and only a scoped *clear* (§3.3b) deletes:
  `local`, `b2` or `both`, separate, confirmed, and executed by the node.
- **What if the node is down at 03:00?** The unit has
  `ConditionPathExists = bcfg.environmentFile` (`host-module.nix:413`) plus
  `Persistent = true` / `RandomizedDelaySec = 15m` (`host-module.nix:1281-1282`),
  so the run is skipped and retried rather than failing loudly; the dashboard's
  stale flag is the only signal, and there is no alert (`ROUTING-PLAN.md` §9.1
  open items). This plan does not add one, but it makes the *node* a second thing
  whose availability matters — and with several nodes, a plural one. The alerting
  work should cover each node's prune and copy units, its `:8000` listener, and
  the copier's `lastCopied`; until it does, the per-service B2 size and
  `lastCopied` columns (§3.3b) are how a node that is up but not copying stays
  visible rather than looking healthy.
- **Where does a second node's copy land?** The same place: the B2 path is keyed
  by *subject*, not by node (`b2:<bucket>:svc-<name>`, §3.4), so a second node
  adds no bucket prefix to plan. What it must not do is copy the same subject at
  the same time as the first, and it cannot: the copier only copies services whose
  resolved `target` is *itself* (§3.3a point 5), so the policy edit that moves a
  service is what hands the offsite series from one node to the other. The local
  side still forks by node (its `svc-<name>` is a separate repo — same inherited
  chunker, independent history, §3.3a point 1), so a node change is accompanied by
  that two-password `restic copy` locally; B2 keeps one continuous `svc-<name>`
  repo either way.
- **What does the offsite copy *not* contain?** Repo metadata: a B2 repo holds
  snapshots, blobs, index and keys of *itself*, not the local repo's. Restores
  from B2 are therefore self-contained, but the local repo's password cannot be
  recovered from it — and with per-subject passwords that is now one password per
  subject, held in the password manager (`ROUTING-PLAN.md` §9.3) alongside the
  bucket key. Break-glass set = those passwords + the bucket key(s), and it
  changes whenever a subject's repo is re-`init`ed. After §4 step 8 the
  break-glass media copy is the media subject inside `7f023d4a` — the same repo,
  one subject, everything else pruned at step 9 — and every container subject is
  its own entry in the same record. That record gains an entry per node too,
  because keys are per node (§3.4).
- **Unverified**: the node deployment itself — the socket-activated listener under
  the module's `PrivateNetwork`/`PrivateUsers`/`RestrictAddressFamilies = "none"`
  hardening, the firewall rule as written, and the split §3.5a introduces — the
  root `render-htpasswd` oneshot reading root-0400 hydrated secrets, and whether
  rest-server starts on an *empty* render (a boot with no hydrated subject secret
  yet, which §3.5a intends to be a valid empty file). The two pieces of that
  split that *are* measured are recorded there: a file `ReadOnlyPaths` bind does
  not pin a stale inode across the renderer's `rename(2)`, and `htpasswd -niB`
  with the password on **stdin** and only the username on argv produces a
  verifying line without a TTY — both on the workstation with apache-httpd
  2.4.69, not in the unit. So the remaining question on the render is whether it
  can read the secrets and run at all under that unit's own hardening. The node
  deployment has only been tested on loopback fixtures with
  `systemd-socket-activate`, not on h004. Phase 1's whole job is to prove it
  there before any host's data depends on it. Also unmeasured: the first `restic
  stats --mode raw-data` against the 484.9 GiB media B2 repo walks the index and
  will take minutes, so the UI must render a cached number with its timestamp and
  never block a page load on it; and the hourly stats timer's cost on the nodes'
  own CPU is unmeasured for the media repo (it may need to be daily).
