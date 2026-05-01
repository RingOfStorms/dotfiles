# h002 bcachefs erasure-coding migration (research + plan)

Captured 2026-05-01 after the r/bcachefs v1.37.0 announcement
(<https://www.reddit.com/r/bcachefs/comments/1rukym4/v1370_erasure_coding/>).

This file is **not a plan to execute now** — it's a record of what we want
to do, why we're waiting, and exactly what to do when the blockers clear.
The current production state is `--replicas=2` on 5 HDDs (50% usable),
which works fine; this migration is about reclaiming usable capacity
from ~22 TB to ~33 TB without giving up single-drive failure tolerance.

## Status / TL;DR

- **Decision (2026-05-01):** Wait. Do not enable EC on `/data` yet.
- **Why we're waiting:** bcachefs filesystem version 1.38 is when the
  experimental label is expected to come off and when the allocator work
  lands that makes EC scrub/resilver fast. Kent Overstreet (upstream
  maintainer) said in the v1.37 thread:
  > "Without the allocator work EC scrub and resilver will be painfully
  > slow, and cleanup code should arrive eventually but I'm not making
  > promises at this time."
  We do not want a "painfully slow" rebuild on a 44 TB array if a drive
  dies.
- **Standing trigger to revisit:** v1.38 lands in mainline kernel **and**
  has been in the wild for ~1-2 months without major reports of EC
  corruption / migration regressions.

## Blocker checklist — check these before starting Phase 2

Run these to see if we're unblocked. All four must be ✅.

1. **Upstream bcachefs filesystem version ≥ 1.38 released.**
   - Watch <https://evilpiepirate.org/git/bcachefs.git> commit log for
     the `BCH_VERSION(1, 38)` bump.
   - Or watch r/bcachefs for the "v1.38" announcement post (Kent posts
     each release there).
2. **Mainline Linux kernel containing fs v1.38 has shipped.**
   - v1.37 landed in Linux 6.18 (~Nov 2025). v1.38 will likely be in
     6.19 or 6.20.
   - Check: `HOME=/tmp/nixhome nix eval --impure --expr '(import
     (builtins.getFlake "github:nixos/nixpkgs/nixos-unstable") { system =
     "x86_64-linux"; }).linuxPackages_latest.kernel.version'`
   - Cross-check the kernel changelog (`Documentation/filesystems/bcachefs/`
     or `fs/bcachefs/bcachefs_format.h` `BCH_VERSION` macro) actually
     contains v1.38.
3. **`bcachefs-tools` in our nixpkgs channel ≥ 1.38.**
   - As of writing, nixos-25.11 already has `bcachefs-tools 1.38.0`
     (sufficient for EC userspace; was already current at the time of
     this doc). Re-verify before migration just in case it regressed:
     `HOME=/tmp/nixhome nix eval --impure --expr '(import (builtins.getFlake
     "github:nixos/nixpkgs/nixos-25.11") { system = "x86_64-linux";
     }).bcachefs-tools.version'`
4. **Community shakedown OK.**
   - Skim r/bcachefs and the bcachefs mailing list / matrix for at least
     a month after v1.38's kernel release. Look for:
     - reports of corruption during `bcachefs data rereplicate`
     - reports of EC stripes failing to allocate on mixed-size arrays
     - any "do not upgrade if you have EC enabled" warnings

If any are ❌, stop and revisit later. The current `replicas=2` setup is
fine; there's no urgency.

## Why we're doing this at all

Current `/data` array on h002:

```
sda  10.9 TB HDD   ┐
sdb  10.9 TB HDD   │
sde  10.9 TB HDD   ├─ all in /data, --replicas=2 --compression=zstd
sdf  10.9 TB HDD   │
sdc   0.7 TB HDD   ┘

sdd  120 GB SSD    boot drive (ext4 /), not in array
```

- Raw: ~44.3 TB
- With `replicas=2`: ~22.1 TB usable (50% efficiency)
- Currently using ~10 TB of that
- With EC `redundancy=1` across all 5 drives: **~33 TB usable** (~75% efficiency)
- Same single-drive-failure tolerance as today
- Reclaims ~11 TB without buying any drives

We don't have anywhere to stash 10 TB of media externally, so this needs
to be an in-place migration. bcachefs supports that via online option
changes + `bcachefs data rereplicate`.

## Key design decisions (locked in)

| Decision | Choice | Reasoning |
|---|---|---|
| Drives in EC data target | **All 5 HDDs** | sdc (700 GB) is the same media class as the others; segregating it would only save ~700 GB and complicate operations. Allocator handles smallest-drive-fills-first automatically by narrowing stripe width. |
| `data_replicas` | **1** | EC provides the redundancy; storing replicas on top would defeat the point. |
| `metadata_replicas` | **2** (unchanged) | Metadata is **not** erasure-coded in bcachefs — only data extents are. Metadata is <1% of array, so cost of replication is negligible, and a single bad metadata block can corrupt the whole FS. Non-negotiable. |
| `erasure_code` | **1** (on) | The actual switch. |
| Stripe redundancy | **1** (RAID5-like) | One parity bucket per stripe, survives one drive loss. Matches current single-drive tolerance. The data on `/data` is media — recoverable via re-procurement, just bandwidth-expensive — so we accept the lower margin in exchange for max usable space. |
| Per-device labels / targets | **None** | No `--label` / `--foreground_target` / `--metadata_target` / `--background_target` plumbing. All drives are the same class, the SSD is not in this array. Keep the FS config flat. |
| Backup before migration | **None** | We have nowhere to put 10 TB. Mitigation = wait for v1.38 + community shakedown so the migration code is well-tested. |
| Migration style | **In-place, online** | Filesystem stays mounted throughout. Background rebalance via `bcachefs data rereplicate`. nixarr / NFS keep working (slower). |

## Conceptual notes (so future-me doesn't re-confuse this)

**Replicas vs EC redundancy** — different mechanisms, can stack but
shouldn't:

- `data_replicas=N` = make N full copies of every extent (mirroring).
  Cost: N× space.
- `erasure_code=1` + `redundancy=N` = compute N Reed-Solomon parity
  blocks per stripe across multiple devices. Cost: N drives' worth of
  parity per stripe (not per byte).

bcachefs EC is **striped with rotating parity** (RAID5/6-style), not
**dedicated-parity-drive** (SnapRAID/unRAID-style). This means:

- Stripes are small (bucket-sized, ~512KB-2MB), spread across N devices
- Parity rotates across devices — there is no "parity drive"
- Can't read a single drive standalone; data is fragmented across all
  drives in the stripe
- No RAID hole, because bcachefs only writes full stripes (COW); never
  updates an existing stripe in place

The smallest drive (sdc) does **not** cap stripe size in any meaningful
way. Each stripe is just megabytes. What happens is sdc fills up after
contributing ~700 GB of buckets, then the allocator naturally builds
4-wide stripes on the remaining HDDs only. Mixed stripe widths in the
same FS are fine.

## Phase 1: Wait & monitor (NOW until blockers clear)

No file changes. Just periodically run the blocker checklist above.

## Phase 2: NixOS prep (when blockers clear)

The only NixOS-level change needed is pinning a kernel new enough to
contain bcachefs filesystem v1.38. Currently `hosts/h002/` does not set
`boot.kernelPackages`, so it inherits nixpkgs default (6.12 LTS as of
this writing — too old).

Edit `hosts/h002/hardware-configuration.nix`. Add `pkgs` to the function
args and pin the kernel:

```nix
{
  config,
  lib,
  modulesPath,
  pkgs,                                            # <-- add
  ...
}:
{
  # ...
  boot.supportedFilesystems = [ "bcachefs" ];
  boot.kernelPackages = pkgs.linuxPackages_latest; # <-- add
  # ...
}
```

Then:

```sh
# from a workstation with the repo checked out
nixos-rebuild switch --flake ./hosts/h002#h002 --target-host h002
# verify
ssh h002 'uname -r && bcachefs version'
```

The mount config (`fileSystems."/data"`) does **not** change yet. EC
settings live in the bcachefs superblock, not in fstab — they're
toggled by `bcachefs set-fs-option`.

## Phase 3: The actual migration (online, on h002)

All commands run as root on h002. **Read each one before pasting.**

### 3a. Pre-flight health check

```sh
# Confirm we're on a kernel/tools combo that can do EC
uname -r
bcachefs version

# Current state of the array
bcachefs fs usage -h /data
bcachefs show-super /dev/sda | grep -E 'version|features|replicas|erasure'

# Dry-run fsck — must complete clean. If it reports errors, STOP and
# fix them before continuing.
bcachefs fsck -n /dev/sda /dev/sdb /dev/sdc /dev/sde /dev/sdf
```

If usage shows we're at >25 TB used (which would be impossible at
current replicas=2 since usable is ~22 TB, but sanity-check anyway),
stop — the math doesn't work.

### 3b. Flip the EC switches

```sh
# Turn on erasure coding
bcachefs set-fs-option --erasure_code=1 /data

# Drop data replicas to 1 (EC provides redundancy from here on)
bcachefs set-fs-option --data_replicas=1 /data

# DO NOT touch metadata_replicas — leave at 2.
# Sanity-check it stayed at 2:
bcachefs show-super /dev/sda | grep -i replica
```

Expected: `metadata_replicas: 2`, `data_replicas: 1`, `erasure_code: 1`.

At this point **new writes** start going into EC stripes. Existing data
is still stored as 2× replicas. Step 3c rewrites it.

### 3c. Trigger background rewrite

```sh
# Rewrite all existing data according to current options.
# This is the long-running part. Survives across remounts.
bcachefs data rereplicate /data
```

Expect **multiple days** to chew through ~10 TB on spinning rust. The
filesystem stays mounted and usable throughout. NFS / nixarr stay up.

### 3d. Monitor progress

```sh
# Run on a long-lived ssh session (tmux on h002 — already enabled via
# common.nixosModules.tmux):
watch -n 30 'bcachefs fs usage -h /data'
```

Look for:
- `Replicated:` line shrinking over time
- `Erasure coded:` (or similar) line growing
- Total usable capacity (the `Free:` figure) increasing
- No I/O errors in `dmesg -w` in another pane

### 3e. Verify completion

When `Replicated:` is near zero (just metadata, which stays at 2×):

```sh
bcachefs fs usage -h /data
df -h /data
# Expect free space jumped by ~10-11 TB compared to before.

# Optional but recommended: full scrub to verify EC stripes are good
bcachefs data scrub /data
```

### 3f. Commit the post-migration state to git

Update the comment block in `hosts/h002/hardware-configuration.nix` so
future-me knows the layout:

```nix
fileSystems."/data" = {
  device =
    # 2026-NN-NN: migrated from --replicas=2 to EC redundancy=1
    # Layout: 5x HDD (4x 10.9 TB + 1x 0.7 TB), all in single data target
    # Settings: data_replicas=1, metadata_replicas=2, erasure_code=1
    # Tolerates: 1 drive loss (matches pre-migration tolerance)
    "UUID=53a26b95-941b-4f41-b049-c166905ed8c2";
  fsType = "bcachefs";
  options = [
    "defaults"
    "x-systemd.device-timeout=600s"
    "nofail"
  ];
};
```

No mount-option change required.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| EC implementation bug corrupts data during `data rereplicate` | The whole reason we're waiting for v1.38 + a month of community shakedown. |
| Power loss mid-migration | bcachefs handles this safely per Kent (assumes drives honor FUA). h002 is on the workshop UPS. |
| `metadata_replicas=1` reduces FS resilience | Not doing this. Staying at 2. |
| Rebuild after a real drive failure with EC is "painfully slow" | This is the whole reason we're waiting for v1.38's allocator work. |
| sdc (smallest drive) interacts weirdly with EC stripe allocation | Allocator handles narrowing stripe width automatically; mixed widths are supported. If observed in practice during community shakedown phase, reconsider excluding sdc. |
| Want to undo EC after the fact | `bcachefs set-fs-option --data_replicas=2 --erasure_code=0 /data && bcachefs data rereplicate /data`. Only works if free space allows the doubling — which it won't if we've filled past ~22 TB. So the rollback window closes once usage exceeds the old replicas=2 capacity. |

## Open questions to research closer to migration day

- Does `bcachefs data rereplicate` need a specific flag in v1.38 to
  prefer EC over remaining as replicas? (The v1.37 changelog wording
  suggested it's automatic given current options, but verify.)
- Is there a way to throttle the rereplicate I/O so nixarr / Plex
  streams stay smooth? Check for `--rate=` or similar at the time.
- Confirm `bcachefs data scrub` exists and is the right post-migration
  verification command in the v1.38 tools (subcommand names have
  shifted across releases).
- Whether v1.38 introduces any new mount options worth setting (e.g.
  EC-related tuning).

## Files this plan will touch when executed

- `hosts/h002/hardware-configuration.nix` — add `pkgs` arg, add
  `boot.kernelPackages = pkgs.linuxPackages_latest;`, update `/data`
  comment block post-migration.

That's it. No other NixOS config changes. Everything else is live
`bcachefs` commands run on the host.
