branchdel() {
  # branchd — remove current branch worktree (function form)
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

  if [ "$repo_dir" = "$wt_path" ]; then
    echo "Inside the root directory of repo, will not delete." >&2
    return 1
  fi

  local current default_branch
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || { echo "Not inside a git repository." >&2; return 1; }

  default_branch=$(getdefault)

  if [ "$current" = "$default_branch" ] || [ "$current" = "default" ]; then
    echo "Already on default branch ($default_branch). Won't remove."
    return 0
  fi

  echo "Switching to default branch '$default_branch'..."
  # Use branch function if available, otherwise checkout directly in repo
  if declare -f branch >/dev/null 2>&1; then
    branch default || { echo "Failed to switch to default branch" >&2; return 1; }
  else
    git -C "$repo_dir" checkout "$default_branch" || { echo "Failed to checkout default branch" >&2; return 1; }
  fi

  echo "Removing worktree at: $wt_path"
  if git -C "$repo_dir" worktree remove "$wt_path" 2>/dev/null; then
    echo "Removed worktree: $wt_path"
    return 0
  fi
  # try with --force as a fallback
  if git -C "$repo_dir" worktree remove --force "$wt_path" 2>/dev/null; then
    echo "Removed worktree (forced): $wt_path"
    return 0
  fi

  echo "Failed to remove worktree: $wt_path" >&2
  return 1
}
