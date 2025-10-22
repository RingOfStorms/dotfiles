branchdel() {
  # branchdel — remove a branch worktree (optional branch arg)
  local branch_arg
  branch_arg="$1"
  local wt_path
  wt_path=$(pwd)
  local common_dir repo_dir
  if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "Not inside a git repository." >&2
    return 1
  fi
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  repo_dir="${common_dir%%/.git*}"
  if [ -z "$repo_dir" ]; then
    echo "Unable to determine repository root." >&2
    return 1
  fi

  # determine current branch in this worktree
  local current default_branch branch target_wt
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || { echo "Not inside a git repository." >&2; return 1; }

  default_branch=$(getdefault)

  # choose branch: provided arg or current
  if [ -z "$branch_arg" ]; then
    branch="$current"
  else
    branch="$branch_arg"
  fi
  # normalize branch name if refs/heads/ was provided
  branch="${branch#refs/heads/}"

  # don't remove default
  if [ "$branch" = "$default_branch" ] || [ "$branch" = "default" ]; then
    echo "Refusing to remove default branch worktree ($default_branch)." >&2
    return 1
  fi

  # find the worktree path for the requested branch
  target_wt=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    $1=="worktree" { w=$2 }
    $1=="branch" && $2==b { print w; exit }
  ')

  # if not found in worktree list, check main worktree branch
  if [ -z "$target_wt" ]; then
    local main_branch
    main_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "$main_branch" = "$branch" ]; then
      target_wt="$repo_dir"
    fi
  fi

  if [ -z "$target_wt" ]; then
    echo "No worktree found for branch '$branch'." >&2
    return 1
  fi

  if [ "$target_wt" = "$repo_dir" ]; then
    echo "Branch '$branch' is the main worktree at '$repo_dir'. Will not delete main worktree." >&2
    return 1
  fi

  # if we're currently in that branch/worktree, switch to default and cd to repo root first
  if [ "$current" = "$branch" ]; then
    echo "Currently on branch '$branch' in '$wt_path'. Switching to default branch '$default_branch' in main worktree..."
    if declare -f branch >/dev/null 2>&1; then
      branch default || { echo "Failed to switch to default branch" >&2; return 1; }
    else
      git -C "$repo_dir" checkout "$default_branch" || { echo "Failed to checkout default branch" >&2; return 1; }
    fi
    cd "$repo_dir" || { echo "Failed to change directory to repo root: $repo_dir" >&2; return 1; }
  fi

  echo "Removing worktree at: $target_wt"
  # helper: attempt a guarded, forceful removal of a directory
  remove_dir_forcefully() {
    local dir="$1"
    if [ -z "$dir" ]; then
      return 1
    fi
    # resolve absolute paths
    local abs_dir abs_repo
    abs_dir=$(readlink -f -- "$dir" 2>/dev/null) || abs_dir="$dir"
    abs_repo=$(readlink -f -- "$repo_dir" 2>/dev/null) || abs_repo="$repo_dir"

    # safety checks: do not remove repository root or /
    if [ "$abs_dir" = "/" ] || [ "$abs_dir" = "$abs_repo" ]; then
      echo "Refusing to remove unsafe path: $abs_dir" >&2
      return 1
    fi

    # try plain rm -rf
    rm -rf -- "$abs_dir" 2>/dev/null && return 0

    # fix permissions then try again
    chmod -R u+rwx "$abs_dir" 2>/dev/null || true
    rm -rf -- "$abs_dir" 2>/dev/null && return 0

    # try removing contents first, then remove directory
    if find "$abs_dir" -mindepth 1 -exec rm -rf -- {} + 2>/dev/null; then
      rmdir "$abs_dir" 2>/dev/null || true
    fi

    # final existence check
    [ ! -e "$abs_dir" ]
  }

  # try unregistering the worktree, prefer normal then fallback to --force
  if git -C "$repo_dir" worktree remove "$target_wt" 2>/dev/null || git -C "$repo_dir" worktree remove --force "$target_wt" 2>/dev/null; then
    if remove_dir_forcefully "$target_wt"; then
      echo "Removed worktree: $target_wt"
    else
      echo "Worktree removed from git, but failed to fully delete directory: $target_wt" >&2
      echo "Attempted to force-delete; you may need to remove it manually with sudo." >&2
    fi

    # delete local branch if it exists
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repo_dir" branch -D "$branch" 2>/dev/null || true
      echo "Deleted local branch: $branch"
    fi
    return 0
  fi

  echo "Failed to remove worktree: $target_wt" >&2
  return 1
}
