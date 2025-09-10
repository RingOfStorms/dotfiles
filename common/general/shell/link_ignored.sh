#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: link_ignored.sh [--dry-run] [--no-fzf] [pattern ...]

Description:
  Interactively or non-interactively create symlinks in the current worktree
  for files/dirs that exist in the main repository root but are git-ignored /
  untracked. Useful for syncing local dev files (eg .env, .envrc) from your
  main repo working copy into a worktree.

Options:
  --dry-run    : Print actions but don't create symlinks
  --no-fzf     : Don't use fzf for interactive selection; select all matching
  pattern ...  : Optional glob or substring patterns to filter candidate paths

Examples:
  link_ignored.sh .env .envrc
  link_ignored.sh --dry-run
  link_ignored.sh --no-fzf
EOF
}

DRY_RUN=0
USE_FZF=1
PATTERNS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-fzf) USE_FZF=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) PATTERNS+=("$1"); shift ;;
  esac
done

# Determine the main repo root using git-common-dir (handles worktrees)
if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
  echo "Error: not in a git repository." >&2
  exit 2
fi
# Make absolute if relative
if [ "${common_dir#/}" = "$common_dir" ]; then
  common_dir="$(pwd)/$common_dir"
fi
repo_root="${common_dir%%/.git*}"
if [ -z "$repo_root" ]; then
  echo "Error: unable to determine repository root." >&2
  exit 2
fi

# Get list of untracked/ignored files from the repo root (relative paths)
mapfile -d $'\0' -t candidates < <(git -C "$repo_root" ls-files --others --ignored --exclude-standard -z || true)

if [ ${#candidates[@]} -eq 0 ]; then
  echo "No untracked/ignored files found in $repo_root"
  exit 0
fi

# Collapse to top-level (first path component) and make unique.
# This prevents listing every file under node_modules/ or build/.
declare -A _seen
tops=()
for c in "${candidates[@]}"; do
  # remove trailing slash if present
  c="${c%/}"
  top="${c%%/*}"
  [ -z "$top" ] && continue
  if [ -z "${_seen[$top]:-}" ]; then
    _seen[$top]=1
    tops+=("$top")
  fi
done

if [ ${#tops[@]} -eq 0 ]; then
  echo "No top-level ignored/untracked entries found in $repo_root"
  exit 0
fi

# Filter top-level entries by provided patterns (if any)
if [ ${#PATTERNS[@]} -gt 0 ]; then
  filtered=()
  for t in "${tops[@]}"; do
    for p in "${PATTERNS[@]}"; do
      if [[ "$t" == *"$p"* ]]; then
        filtered+=("$t")
        break
      fi
    done
  done
else
  filtered=("${tops[@]}")
fi

if [ ${#filtered[@]} -eq 0 ]; then
  echo "No candidates match the provided patterns." >&2
  exit 0
fi

# Present selection
if command -v fzf >/dev/null 2>&1 && [ "$USE_FZF" -eq 1 ]; then
  # Show preview of the source file (if text) and allow multi-select
  selected=$(printf "%s\n" "${filtered[@]}" | fzf --multi --height=40% --border --prompt="Select files to link: " --preview "if [ -f '$repo_root'/{} ]; then bat --color always --paging=never --style=plain '$repo_root'/{}; else ls -la '$repo_root'/{}; fi")
  if [ -z "$selected" ]; then
    echo "No files selected." && exit 0
  fi
  # Convert to array
  IFS=$'\n' read -r -d '' -a chosen < <(printf "%s\n" "$selected" && printf '\0')
else
  # Non-interactive: choose all
  chosen=("${filtered[@]}")
fi

# Worktree destination is current working directory
worktree_root=$(pwd)

echo "Repository root: $repo_root"
echo "Worktree root : $worktree_root"

# Create symlinks
created=()
skipped=()
errors=()

for rel in "${chosen[@]}"; do
  # Trim trailing newlines/spaces
  rel=${rel%%$'\n'}
  src="$repo_root/$rel"
  dst="$worktree_root/$rel"

  if [ ! -e "$src" ]; then
    errors+=("$rel (source missing)")
    continue
  fi

  if [ -L "$dst" ]; then
    # Already a symlink
    echo "Skipping $rel (already symlink)"
    skipped+=("$rel")
    continue
  fi
  if [ -e "$dst" ]; then
    echo "Skipping $rel (destination exists)"
    skipped+=("$rel")
    continue
  fi

  mkdir -p "$(dirname "$dst")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: ln -s '$src' '$dst'"
  else
    if ln -s "$src" "$dst"; then
      echo "Linked: $rel"
      created+=("$rel")
    else
      echo "Failed to link: $rel" >&2
      errors+=("$rel (link failed)")
    fi
  fi
done

# Summary
echo
echo "Summary:"
echo "  Linked: ${#created[@]}"
[ ${#created[@]} -gt 0 ] && printf '    %s\n' "${created[@]}"
echo "  Skipped: ${#skipped[@]}"
[ ${#skipped[@]} -gt 0 ] && printf '    %s\n' "${skipped[@]}"
echo "  Errors: ${#errors[@]}"
[ ${#errors[@]} -gt 0 ] && printf '    %s\n' "${errors[@]}"

exit 0
