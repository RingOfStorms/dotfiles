#!/usr/bin/env bash
set -eu

SNAPSHOT_ROOT="/.snapshots/old_roots"
KEEP_PER_MONTH=1
KEEP_RECENT_WEEKS=4
KEEP_RECENT_COUNT=5
DRY_RUN=0
DIFF_MAX_DEPTH=0

usage() {
  cat <<EOF
bcache-impermanence - tools for managing impermanence snapshots

Usage:
  bcache-impermanence gc [--snapshot-root DIR] [--keep-per-month N] [--keep-recent-weeks N] [--keep-recent-count N] [--dry-run]
  bcache-impermanence ls [-nN] [--snapshot-root DIR]
  bcache-impermanence diff [-s SNAPSHOT] [--snapshot-root DIR] [--max-depth N] [PATH_PREFIX...]

Subcommands:
  gc    Run garbage collection on old root snapshots.
  ls    List snapshots (newest first). With -nN prints N latest.
  diff  Browse and diff files/dirs between current system and a snapshot.

Options:
  --snapshot-root DIR        Override snapshot root directory (default: /.snapshots/old_roots).
  --keep-per-month N         For gc: keep at least N snapshots per calendar month.
  --keep-recent-weeks N      For gc: keep at least one snapshot per ISO week within the last N weeks.
  --keep-recent-count N      For gc: always keep at least N most recent snapshots overall.
  --dry-run                  For gc: show what would be deleted.
EOF
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
  local count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n*)
        # Accept -nN where N is integer; default to 1 if empty.
        local n="${1#-n}"
        if [ -z "$n" ]; then
          n=1
        fi
        count="$n"
        ;;
      --snapshot-root)
        shift
        [ "$#" -gt 0 ] || { echo "--snapshot-root requires a value" >&2; exit 1; }
        SNAPSHOT_ROOT="$1"
        ;;
      --help|-h)
        echo "Usage: bcache-impermanence ls [-nN] [--snapshot-root DIR]" >&2
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

  if [ "$count" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$snaps" | head -n "$count"
  else
    printf '%s\n' "$snaps"
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
    printf '%s\n' "$snaps" | head -n "$KEEP_RECENT_COUNT" >"$tmpdir/keep_recent"
  fi

  # Per-month: keep up to KEEP_PER_MONTH newest per month.
  if [ "$KEEP_PER_MONTH" -gt 0 ]; then
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

browse_diff_tree() {
  local snapshot_name snapshot_dir diff_list initial_prefix
  snapshot_name="$1"
  snapshot_dir="$2"
  diff_list="$3"
  initial_prefix="${4-}"

  local current_prefix=""
  if [ -n "$initial_prefix" ]; then
    current_prefix="$initial_prefix"
  fi

  while :; do
    local children
    children=$(mktemp)
    local seen
    seen=$(mktemp)

    # Optional parent entry
    if [ -n "$current_prefix" ]; then
      echo "dir .." >"$children"
    fi

    # Build immediate children under current_prefix.
    while read -r st rel; do
      [ -n "$rel" ] || continue
      local sub
      if [ -n "$current_prefix" ]; then
        case "$rel" in
          "$current_prefix")
            # Exact match at this level; treat as leaf, not a separate child.
            continue
            ;;
          "$current_prefix"/*)
            sub="${rel#"$current_prefix"/}"
            ;;
          *)
            continue
            ;;
        esac
      else
        sub="$rel"
      fi

      [ -n "$sub" ] || continue

      local child
      child="${sub%%/*}"
      local child_rel
      if [ -n "$current_prefix" ]; then
        child_rel="$current_prefix/$child"
      else
        child_rel="$child"
      fi

      if grep -qx "$child_rel" "$seen" 2>/dev/null; then
        continue
      fi

      echo "$st $child_rel" >>"$children"
      echo "$child_rel" >>"$seen"
    done <"$diff_list"

    rm -f "$seen"

    if [ ! -s "$children" ]; then
      echo "No further differences under ${current_prefix:-/}" >&2
      rm -f "$children"
      break
    fi

    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf is required for diff browsing" >&2
      rm -f "$children"
      break
    fi

    local preview_cmd
    preview_cmd='sel_rel=$(printf "%s\n" {} | cut -d" " -f2-)
if [ "$sel_rel" = ".." ]; then
  echo "[UP] .."
  exit 0
fi
snap_dir="'"$snapshot_dir"'"
a_path="$snap_dir/$sel_rel"
b_path="/$sel_rel"

if [ ! -e "$a_path" ] && [ -e "$b_path" ]; then
  echo "[ADDED] /$sel_rel"; echo
  if [ -d "$b_path" ]; then
    (cd / && find "$sel_rel" -maxdepth 3 -print 2>/dev/null || true)
  else
    diff -u /dev/null "$b_path" 2>/dev/null || cat "$b_path" 2>/dev/null || true
  fi
elif [ -e "$a_path" ] && [ ! -e "$b_path" ]; then
  echo "[REMOVED] /$sel_rel"; echo
  if [ -d "$a_path" ]; then
    (cd "$snap_dir" && find "$sel_rel" -maxdepth 3 -print 2>/dev/null || true)
  else
    diff -u "$a_path" /dev/null 2>/dev/null || cat "$a_path" 2>/dev/null || true
  fi
else
  if [ -d "$a_path" ] && [ -d "$b_path" ]; then
    echo "[CHANGED DIR] /$sel_rel"; echo
    diff -ru "$a_path" "$b_path" 2>/dev/null || true
  else
    echo "[CHANGED] /$sel_rel"; echo
    diff -u "$a_path" "$b_path" 2>/dev/null || true
  fi
fi
'

    local selection
    selection=$(FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:-} --ansi --preview-window=right:70%:wrap" \
      fzf --prompt="[bcache-impermanence diff ${current_prefix:-/}] " \
          --preview "$preview_cmd" <"$children") || {
      rm -f "$children"
      break
    }

    rm -f "$children"

    local sel_rel
    sel_rel=$(printf "%s\n" "$selection" | cut -d" " -f2-)

    if [ "$sel_rel" = ".." ]; then
      if [ -z "$current_prefix" ]; then
        break
      fi
      if printf "%s" "$current_prefix" | grep -q '/'; then
        current_prefix="${current_prefix%/*}"
      else
        current_prefix=""
      fi
      continue
    fi

    # If this selection has descendants, drill down; otherwise treat as leaf and exit.
    if grep -q " $sel_rel/" "$diff_list"; then
      current_prefix="$sel_rel"
      continue
    else
      # Leaf: user already saw diff in preview; exit.
      break
    fi
  done
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
      --max-depth)
        shift
        [ "$#" -gt 0 ] || { echo "--max-depth requires a value" >&2; exit 1; }
        DIFF_MAX_DEPTH="$1"
        ;;
      --help|-h)
        echo "Usage: bcache-impermanence diff [-s SNAPSHOT] [--snapshot-root DIR] [--max-depth N] [PATH_PREFIX...]" >&2
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

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf is required for diff browsing" >&2
    exit 1
  fi

  local prefixes
  prefixes=("$@")

  local tmp
  tmp=$(mktemp)

  for prefix in "${prefixes[@]}"; do
    case "$prefix" in
      /*) : ;;
      *)
        echo "Path prefix must be absolute: $prefix" >&2
        continue
        ;;
    esac

    local rel
    rel="${prefix#/}"
    [ -z "$rel" ] && rel="."

    if [ "$DIFF_MAX_DEPTH" -gt 0 ] 2>/dev/null; then
      (
        cd "$snapshot_dir" && find "$rel" -mindepth 1 -maxdepth "$DIFF_MAX_DEPTH" -print 2>/dev/null || true
      ) | sed "s/^/A /" >>"$tmp"

      (
        cd / && find "$rel" -mindepth 1 -maxdepth "$DIFF_MAX_DEPTH" -print 2>/dev/null || true
      ) | sed "s/^/B /" >>"$tmp"
    else
      (
        cd "$snapshot_dir" && find "$rel" -mindepth 1 -print 2>/dev/null || true
    ) | sed "s/^/B /" >>"$tmp"
    fi
  done


  if [ ! -s "$tmp" ]; then
    echo "No files found under specified prefixes" >&2
    rm -f "$tmp"
    exit 1
  fi

  local paths
  paths=$(cut -d' ' -f2- "$tmp" | sort -u)

  local diff_list
  diff_list=$(mktemp)

  while read -r rel; do
    [ -n "$rel" ] || continue
    local a_path b_path
    a_path="$snapshot_dir/$rel"
    b_path="/$rel"

    local status
    if [ ! -e "$a_path" ] && [ -e "$b_path" ]; then
      status="added"
    elif [ -e "$a_path" ] && [ ! -e "$b_path" ]; then
      status="removed"
    else
      if [ -d "$a_path" ] && [ -d "$b_path" ]; then
        if ! diff -rq "$a_path" "$b_path" >/dev/null 2>&1; then
          status="changed-dir"
        else
          continue
        fi
      else
        if ! diff -q "$a_path" "$b_path" >/dev/null 2>&1; then
          status="changed"
        else
          continue
        fi
      fi
    fi

    echo "$status $rel" >>"$diff_list"
  done <<<"$paths"

  rm -f "$tmp"

  if [ ! -s "$diff_list" ]; then
    echo "No differences found between snapshot $snapshot_name and current system" >&2
    rm -f "$diff_list"
    exit 0
  fi

  local initial_prefix=""
  if [ "$#" -eq 1 ]; then
    # Single prefix: start tree at that path relative to /
    initial_prefix="${1#/}"
  fi

  browse_diff_tree "$snapshot_name" "$snapshot_dir" "$diff_list" "$initial_prefix"
  rm -f "$diff_list"
}

main() {
  if [ "$#" -lt 1 ]; then
    usage
    exit 1
  fi

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
