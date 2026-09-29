# Shared by the interactive Bash/Zsh functions and Herdr's Bash event hook.
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

  # A Herdr event hook can race the interactive branch command. Lock and mark
  # the per-worktree Git dir, not the checkout, so both entrypoints agree.
  (
    exec 9>"$git_dir/post-setup.lock" || return 1
    flock -x 9 || return 1
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

_branch__herdr_open() {
  local repo_dir=$1 wt_path=$2 output
  command -v herdr >/dev/null 2>&1 || return 0
  # --cwd resolves the main checkout; Herdr worktree.open creates its parent
  # workspace if absent and groups this already-existing checkout with it.
  if ! output=$(herdr worktree open --cwd "$repo_dir" --path "$wt_path" --no-focus 2>&1); then
    printf 'Herdr could not open worktree %s: %s\n' "$wt_path" "$output" >&2
  fi
}

_branch__herdr_close() {
  local repo_dir=$1 wt_path=$2 output workspace_id details
  command -v herdr >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || {
    printf 'Herdr registration for %s was not closed: jq unavailable\n' "$wt_path" >&2
    return 0
  }
  if ! output=$(herdr workspace list 2>&1); then
    printf 'Herdr registrations could not be listed: %s\n' "$output" >&2
    return 0
  fi
  if ! workspace_id=$(printf '%s\n' "$output" | jq -er --arg path "$wt_path" --arg root "$repo_dir" '
      [.result.workspaces[] | select(.worktree.is_linked_worktree == true
        and .worktree.checkout_path == $path and .worktree.repo_root == $root)
        | .workspace_id] | if length == 0 then "" elif length == 1 then .[0] else error("ambiguous worktree workspace") end
    '); then
    printf 'Herdr workspace listing for %s was invalid or ambiguous\n' "$wt_path" >&2
    return 0
  fi
  [ -n "$workspace_id" ] || return 0
  if ! details=$(herdr workspace get "$workspace_id" 2>&1); then
    printf 'Herdr workspace %s could not be checked: %s\n' "$workspace_id" "$details" >&2
    return 0
  fi
  # Recheck the exact identity before closing: workspace close is state-only,
  # but it must never close the main root or an unrelated workspace.
  if ! printf '%s\n' "$details" | jq -e --arg path "$wt_path" --arg root "$repo_dir" --arg id "$workspace_id" '
      .result.workspace | .workspace_id == $id and .worktree.is_linked_worktree == true
        and .worktree.checkout_path == $path and .worktree.repo_root == $root
    ' >/dev/null; then
    printf 'Herdr workspace %s no longer matches removed worktree %s; not closing\n' "$workspace_id" "$wt_path" >&2
    return 0
  fi
  if ! output=$(herdr workspace close "$workspace_id" 2>&1); then
    printf 'Herdr workspace %s could not be closed: %s\n' "$workspace_id" "$output" >&2
  fi
}
