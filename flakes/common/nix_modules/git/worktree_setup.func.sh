# Shared worktree helpers for branch, branchdel, link_ignored and branching_setup.
# Use builtin cd internally: zoxide's cd function treats -P as a search term.
_branch__repo_root() {
  local common_dir repo_root
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  repo_root=${common_dir%/.git}
  [ "$repo_root" != "$common_dir" ] || return 1
  (builtin cd -P -- "$repo_root" && pwd -P)
}

_branch__worktree_for_branch() {
  local repo_dir=$1 branch=$2 line found_path=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) found_path=${line#worktree } ;;
      "branch refs/heads/$branch") printf '%s\n' "$found_path"; return 0 ;;
    esac
  done < <(git -C "$repo_dir" worktree list --porcelain)
  return 1
}

# Linked checkouts live at <root>/<branch>/<repo basename>, so the cwd leaf
# keeps the main checkout's name. $xdg overrides the data dir if set.
_branch__worktree_root() {
  local repo_dir=$1 repo_hash
  repo_hash=$(printf '%s' "$repo_dir" | sha1sum | awk '{print $1}')
  printf '%s/git_worktrees/%s_%s\n' "${xdg:-${XDG_DATA_HOME:-$HOME/.local/share}}" "$(basename -- "$repo_dir")" "$repo_hash"
}

# Remove now-empty directories from $2 upward, stopping below root $1.
_branch__prune_empty_dirs() {
  local root=${1%/} dir=${2%/}
  while case "$dir/" in "$root/"?*) true ;; *) false ;; esac; do
    rmdir -- "$dir" 2>/dev/null || return 0
    dir=$(dirname -- "$dir")
  done
}

_branch__setup_worktree() {
  local repo_dir=$1 wt_path=$2 actual_root git_dir mode cmd
  repo_dir=$(builtin cd -P -- "$repo_dir" && pwd -P) || return 1
  wt_path=$(builtin cd -P -- "$wt_path" && pwd -P) || return 1
  actual_root=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$actual_root" = "$repo_dir/.git" ] && [ "$wt_path" != "$repo_dir" ] || {
    printf 'Refusing setup outside linked worktree of %s: %s\n' "$repo_dir" "$wt_path" >&2
    return 1
  }
  git_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1

  # Mark the per-worktree Git dir, not the checkout, so setup runs once.
  (
    [ ! -f "$git_dir/post-setup.done" ] || return 0

    # Copy wins when a name is configured both ways. Neither operation
    # overwrites an existing destination.
    if git -C "$repo_dir" config --get-all worktree.autocopy >/dev/null 2>&1; then
      (builtin cd -- "$wt_path" && link_ignored --copy --auto --no-fzf) || return 1
    fi
    if [ "${BRANCH_AUTOLINK:-0}" = 1 ] || git -C "$repo_dir" config --get-all worktree.autolink >/dev/null 2>&1; then
      (builtin cd -- "$wt_path" && link_ignored --auto --no-fzf) || return 1
    fi

    mode=$(git -C "$repo_dir" config --get worktree.bootstrap 2>/dev/null || true)
    if [ -n "${BRANCH_BOOTSTRAP_CMD:-}" ]; then
      cmd=$BRANCH_BOOTSTRAP_CMD
    elif [ -n "$mode" ]; then
      cmd=$mode
    else
      cmd=${BRANCH_BOOTSTRAP:-skip}
    fi
    case "$cmd" in
      skip|0|false|'') cmd='' ;;
      auto)
        if [ -f "$wt_path/pnpm-lock.yaml" ]; then cmd='pnpm i --frozen-lockfile'
        elif [ -f "$wt_path/yarn.lock" ]; then cmd='yarn install --frozen-lockfile || yarn install --immutable'
        elif [ -f "$wt_path/package-lock.json" ]; then cmd='npm ci'
        else cmd=''; fi
        ;;
      1|true) cmd='npm ci' ;;
    esac
    if [ -n "$cmd" ]; then
      (builtin cd -- "$wt_path" && eval "$cmd") || {
        printf 'Worktree bootstrap failed in %s: %s\n' "$wt_path" "$cmd" >&2
        return 1
      }
    fi
    : > "$git_dir/post-setup.done"
  )
}
