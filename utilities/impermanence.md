# Impermanence

Fleet hosts that opt into `ringofstorms.impermanence` (see
`flakes/impermanence/bcachefs-impermanence.nix`) use a **bcachefs**
subvolume layout rather than Btrfs. On every boot, an initrd stage
snapshots the current root, then deletes and recreates it empty, so `/`
starts fresh each boot while a few explicit paths survive under
`/persist`.

## Subvolume layout

A single bcachefs filesystem (optionally encrypted, optionally unlocked
via a USB key) holds these subvolumes, mounted via `X-mount.subdir=`:

- `@root` — mounted at `/`. Wiped and recreated on every boot.
- `@persist` — mounted at `/persist`. Durable state that survives
  reboots; this is the target of `environment.persistence."/persist"`
  entries declared per-host in `impermanence.nix` (and the shared sets
  in `flakes/impermanence/shared_persistence/`).
- `@snapshots` — mounted at `/.snapshots`. Holds `old_roots/<timestamp>`,
  a snapshot of `@root` taken immediately before each wipe.

The boot-time reset logic lives in `bcachefs-impermanence.nix`: if
`/primary_tmp/@root` doesn't exist it's created; otherwise it's
snapshotted to `/primary_tmp/@snapshots/old_roots/<timestamp>` and then
deleted/recreated empty before pivoting into the real root.

See `flakes/impermanence/disko-bcachefs.nix` for the disko partitioning
that creates `@root`, `@nix`, `@persist`, and `@snapshots` up front.

## `bcache-impermanence` CLI

Hosts with impermanence enabled ship a `bcache-impermanence` script
(from `flakes/impermanence/impermanence-tools.sh`) for inspecting and
managing `/.snapshots/old_roots`:

```sh
# List snapshots, newest first (prefix with -nN to limit to N latest)
bcache-impermanence ls
bcache-impermanence ls -n5

# Browse/diff files between the current system and a snapshot.
# Defaults to the latest snapshot if -s is omitted; pass path prefixes
# to narrow the scan, --max-depth to limit recursion.
bcache-impermanence diff
bcache-impermanence diff -s 2026-10-01_12-00-00 /etc /var/lib

# Garbage-collect old snapshots: keeps the N most recent, at least one
# per calendar month, and one per ISO week within the recent window.
bcache-impermanence gc --dry-run
bcache-impermanence gc --keep-recent-count 5 --keep-per-month 1 --keep-recent-weeks 4
```

Run `bcache-impermanence --help` or `bcache-impermanence <subcommand>
--help` for the full option list (`--snapshot-root` to point at a
non-default location, etc).

## Manual fallback: rsync/diff against a snapshot

If the CLI isn't available (or for an ad-hoc comparison), the snapshots
are just plain directories under `/.snapshots/old_roots`, no special
mounting required:

```sh
LATEST_SNAPSHOT=$(ls -t /.snapshots/old_roots/ | head -n 1)
SNAPSHOT_PATH="/.snapshots/old_roots/$LATEST_SNAPSHOT"
echo "Comparing against snapshot: $SNAPSHOT_PATH"

# Option A: rsync (dry-run, shows what changed since that boot)
sudo rsync -rcai --delete --dry-run \
  --exclude='/@*' \
  --exclude='/nix' \
  --exclude='/proc' \
  --exclude='/sys' \
  --exclude='/dev' \
  --exclude='/tmp' \
  --exclude='/boot' \
  --exclude='/persist' \
  --exclude='/.snapshots' \
  --exclude='/.swap' \
  /var/lib/ "$SNAPSHOT_PATH/var/lib/"

# Option B: diff (can be very noisy, but effective for small subtrees)
sudo diff -qr /var/lib "$SNAPSHOT_PATH/var/lib"
```
