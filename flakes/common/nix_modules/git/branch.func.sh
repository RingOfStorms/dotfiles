branch() {
  local branch_name=${1:-}
  local base_ref=${2:-}

  # helper: set tmux window name. If tmux is in auto mode, always rename.
  # If tmux is manual but the current window name matches the previous branch,
  # allow renaming from previous branch name to the new one.
  _branch__maybe_set_tmux_name() {
    if ! command -v tmux_window >/dev/null 2>&1; then
      return 1
    fi
    local new_name prev_branch tmux_status tmux_cur
    new_name=${1:-}
    prev_branch=${2:-}
    tmux_status=$(tmux_window status 2>/dev/null || true)
    if [ "$tmux_status" = "auto" ]; then
      tmux_window rename "$new_name" 2>/dev/null || true
      return 0
    fi
    # tmux is manual. If the current tmux name matches the previous branch,
    # we consider it safe to update it to the new branch name.
    if [ -n "$prev_branch" ]; then
      tmux_cur=$(tmux_window get 2>/dev/null || true)
      if [ "$tmux_cur" = "$prev_branch" ]; then
        tmux_window rename "$new_name" 2>/dev/null || true
      fi
    fi
  }

  # helper: revert tmux to automatic rename only if current tmux name matches previous branch
  _branch__revert_tmux_auto() {
    if ! command -v tmux_window >/dev/null 2>&1; then
      return 1
    fi
    local prev_branch=${1:-}
    if [ -z "$prev_branch" ]; then
      tmux_window rename 2>/dev/null || true
      return 0
    fi
    local tmux_cur
    tmux_cur=$(tmux_window get 2>/dev/null || true)
    if [ "$tmux_cur" = "$prev_branch" ]; then
      tmux_window rename 2>/dev/null || true
    fi
  }

  # The common Git directory is shared by every checkout; do not derive the
  # root by splitting at the first occurrence of ".git" in a path.
  local repo_dir
  repo_dir=$(_branch__repo_root) || {
    echo "Not inside a non-bare Git repository." >&2
    return 1
  }

  # If no branch was provided, present an interactive selector combining local and remote branches
  if [ -z "$branch_name" ]; then
    if ! command -v fzf >/dev/null 2>&1; then
      echo "Usage: branch <name> [base]" >&2
      return 2
    fi

    local branches_list_raw branches_list selection
    # Gather local and remote branches with fallbacks to ensure locals appear
    branches_list_raw=""
    if declare -f local_branches >/dev/null 2>&1; then
      branches_list_raw=$(builtin cd -- "$repo_dir" && local_branches 2>/dev/null || true; builtin cd -- "$repo_dir" && remote_branches 2>/dev/null || true)
    fi
    branches_list=$(printf "%s
" "$branches_list_raw" | awk '!seen[$0]++')
    if [ -z "$branches_list" ]; then
      echo "No branches found." >&2
      return 1
    fi

    fzf_out=$(printf "%s\n" "$branches_list" | fzf --height=40% --prompt="Select branch: " --print-query)
    if [ -z "$fzf_out" ]; then
      echo "No branch selected." >&2
      return 1
    fi
    branch_query=$(printf "%s\n" "$fzf_out" | sed -n '1p')
    branch_selection=$(printf "%s\n" "$fzf_out" | sed -n '2p')
    if [ -n "$branch_selection" ]; then
      branch_name="$branch_selection"
    else
      # user typed something in fzf but didn't select: use that as new branch name
      branch_name=$(printf "%s" "$branch_query" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
  fi

  local default_branch

  default_branch=$(getdefault 2>/dev/null)
  [ -n "$default_branch" ] || default_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD) || return 1

  # capture current branch name as seen by tmux so we can decide safe renames later
  local prev_branch
  prev_branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

  # Special-case: jump to the main working tree on the default branch
  if [ "$branch_name" = "default" ] || [ "$branch_name" = "master" ] || [ "$branch_name" = "$default_branch" ]; then
    if [ "$repo_dir" = "$PWD" ]; then
      echo "Already in the main working tree on branch '$default_branch'."
      return 0
    fi
    echo "Switching to main working tree on branch '$default_branch'."
    # capture current branch name as seen by tmux so we only revert if it matches
    prev_branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    builtin cd -- "$repo_dir" || return 1
    _branch__revert_tmux_auto "$prev_branch" || true
    return 0
  fi

  # Match Git's porcelain branch field exactly (including slashes and spaces).
  local existing
  existing=$(_branch__worktree_for_branch "$repo_dir" "$branch_name") || existing=''
  if [ -n "$existing" ]; then
    echo "Opening existing worktree for branch '$branch_name' at '$existing'."
    builtin cd -- "$existing" || return 1
    _branch__setup_worktree "$repo_dir" "$existing" || printf 'Worktree setup did not complete for %s\n' "$existing" >&2
    _branch__herdr_open "$repo_dir" "$existing"
    _branch__maybe_set_tmux_name "$branch_name" "$prev_branch" || true
    return 0
  fi

  # Fetch only when an origin exists; local-only repositories work too.
  if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo_dir" fetch --all --prune || true
  fi

  local wt_root wt_path
  wt_root=$(_branch__worktree_root "$repo_dir")
  wt_path="$wt_root/$branch_name/$(basename -- "$repo_dir")"

  # ensure worktree root exists
  if [ ! -d "$wt_root" ]; then
    mkdir -p "$wt_root" || { echo "Failed to create worktree root: $wt_root" >&2; return 1; }
  fi

  # An existing directory not listed by Git is not this branch's worktree.
  if [ -e "$wt_path" ]; then
    printf 'Path exists but is not a registered worktree for %s: %s\n' "$branch_name" "$wt_path" >&2
    return 1
  fi

  local branch_exists branch_from local_exists no_track=""
  if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    branch_exists=$(git -C "$repo_dir" ls-remote --heads origin "$branch_name" 2>/dev/null | wc -l)
  else
    branch_exists=0
  fi
  # check if a local branch exists
  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch_name"; then
    local_exists=1
  else
    local_exists=0
  fi

  # Resolve an explicit base ref, if the caller supplied one.
  local resolved_base=""
  if [ -n "$base_ref" ]; then
    local candidate
    for candidate in "refs/heads/$base_ref" "refs/remotes/origin/$base_ref" "$base_ref"; do
      if git -C "$repo_dir" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
        resolved_base="$candidate"
        break
      fi
    done
    if [ -z "$resolved_base" ]; then
      echo "Base ref '$base_ref' could not be resolved in '$repo_dir'." >&2
      return 1
    fi
  fi

  branch_from="$default_branch"
  if [ "$branch_exists" -eq 0 ]; then
    if [ "$local_exists" -eq 1 ]; then
      branch_from="$branch_name"
      if [ -n "$resolved_base" ]; then
        echo "Branch '$branch_name' already exists locally; ignoring base '$base_ref'."
      fi
      echo "Branch '$branch_name' exists locally; creating worktree from local branch."
    else
      if [ -n "$resolved_base" ]; then
        branch_from="$resolved_base"
        # Don't inherit the base's upstream: a later bare `git push` must not
        # target the branch we forked from.
        no_track="--no-track"
      fi
      echo "Branch '$branch_name' does not exist on remote; creating from '$branch_from'."
    fi
  else
    branch_from="origin/$branch_name"
    if [ -n "$resolved_base" ]; then
      echo "Branch '$branch_name' already exists on remote; ignoring base '$base_ref'."
    fi
    echo "Branch '$branch_name' exists on remote; creating worktree tracking it."
  fi

  echo "Creating new worktree for branch '$branch_name' at '$wt_path'."

  # Add from the selected local or remote ref, preserving Git's errors.

  _branch__post_setup() {
    if ! _branch__setup_worktree "$1" "$2"; then
      printf 'Worktree setup did not complete for %s\n' "$2" >&2
    fi
    _branch__herdr_open "$1" "$2"
  }

  if [ "$local_exists" -eq 1 ]; then
    if git -C "$repo_dir" worktree add "$wt_path" "$branch_name"; then
      builtin cd -- "$wt_path" || return 1
      _branch__maybe_set_tmux_name "$branch_name" "$prev_branch" || true
      _branch__post_setup "$repo_dir" "$wt_path"
      return 0
    fi
  else
    if git -C "$repo_dir" worktree add ${no_track:+$no_track} -b "$branch_name" "$wt_path" "$branch_from"; then
      builtin cd -- "$wt_path" || return 1
      _branch__maybe_set_tmux_name "$branch_name" "$prev_branch" || true
      _branch__post_setup "$repo_dir" "$wt_path"
      return 0
    fi
  fi

  echo "Failed to add worktree for branch '$branch_name'." >&2
  _branch__prune_empty_dirs "$wt_root" "$wt_path"
  return 1
}
