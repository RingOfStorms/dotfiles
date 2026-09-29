branching_setup() {
  # Interactive helper for worktree.autolink, worktree.autocopy and worktree.bootstrap
  local repo_root
  repo_root=$(_branch__repo_root) || {
    echo "Not inside a non-bare Git repository." >&2
    return 1
  }

  # Build candidate ignored/untracked top-level entries
  local -a raw=()
  while IFS= read -r -d '' file; do
    raw+=("$file")
  done < <(git -C "$repo_root" ls-files --others --ignored --exclude-standard -z || true)

  # Reduce to top-level names (directories or files)
  local -a tops=()
  for c in "${raw[@]}"; do
    c="${c%/}"
    local top="${c%%/*}"
    [ -z "$top" ] && continue
    local found=0
    for existing in "${tops[@]}"; do
      [ "$existing" = "$top" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && tops+=("$top")
  done

  # Include common root items even if tracked (for convenience)
  for extra in .env .env.development .env.development.local .envrc .direnv flake.nix flake.lock; do
    if [ -e "$repo_root/$extra" ]; then
      local exists=0
      for t in "${tops[@]}"; do [ "$t" = "$extra" ] && exists=1 && break; done
      [ $exists -eq 0 ] && tops+=("$extra")
    fi
  done

  # Hard-coded excludes (noise, build outputs)
  local -a EXCLUDES=(build dist)
  local -a filtered=()
  for t in "${tops[@]}"; do
    local skip=0
    for e in "${EXCLUDES[@]}"; do [ "$t" = "$e" ] && skip=1 && break; done
    [ $skip -eq 0 ] && filtered+=("$t")
  done

  # Current config values
  local -a current
  while IFS= read -r line; do
    [ -n "$line" ] && current+=("$line")
  done < <(git -C "$repo_root" config --get-all worktree.autolink 2>/dev/null || true)

  # Preselect current ones in fzf (mark with *)
  local list
  list=$(printf "%s\n" "${filtered[@]}" | while read -r x; do
    local mark=""
    for c in "${current[@]}"; do [ "$c" = "$x" ] && mark="*" && break; done
    printf "%s%s\n" "$mark" "$x"
  done)

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not found; printing candidates. Use git config --local --add worktree.autolink <item> to add." >&2
    printf '%s\n' "${filtered[@]}"
  else
    local selection selection_status
    selection=$(printf "%s\n" "$list" | sed 's/^\*//' | fzf --multi --prompt="Select autolink items: " --header="Current links: $(git -C "$repo_root" config --get-all worktree.autolink 2>/dev/null || true)" --preview "if [ -f '$repo_root'/{} ]; then bat --color always --paging=never --style=plain '$repo_root'/{}; else ls -la '$repo_root'/{}; fi")
    selection_status=$?
    if [ "$selection_status" -eq 130 ]; then
      echo "Link selection cancelled; leaving worktree.autolink unchanged."
    elif [ "$selection_status" -gt 1 ]; then
      echo "Link selection failed; leaving worktree.autolink unchanged." >&2
      return "$selection_status"
    else
      git -C "$repo_root" config --unset-all worktree.autolink 2>/dev/null || true
      if [ -n "$selection" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] && git -C "$repo_root" config --add worktree.autolink "$line"
        done <<EOF
$selection
EOF
      fi
      echo "Updated worktree.autolink entries."
    fi
  fi
  # Copies are opt-in and must name ignored/untracked top-level entries.
  if ! command -v fzf >/dev/null 2>&1; then
    echo "For copies: git config --local --add worktree.autocopy <top-level ignored entry>" >&2
  else
    local copy_selection copy_status prior_copies line copied
    prior_copies=$(git -C "$repo_root" config --get-all worktree.autocopy 2>/dev/null || true)
    copy_selection=$(printf '%s\n' "${raw[@]}" | sed 's#/.*##' | sort -u |
      fzf --multi --prompt="Select entries to copy (optional): " --header="Current copies: ${prior_copies:-<none>}")
    copy_status=$?
    if [ "$copy_status" -eq 130 ]; then
      echo "Copy selection cancelled; leaving worktree.autocopy unchanged."
    elif [ "$copy_status" -gt 1 ]; then
      echo "Copy selection failed; leaving worktree.autocopy unchanged." >&2
      return "$copy_status"
    else
      git -C "$repo_root" config --unset-all worktree.autocopy 2>/dev/null || true
      if [ -n "$copy_selection" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] && git -C "$repo_root" config --add worktree.autocopy "$line"
        done <<EOF
$copy_selection
EOF
      fi
      # A copy and a link must not compete for the same configured name.
      # Rebuild autolink by exact string comparison, never regex matching.
      if [ -n "$copy_selection" ]; then
        local -a remaining_links=()
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          copied=0
          while IFS= read -r selected; do
            [ "$line" != "$selected" ] || { copied=1; break; }
          done <<EOF
$copy_selection
EOF
          [ "$copied" -eq 1 ] || remaining_links+=("$line")
        done < <(git -C "$repo_root" config --get-all worktree.autolink 2>/dev/null || true)
        git -C "$repo_root" config --unset-all worktree.autolink 2>/dev/null || true
        for line in "${remaining_links[@]}"; do
          git -C "$repo_root" config --add worktree.autolink "$line"
        done
      fi
      echo "Updated worktree.autocopy entries."
    fi
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
