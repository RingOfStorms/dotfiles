copy_ignored() {
  local DRY_RUN=0
  local USE_FZF=1
  local -a PATTERNS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --no-fzf) USE_FZF=0; shift ;;
      -h|--help) copy_ignored_usage; return 0 ;;
      --) shift; break ;;
      *) PATTERNS+=("$1"); shift ;;
    esac
  done
  copy_ignored_usage() {
    cat <<EOF
Usage: copy_ignored [--dry-run] [--no-fzf] [pattern ...]
Interactively or non-interactively copy files/dirs into the current worktree
for files/dirs that exist in the main repository root but are git-ignored /
untracked.
EOF
  }
  # Determine the main repo root using git-common-dir (handles worktrees)
  local common_dir repo_root
  if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "Error: not in a git repository." >&2
    return 2
  fi
  if [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir="$(pwd)/$common_dir"
  fi
  repo_root="${common_dir%%/.git*}"
  if [ -z "$repo_root" ]; then
    echo "Error: unable to determine repository root." >&2
    return 2
  fi
  local -a candidates=()
  while IFS= read -r -d '' file; do
    candidates+=("$file")
  done < <(git -C "$repo_root" ls-files --others --ignored --exclude-standard -z || true)
  if [ ${#candidates[@]} -eq 0 ]; then
    echo "No untracked/ignored files found in $repo_root"
    return 0
  fi
  local -a tops=()
  for c in "${candidates[@]}"; do
    c="${c%/}"
    local top="${c%%/*}"
    [ -z "$top" ] && continue
    local found=0
    for existing in "${tops[@]}"; do
      [ "$existing" = "$top" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && tops+=("$top")
  done
  if [ ${#tops[@]} -eq 0 ]; then
    echo "No top-level ignored/untracked entries found in $repo_root"
    return 0
  fi
  local -a filtered
  if [ ${#PATTERNS[@]} -gt 0 ]; then
    for t in "${tops[@]}"; do
      for p in "${PATTERNS[@]}"; do
        if [[ "$t" == *"$p"* ]]; then
          filtered+=("$t")
          break
        fi
      done
    done
  else
    filtered=("${tops[@]}")
  fi
  if [ ${#filtered[@]} -eq 0 ]; then
    echo "No candidates match the provided patterns." >&2
    return 0
  fi
  local -a chosen
  if command -v fzf >/dev/null 2>&1 && [ "$USE_FZF" -eq 1 ]; then
    local selected
    selected=$(printf "%s\n" "${filtered[@]}" | fzf --multi --height=40% --border --prompt="Select files to copy: " --preview "if [ -f '$repo_root'/{} ]; then bat --color always --paging=never --style=plain '$repo_root'/{}; else ls -la '$repo_root'/{}; fi")
    if [ -z "$selected" ]; then
      echo "No files selected." && return 0
    fi
    chosen=()
    while IFS= read -r line; do
      chosen+=("$line")
    done <<EOF
$selected
EOF
  else
    chosen=("${filtered[@]}")
  fi
  local worktree_root
  worktree_root=$(pwd)
  echo "Repository root: $repo_root"
  echo "Worktree root : $worktree_root"
  local -a created=()
  local -a skipped=()
  local -a errors=()
  for rel in "${chosen[@]}"; do
    rel=${rel%%$'\n'}
    local src="${repo_root}/${rel}"
    local dst="${worktree_root}/${rel}"
    if [ ! -e "$src" ]; then
      errors+=("$rel (source missing)")
      continue
    fi
    if [ -e "$dst" ]; then
      echo "Skipping $rel (destination exists)"
      skipped+=("$rel")
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ -d "$src" ]; then
        echo "DRY RUN: cp -r '$src' '$dst'"
      else
        echo "DRY RUN: cp '$src' '$dst'"
      fi
    else
      local copy_result=0
      if [ -d "$src" ]; then
        if cp -r "$src" "$dst"; then
          copy_result=0
        else
          copy_result=1
        fi
      else
        if cp "$src" "$dst"; then
          copy_result=0
        else
          copy_result=1
        fi
      fi
      
      if [ "$copy_result" -eq 0 ]; then
        echo "Copied: $rel"
        created+=("$rel")
      else
        echo "Failed to copy: $rel" >&2
        errors+=("$rel (copy failed)")
      fi
    fi
  done
  echo
  echo "Summary:"
  echo "  Copied: ${#created[@]}"
  [ ${#created[@]} -gt 0 ] && printf '    %s\n' "${created[@]}"
  echo "  Skipped: ${#skipped[@]}"
  [ ${#skipped[@]} -gt 0 ] && printf '    %s\n' "${skipped[@]}"
  echo "  Errors: ${#errors[@]}"
  [ ${#errors[@]} -gt 0 ] && printf '    %s\n' "${errors[@]}"
  return 0
}
