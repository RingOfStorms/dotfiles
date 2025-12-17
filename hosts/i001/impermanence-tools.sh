#!/usr/bin/env bash
set -eu

SNAPSHOT_ROOT="/.snapshots/old_roots"
KEEP_PER_MONTH=1
KEEP_RECENT_WEEKS=4
KEEP_RECENT_COUNT=5
DRY_RUN=0

usage() {
  cat <<EOF
bcache-impermanence - tools for managing impermanence snapshots

Usage:
  bcache-impermanence gc [--snapshot-root DIR] [--keep-per-month N] [--keep-recent-weeks N] [--keep-recent-count N] [--dry-run]
  bcache-impermanence ls [-n1] [--snapshot-root DIR]
  bcache-impermanence diff [-s SNAPSHOT] [--snapshot-root DIR] [PATH_PREFIX...]

Subcommands:
  gc    Run garbage collection on old root snapshots.
  ls    List snapshots (newest first). With -n1 prints only latest.
  diff  Show diff between current system and a snapshot.

Options:
  --snapshot-root DIR        Override snapshot root directory (default: /.snapshots/old_roots).
  --keep-per-month N         For gc: keep at least N snapshots per calendar month.
  --keep-recent-weeks N      For gc: keep at least one snapshot per ISO week within the last N weeks.
  --keep-recent-count N      For gc: always keep at least N most recent snapshots overall.
  --dry-run                  For gc: show what would be deleted.
EOF
}

ensure_deps() {
  for cmd in date sort basename diff bcachefs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

list_snapshots_desc() {
  if [ ! -d "$SNAPSHOT_ROOT" ]; then
    return 0
  fi
  for entry in "$SNAPSHOT_ROOT"/*; do
    [ -d "$entry" ] || continue
    basename "$entry"
  done | sort -r
}

latest_snapshot_name() {
  list_snapshots_desc | head -n1
}

cmd_ls() {
  local n1=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n1)
        n1=1
        ;;
      --snapshot-root)
        shift
        [ "$#" -gt 0 ] || { echo "--snapshot-root requires a value" >&2; exit 1; }
        SNAPSHOT_ROOT="$1"
        ;;
      --help|-h)
        echo "Usage: bcache-impermanence ls [-n1] [--snapshot-root DIR]" >&2
        exit 0
        ;;
      *)
        echo "Unknown ls option: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  local snaps
  snaps=$(list_snapshots_desc)

  if [ -z "$snaps" ]; then
    echo "No snapshots found in $SNAPSHOT_ROOT" >&2
    exit 1
  fi

  if [ "$n1" -eq 1 ]; then
    printf '%s
' "$snaps" | head -n1
  else
    printf '%s
' "$snaps"
  fi
}

build_keep_set() {
  # Prints snapshot names to keep, one per line, based on policies.
  local now
  now=$(date +%s)

  local snaps
  snaps=$(list_snapshots_desc)

  if [ -z "$snaps" ]; then
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  # Always keep newest KEEP_RECENT_COUNT snapshots.
  if [ "$KEEP_RECENT_COUNT" -gt 0 ]; then
    printf '%s
' "$snaps" | head -n "$KEEP_RECENT_COUNT" >"$tmpdir/keep_recent"
  fi

  # Per-month: keep up to KEEP_PER_MONTH newest per month.
  if [ "$KEEP_PER_MONTH" -gt 0 ]; then
    # Iterate newest -> oldest.
    while read -r snap; do
      [ -n "$snap" ] || continue
      local month
      month=${snap%_*}  # YYYY-MM-DD
      month=${month%-*} # YYYY-MM
      local month_file="$tmpdir/month_$month"
      local count=0
      if [ -f "$month_file" ]; then
        count=$(wc -l <"$month_file")
      fi
      if [ "$count" -lt "$KEEP_PER_MONTH" ]; then
        echo "$snap" >>"$month_file"
      fi
    done <<EOF_SNAPS
$snaps
EOF_SNAPS
  fi

  # Recent weeks: keep latest snapshot per week within last KEEP_RECENT_WEEKS weeks.
  if [ "$KEEP_RECENT_WEEKS" -gt 0 ]; then
    local max_age
    max_age=$(( KEEP_RECENT_WEEKS * 7 * 24 * 3600 ))
    while read -r snap; do
      [ -n "$snap" ] || continue
      local ts
      ts=$(date -d "${snap%_*} ${snap#*_}" +%s 2>/dev/null || true)
      [ -n "$ts" ] || continue
      local age
      age=$(( now - ts ))
      if [ "$age" -gt "$max_age" ]; then
        continue
      fi
      local week
      week=$(date -d "${snap%_*} ${snap#*_}" +"%G-%V" 2>/dev/null || true)
      [ -n "$week" ] || continue
      local week_file="$tmpdir/week_$week"
      if [ ! -f "$week_file" ]; then
        echo "$snap" >"$week_file"
      fi
    done <<EOF_SNAPS2
$snaps
EOF_SNAPS2
  fi

  # Aggregate and dedupe.
  for f in "$tmpdir"/*; do
    [ -f "$f" ] || continue
    cat "$f"
  done | sort -u

  rm -rf "$tmpdir"
}

cmd_gc() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot-root)
        shift
        [ "$#" -gt 0 ] || { echo "--snapshot-root requires a value" >&2; exit 1; }
        SNAPSHOT_ROOT="$1"
        ;;
      --keep-per-month)
        shift
        [ "$#" -gt 0 ] || { echo "--keep-per-month requires a value" >&2; exit 1; }
        KEEP_PER_MONTH="$1"
        ;;
      --keep-recent-weeks)
        shift
        [ "$#" -gt 0 ] || { echo "--keep-recent-weeks requires a value" >&2; exit 1; }
        KEEP_RECENT_WEEKS="$1"
        ;;
      --keep-recent-count)
        shift
        [ "$#" -gt 0 ] || { echo "--keep-recent-count requires a value" >&2; exit 1; }
        KEEP_RECENT_COUNT="$1"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        echo "Usage: bcache-impermanence gc [--snapshot-root DIR] [--keep-per-month N] [--keep-recent-weeks N] [--keep-recent-count N] [--dry-run]" >&2
        exit 0
        ;;
      *)
        echo "Unknown gc option: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ ! -d "$SNAPSHOT_ROOT" ]; then
    echo "Snapshot root $SNAPSHOT_ROOT does not exist; nothing to do" >&2
    exit 0
  fi

  local snaps
  snaps=$(list_snapshots_desc)
  if [ -z "$snaps" ]; then
    echo "No snapshots to process" >&2
    exit 0
  fi

  local keep
  keep=$(build_keep_set)

  local tmpkeep
  tmpkeep=$(mktemp -d)
  while read -r k; do
    [ -n "$k" ] || continue
    : >"$tmpkeep/$k"
  done <<EOF_KEEP
$keep
EOF_KEEP

  local deleted=0
  while read -r snap; do
    [ -n "$snap" ] || continue
    if [ -f "$tmpkeep/$snap" ]; then
      continue
    fi
    local full
    full="$SNAPSHOT_ROOT/$snap"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] Would delete $full"
    else
      echo "Deleting snapshot $full"
      if ! bcachefs subvolume delete "$full"; then
        echo "Failed to delete $full" >&2
      else
        deleted=$((deleted + 1))
      fi
    fi
  done <<EOF_SNAPS
$snaps
EOF_SNAPS

  rm -rf "$tmpkeep"
  echo "GC complete; deleted $deleted snapshots"
}

cmd_diff() {
  local snapshot_name=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -s)
        shift
        [ "$#" -gt 0 ] || { echo "-s requires a snapshot name" >&2; exit 1; }
        snapshot_name="$1"
        ;;
      --snapshot-root)
        shift
        [ "$#" -gt 0 ] || { echo "--snapshot-root requires a value" >&2; exit 1; }
        SNAPSHOT_ROOT="$1"
        ;;
      --help|-h)
        echo "Usage: bcache-impermanence diff [-s SNAPSHOT] [--snapshot-root DIR] [PATH_PREFIX...]" >&2
        exit 0
        ;;
      --*)
        echo "Unknown diff option: $1" >&2
        exit 1
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  if [ -z "$snapshot_name" ]; then
    snapshot_name=$(latest_snapshot_name || true)
  fi

  if [ -z "$snapshot_name" ]; then
    echo "No snapshots found for diff" >&2
    exit 1
  fi

  local snapshot_dir
  snapshot_dir="$SNAPSHOT_ROOT/$snapshot_name"

  if [ ! -d "$snapshot_dir" ]; then
    echo "Snapshot directory $snapshot_dir does not exist" >&2
    exit 1
  fi

  if [ "$#" -eq 0 ]; then
    set -- /
  fi

  local rc=0
  while [ "$#" -gt 0 ]; do
    local path
    path="$1"
    shift

    case "$path" in
      /*) : ;;
      *)
        echo "Path prefix must be absolute: $path" >&2
        rc=2
        continue
        ;;
    esac

    local from
    local to
    from="$snapshot_dir$path"
    to="$path"

    echo "--- Diff for $path (snapshot $snapshot_name) ---"
    if ! diff -ru --new-file "$from" "$to"; then
      local diff_rc=$?
      if [ "$diff_rc" -gt 1 ]; then
        echo "Error running diff for $path" >&2
        rc=$diff_rc
      fi
    fi
  done

  exit "$rc"
}

main() {
  if [ "$#" -lt 1 ]; then
    usage
    exit 1
  fi

  ensure_deps

  local cmd
  cmd="$1"
  shift || true

  case "$cmd" in
    gc)
      cmd_gc "$@"
      ;;
    ls)
      cmd_ls "$@"
      ;;
    diff)
      cmd_diff "$@"
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      echo "Unknown subcommand: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
