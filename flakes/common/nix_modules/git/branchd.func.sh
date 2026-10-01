branchdel() {
  local branch=${1:-} repo_dir current default_branch target_wt
  repo_dir=$(_branch__repo_root) || {
    echo "Not inside a non-bare Git repository." >&2
    return 1
  }
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || branch=$current
  branch=${branch#refs/heads/}
  default_branch=$(getdefault 2>/dev/null)
  [ -n "$default_branch" ] || default_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD) || return 1
  if [ "$branch" = "$default_branch" ] || [ "$branch" = default ]; then
    printf 'Refusing to remove default branch worktree (%s).\n' "$default_branch" >&2
    return 1
  fi

  target_wt=$(_branch__worktree_for_branch "$repo_dir" "$branch") || {
    printf 'No worktree found for branch %s.\n' "$branch" >&2
    return 1
  }
  target_wt=$(builtin cd -P -- "$target_wt" && pwd -P) || return 1
  if [ "$target_wt" = "$repo_dir" ]; then
    printf 'Refusing to remove main worktree: %s\n' "$repo_dir" >&2
    return 1
  fi

  # Preserve branchdel's historical fallback for dirty worktrees. Git owns
  # checkout removal; never recursively remove paths behind its back.
  case "$PWD/" in
    "$target_wt/"*) builtin cd -- "$repo_dir" || return 1 ;;
  esac
  if ! git -C "$repo_dir" worktree remove "$target_wt" &&
      ! git -C "$repo_dir" worktree remove --force "$target_wt"; then
    printf 'Worktree was not removed: %s\n' "$target_wt" >&2
    return 1
  fi
  printf 'Removed worktree: %s\n' "$target_wt"

  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    if git -C "$repo_dir" branch -D "$branch"; then
      printf 'Deleted local branch: %s\n' "$branch"
    else
      printf 'Could not delete local branch: %s\n' "$branch" >&2
    fi
  fi
}
