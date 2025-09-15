branch() {
  local branch_name=${1:-}

  # Determine repo root early so we can run branches inside it
  local common_dir
  if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "Not inside a git repository." >&2
    return 1
  fi
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  local repo_dir="${common_dir%%/.git*}"
  if [ -z "$repo_dir" ]; then
    echo "Unable to determine repository root." >&2
    return 1
  fi

  # If no branch was provided, present an interactive selector combining local and remote branches
  if [ -z "$branch_name" ]; then
    if ! command -v fzf >/dev/null 2>&1; then
      echo "Usage: branch <name>" >&2
      return 2
    fi

    local branches_list_raw branches_list selection
    if declare -f local_branches >/dev/null 2>&1; then
      branches_list_raw=$(local_branches 2>/dev/null || true; remote_branches 2>/dev/null || true)
    else
      branches_list_raw=$(git -C "$repo_dir" branch --format='%(refname:short)' 2>/dev/null || true; git -C "$repo_dir" branch -r --format='%(refname:short)' 2>/dev/null | sed 's#^.*/##' || true)
    fi

    branches_list=$(printf "%s
" "$branches_list_raw" | awk '!seen[$0]++')
    if [ -z "$branches_list" ]; then
      echo "No branches found." >&2
      return 1
    fi

    selection=$(printf "%s\n" "$branches_list" | fzf --height=40% --prompt="Select branch: ")
    if [ -z "$selection" ]; then
      echo "No branch selected." >&2
      return 1
    fi

    branch_name="$selection"
  fi

  local repo_base repo_hash default_branch
  repo_base=$(basename "$repo_dir")
  repo_hash=$(printf "%s" "$repo_dir" | sha1sum | awk '{print $1}')

  default_branch=$(getdefault)

  # Special-case: jump to the main working tree on the default branch
  if [ "$branch_name" = "default" ] || [ "$branch_name" = "master" ] || [ "$branch_name" = "$default_branch" ]; then
    if [ "$repo_dir" = "$PWD" ]; then
      echo "Already in the main working tree on branch '$default_branch'."
      return 0
    fi
    echo "Switching to main working tree on branch '$default_branch'."
    cd "$repo_dir" || return 1
    return 0
  fi

  # If a worktree for this branch is already registered elsewhere, open a shell there
  local existing
  existing=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null | awk -v b="$branch_name" 'BEGIN{RS="";FS="\n"} $0 ~ "refs/heads/"b{for(i=1;i<=NF;i++) if ($i ~ /^worktree /){ sub(/^worktree /,"",$i); print $i }}')
  if [ -n "$existing" ]; then
    echo "Opening existing worktree for branch '$branch_name' at '$existing'."
    cd "$existing" || return 1
    return 0
  fi

  # Ensure we have up-to-date remote info
  git -C "$repo_dir" fetch --all --prune || true

  local wt_root wt_path
  if [ -z "$xdg" ]; then
    xdg="${XDG_DATA_HOME:-$HOME/.local/share}"
  fi
  wt_root="$xdg/git_worktrees/${repo_base}_${repo_hash}"
  wt_path="$wt_root/$branch_name"

  # ensure worktree root exists
  if [ ! -d "$wt_root" ]; then
    mkdir -p "$wt_root" || { echo "Failed to create worktree root: $wt_root" >&2; return 1; }
  fi

  # If worktree already exists at our expected path, open a shell there
  if [ -d "$wt_path" ]; then
    echo "Opening existing worktree at '$wt_path'."
    cd "$wt_path" || return 1
    return 0
  fi

  local branch_exists branch_from local_exists
  branch_exists=$(git -C "$repo_dir" ls-remote --heads origin "$branch_name" | wc -l)
  # check if a local branch exists
  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch_name"; then
    local_exists=1
  else
    local_exists=0
  fi

  branch_from="$default_branch"
  if [ "$branch_exists" -eq 0 ]; then
    if [ "$local_exists" -eq 1 ]; then
      branch_from="$branch_name"
      echo "Branch '$branch_name' exists locally; creating worktree from local branch."
    else
      echo "Branch '$branch_name' does not exist on remote; creating from '$branch_from'."
    fi
  else
    branch_from="origin/$branch_name"
    echo "Branch '$branch_name' exists on remote; creating worktree tracking it."
  fi

  echo "Creating new worktree for branch '$branch_name' at '$wt_path'."

  # Try to add or update worktree from the resolved ref. Use a fallback path if needed.
  if [ "$local_exists" -eq 1 ]; then
    if git -C "$repo_dir" worktree add "$wt_path" "$branch_name" 2>/dev/null; then
      cd "$wt_path" || return 1
      return 0
    fi
  else
    if git -C "$repo_dir" worktree add -b "$branch_name" "$wt_path" "$branch_from" 2>/dev/null; then
      cd "$wt_path" || return 1
      return 0
    fi
  fi

  # Fallback: try to resolve a concrete SHA and create the branch ref locally, then add worktree
  local start_sha
  if start_sha=$(git -C "$repo_dir" rev-parse --verify "$branch_from" 2>/dev/null); then
    if git -C "$repo_dir" branch "$branch_name" "$start_sha" 2>/dev/null; then
      if git -C "$repo_dir" worktree add "$wt_path" "$branch_name" 2>/dev/null; then
        cd "$wt_path" || return 1
        return 0
      else
        git -C "$repo_dir" branch -D "$branch_name" 2>/dev/null || true
        rmdir "$wt_path" 2>/dev/null || true
        echo "Failed to add worktree after creating branch ref." >&2
        return 1
      fi
    fi
  fi

  echo "Failed to add worktree for branch '$branch_name'." >&2
  rmdir "$wt_path" 2>/dev/null || true
  return 1
}
