# Branch and branchd helpers (worktree-based)

# branch <name> — create or jump to a worktree for <name>
branch() {
  # Use XDG_DATA_HOME or default to ~/.local/share
  local xdg=${XDG_DATA_HOME:-$HOME/.local/share}
  # Determine the git common dir (points into the main repo's .git)
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "Not inside a git repository." >&2
    return 1
  }
  # Make common_dir absolute if it's relative
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  # repo_dir is the path before '/.git' in the common_dir (handles worktrees)
  local repo_dir
  repo_dir="${common_dir%%/.git*}"
  if [ -z "$repo_dir" ]; then
    echo "Unable to determine repository root." >&2
    return 1
  fi

  local repo_base
  repo_base=$(basename "$repo_dir")
  local repo_hash
  repo_hash=$(printf "%s" "$repo_dir" | sha1sum | awk '{print $1}')

  local branch_name
  branch_name=$1
  if [ -z "$branch_name" ]; then
    echo "Usage: branch <name>" >&2
    return 1
  fi

  # If user asked for default or master, cd back to repo root on default branch
  local default_branch
  default_branch=$(getdefault 2>/dev/null || echo "")
  if [ "$branch_name" = "default" ] || [ "$branch_name" = "master" ] || [ "$branch_name" = "$default_branch" ]; then
    cd "$repo_dir" || return 0
    git fetch
    git checkout "$default_branch"
    pull
    return 0
  fi

  # Ensure we have up-to-date remote info
  git fetch --all --prune

  # If branch exists remotely and not locally, create local branch tracking remote
  if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
    if ! git show-ref --verify --quiet "refs/heads/$branch_name"; then
      git branch --track "$branch_name" "origin/$branch_name" 2>/dev/null || git branch "$branch_name" "origin/$branch_name"
    fi
  fi

  # Worktree path
  local wt_root
  wt_root="$xdg/git_worktrees/${repo_base}_${repo_hash}"
  local wt_path
  wt_path="$wt_root/$branch_name"

  mkdir -p "$wt_root"

  # If worktree already exists at our expected path, cd to it
  if [ -d "$wt_path/.git" ]; then
    cd "$wt_path" || return 0
    return 0
  fi

  # If a worktree for this branch is already registered elsewhere, find it and cd
  local existing
  existing=$(git worktree list --porcelain 2>/dev/null | awk -v b="$branch_name" 'BEGIN{RS=""} $0 ~ "refs/heads/"b{for(i=1;i<=NF;i++) if ($i ~ /^worktree/) print $2 }')
  if [ -n "$existing" ]; then
    cd "$existing" || return 0
    return 0
  fi

  # Create the worktree
  mkdir -p "$wt_path"
  git worktree add -B "$branch_name" "$wt_path" "origin/$branch_name" 2>/dev/null || git worktree add "$wt_path" "$branch_name"
  cd "$wt_path" || return 0
}

# branchd — remove current branch worktree
branchd() {
  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo "Not inside a git repository." >&2
    return 1
  }
  local default_branch
  default_branch=$(getdefault 2>/dev/null || echo "")

  if [ "$current" = "$default_branch" ] || [ "$current" = "default" ]; then
    echo "Already on default branch ($default_branch). Won't remove." >&2
    return 1
  fi

  # Find the worktree path for the current branch
  local wt_path
  wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$current" 'BEGIN{RS="";FS="\n"} $0 ~ "refs/heads/"b{for(i=1;i<=NF;i++) if ($i ~ /^worktree /) { sub(/^worktree /,"",$i); print $i }}')
  if [ -z "$wt_path" ]; then
    echo "Worktree for branch '$current' not found." >&2
    return 1
  fi

  # Switch to default branch (uses branch() helper) and then remove worktree
  branch default || { echo "Failed to switch to default branch" >&2; return 1; }

  git worktree remove "$wt_path"
}
