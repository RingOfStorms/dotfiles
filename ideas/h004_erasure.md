# h004 bcachefs erasure-coding migration (research + plan)

Originally captured 2026-05-01 after the r/bcachefs v1.37.0 announcement (<https://www.reddit.com/r/bcachefs/comments/1rukym4/v1370_erasure_coding/>); updated 2026-10-23 after the `h002` → `h004` hardware rebuild and 5th 12 TB drive addition.

This file is **not a plan to execute now** — it's a record of what we want to do, why we're still waiting, and the exact online procedure once upstream EC stabilizes.

## Status / TL;DR

- **Decision (2026-10-23):** **Keep waiting.** Do not enable EC on `/data` yet.
- **What's already done on `h004`:**
  - `h004` is running **Linux 6.18.56** with **`bcachefs-tools` 1.39.6**, and the `/data` pool has already been upgraded on-disk to **bcachefs format v1.39** (`hosts/h004/readme.md:52-57`).
  - The old 750 GB Seagate hybrid (`ST750LX003`) was removed from the pool and formatted as a standalone `/scratch` mount (`hosts/h004/data-pool.nix:27-38`).
  - A 5th 12 TB drive (WD Red Plus `WD-B01XWD2D`) was burned in and added to `/data` (`hosts/h004/readme.md:29`). The pool is now a homogeneous **5× 12 TB array (50.2 TB raw)**.
- **Why we're still waiting:** Even though we are past filesystem v1.38 (now on v1.39), upstream bcachefs is still landing frequent EC (erasure coding) bugfix commits (stripe allocation, rebalance/evacuate edge cases, scrub/resilver stability). We have no external place to back up 10+ TB of media, so we are waiting until the rate of upstream EC bugfixes drops and community reports settle before flipping `--erasure_code=1` on `/data`.

## Standing Trigger to Revisit

Check these before starting the migration:

1. **Upstream EC commit churn has quieted down.**
   - Check <https://evilpiepirate.org/git/bcachefs.git> commit log (`fs/bcachefs/ec.c`, `rebalance.c`, `alloc_*.c`) and r/bcachefs release threads.
   - Ensure there are no recent reports of corruption or stuck `data rereplicate` / `device evacuate` runs on EC arrays.
2. **Scrub / resilver performance verified in the wild.**
   - Confirm that single-drive rebuilds (`bcachefs device evacuate` / degraded resilver) and `bcachefs data scrub` complete at reasonable speeds without hanging.

If EC bugfixes are still actively churning upstream, **wait**. Current `replicas=2` gives ~25.1 TB usable and works reliably.

---

## Current `/data` Layout on `h004`

See `hosts/h004/readme.md` and `hosts/h004/data-pool.nix`:

```
4× Seagate IronWolf Pro 12 TB (ST12000NT001: ZRT2KQXT, ZRT2LRT8, ZRT2FJ7X, ZRT2GA17) — onboard Intel B860 SATA
1× WD Red Plus 12 TB          (WD-B01XWD2D)                                          — Vantec JMB585 PCIe SATA card
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
5× 12 TB HDD in /data (UUID=53a26b95-941b-4f41-b049-c166905ed8c2), --replicas=2 --compression=zstd

Boot:    Inland TN320 256 GB NVMe (encrypted bcachefs + impermanence, not in /data pool)
Scratch: Seagate ST750LX003 750 GB hybrid (standalone unencrypted bcachefs at /scratch, not in /data pool)
```

- **Raw capacity:** 50.2 TB (5× 12 TB, homogeneous sizes — no mixed-size stripe width edge cases anymore)
- **With `replicas=2` (today):** ~25.1 TB usable (50% efficiency)
- **With EC `redundancy=1` (4+1 RAID5-style stripes across 5× 12 TB):** **~40.1 TB usable** (80% efficiency)
- **Gain:** Reclaims **~15 TB** of usable capacity with the same single-drive failure tolerance

---

## Key Design Decisions (Locked In)

| Decision | Choice | Reasoning |
|---|---|---|
| Drives in EC data target | **All 5× 12 TB HDDs** | Homogeneous 12 TB drives (the 750 GB drive is already isolated on `/scratch`). Every full stripe is 4 data + 1 parity across all 5 disks (80% efficiency). |
| `data_replicas` | **1** | EC provides the redundancy; storing replicas on top would defeat the point. |
| `metadata_replicas` | **2** (unchanged) | Metadata is **not** erasure-coded in bcachefs — only data extents are. Metadata is <1% of array, so 2× replication cost is negligible and protects the FS tree. Non-negotiable. |
| `erasure_code` | **1** (on) | Enables Reed-Solomon parity stripes. |
| Stripe redundancy | **1** (RAID5-like, 4+1) | Survives 1 drive loss, matching current `replicas=2` tolerance. `/data/nixarr` is replaceable media; critical fleet backups live on Backblaze B2, not `h004`. |
| Migration style | **In-place, online** | Filesystem stays mounted throughout. Background rewrite via `bcachefs data rereplicate /data`. |

---

## Conceptual Notes

- `data_replicas=N` = N full copies of every extent (mirroring).
- `erasure_code=1` + `redundancy=1` = Reed-Solomon parity blocks across devices in bucket-sized stripes (~512 KB–2 MB) with rotating parity.
- Because bcachefs only writes full stripes copy-on-write (COW) and never updates a stripe in place, there is **no RAID5 write hole**.

---

## Execution Procedure (When Unblocked)

No NixOS kernel/package prep is needed anymore (`h004` is already on nixos-26.05 with bcachefs 1.39+). All commands run as root on `h004`.

### 1. Pre-Flight Health Check

```sh
uname -r
bcachefs version

# Verify all 5 drives are healthy and array is undegraded
bcachefs fs usage -h /data
bcachefs show-super /dev/disk/by-id/ata-ST12000NT001-3LX101_ZRT2GA17 | grep -E 'Version|features|replicas|erasure'

# Dry-run fsck — must complete clean before touching options
bcachefs fsck -n /data
```

### 2. Flip the EC Switches

```sh
# Turn on erasure coding
bcachefs set-fs-option --erasure_code=1 /data

# Drop data replicas to 1 (EC provides redundancy from here on)
bcachefs set-fs-option --data_replicas=1 /data

# Verify metadata_replicas stayed at 2:
bcachefs show-super /dev/disk/by-id/ata-ST12000NT001-3LX101_ZRT2GA17 | grep -i replica
```

Expected: `metadata_replicas: 2`, `data_replicas: 1`, `erasure_code: 1`.

### 3. Trigger Background Rewrite

```sh
# Run inside tmux on h004; survives across remounts
bcachefs data rereplicate /data
```

Expect multiple days on spinning rust. Monitor progress with:

```sh
watch -n 30 'bcachefs fs usage -h /data'
```

### 4. Verify Completion & Scrub

```sh
bcachefs fs usage -h /data
df -h /data
bcachefs data scrub /data
```

### 5. Document in Repo

Update the header comments in `hosts/h004/data-pool.nix` and `hosts/h004/readme.md` from `replicas=2` to `data_replicas=1, metadata_replicas=2, erasure_code=1 (5× 12 TB, 4+1 EC)`.
