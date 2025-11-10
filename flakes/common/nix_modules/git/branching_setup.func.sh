branching_setup() {
  # Interactive helper to manage worktree.autolink and worktree.bootstrap
  local common_dir repo_root
  if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "Not inside a git repository." >&2
    return 1
  fi
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  repo_root="${common_dir%%/.git*}"
  if [ -z "$repo_root" ]; then
    echo "Unable to determine repository root." >&2
    return 1
  fi

  # Build candidate ignored/untracked file list
  local -a candidates=()
  while IFS= read -r -d '' file; do
    candidates+=("$file")
  done < <(git -C "$repo_root" ls-files --others --ignored --exclude-standard -z || true)

  # Include some common dotfiles at root even if tracked (for selection convenience)
  for extra in .env .env.development .env.development.local .envrc .direnv flake.nix flake.lock; do
    if [ -e "$repo_root/$extra" ]; then
      candidates+=("$extra")
    fi
  done

  # De-duplicate
  local unique
  unique=$(printf "%s\n" "${candidates[@]}" | awk '!seen[$0]++')

  # Current config values
  local -a current
  while IFS= read -r line; do
    [ -n "$line" ] && current+=("$line")
  done < <(git -C "$repo_root" config --get-all worktree.autolink 2>/dev/null || true)

  # Preselect current ones in fzf (mark with *)
  local list
  list=$(printf "%s\n" $unique | while read -r x; do
    local mark=""
    for c in "${current[@]}"; do [ "$c" = "$x" ] && mark="*" && break; done
    printf "%s%s\n" "$mark" "$x"
  done)

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not found; printing candidates. Use git config --local --add worktree.autolink <item> to add." >&2
    printf "%s\n" "$unique"
  else
    local selection
    selection=$(printf "%s\n" "$list" | sed 's/^\*//' | fzf --multi --prompt="Select autolink items: " --preview "if [ -f '$repo_root'/{} ]; then bat --color always --paging=never --style=plain '$repo_root'/{}; else ls -la '$repo_root'/{}; fi")
    # Reset existing values
    git -C "$repo_root" config --unset-all worktree.autolink 2>/dev/null || true
    # Apply selection
    if [ -n "$selection" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && git -C "$repo_root" config --add worktree.autolink "$line"
      done <<EOF
$selection
EOF
    fi
    echo "Updated worktree.autolink entries."
  fi

  # Bootstrap mode
  echo "\nBootstrap setup"
  local current_bootstrap
  current_bootstrap=$(git -C "$repo_root" config --get worktree.bootstrap 2>/dev/null || printf "")
  echo "Current: ${current_bootstrap:-<none>}"
  echo "Options: [skip] [auto] [custom command]"
  local choice
  if [ -n "$ZSH_VERSION" ]; then
    read -r "choice?Enter bootstrap mode or command: "
  else
    read -r -p "Enter bootstrap mode or command: " choice
  fi
  choice=${choice:-$current_bootstrap}
  if [ -z "$choice" ]; then
    echo "Leaving bootstrap unchanged."
  else
    git -C "$repo_root" config worktree.bootstrap "$choice"
    echo "Set worktree.bootstrap=$choice"
  fi
}
