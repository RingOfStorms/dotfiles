link_ignored() {
  local DRY_RUN=0
  local USE_FZF=1
  local AUTO=0
  local COPY=0
  local -a PATTERNS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --no-fzf) USE_FZF=0; shift ;;
      --auto) AUTO=1; shift ;;
      --copy) COPY=1; shift ;;
      -h|--help) link_ignored_usage; return 0 ;;
      --) shift; break ;;
      *) PATTERNS+=("$1"); shift ;;
    esac
  done

  link_ignored_usage() {
    cat <<EOF
Usage: link_ignored [--dry-run] [--no-fzf] [--auto] [--copy] [pattern ...]

Interactively or non-interactively create symlinks (or opt-in copies) in the
current worktree for top-level entries ignored/untracked in the main root.

Defaults:
- If no patterns provided, tries git config worktree.autolink (multi)
- --copy reads only explicit patterns or git config worktree.autocopy (multi)
- --copy matches exact top-level names only; never infers a copy from a link pattern
- With --auto and defaults present, skips fzf and links immediately
EOF
  }

  local repo_root
  repo_root=$(_branch__repo_root) || {
    echo "Error: not in a non-bare Git repository." >&2
    return 2
  }

  _li_load_defaults() {
    local -a cfg=()
    local config_key=worktree.autolink
    [ "$COPY" -eq 0 ] || config_key=worktree.autocopy
    while IFS= read -r line; do
      [ -n "$line" ] && cfg+=("$line")
    done < <(git -C "$repo_root" config --get-all "$config_key" 2>/dev/null || true)
    if [ ${#cfg[@]} -gt 0 ]; then
      PATTERNS=("${cfg[@]}")
      return 0
    fi

    if [ "$COPY" -eq 0 ] && [ -n "${LINK_IGNORED_DEFAULTS:-}" ]; then
      if [ -n "${ZSH_VERSION:-}" ]; then
        eval "PATTERNS=(${=LINK_IGNORED_DEFAULTS})"
      else
        read -r -a PATTERNS <<< "$LINK_IGNORED_DEFAULTS"
      fi
      return 0
    fi
    return 1
  }

  # Try to load defaults if none provided
  if [ ${#PATTERNS[@]} -eq 0 ]; then
    _li_load_defaults || true
  fi

  if [ "$COPY" -eq 1 ] && [ ${#PATTERNS[@]} -eq 0 ]; then
    echo "No worktree.autocopy entries configured; nothing copied."
    return 0
  fi
  # If AUTO requested and we have patterns, skip fzf
  if [ $AUTO -eq 1 ] && [ ${#PATTERNS[@]} -gt 0 ]; then
    USE_FZF=0
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

  # Hard-coded top-level excludes to avoid noisy build outputs
  local -a EXCLUDES=(build dist)
  if [ ${#tops[@]} -gt 0 ]; then
    local -a tops_filtered=()
    for t in "${tops[@]}"; do
      local skip=0
      for e in "${EXCLUDES[@]}"; do [ "$t" = "$e" ] && skip=1 && break; done
      [ $skip -eq 0 ] && tops_filtered+=("$t")
    done
    tops=("${tops_filtered[@]}")
  fi
 
  if [ ${#tops[@]} -eq 0 ]; then
    echo "No top-level ignored/untracked entries found in $repo_root"
    return 0
  fi

  local -a filtered
  if [ ${#PATTERNS[@]} -gt 0 ]; then
    for t in "${tops[@]}"; do
      for p in "${PATTERNS[@]}"; do
        if { [ "$COPY" -eq 1 ] && [ "$t" = "$p" ]; } || { [ "$COPY" -eq 0 ] && [[ "$t" == *"$p"* ]]; }; then
          filtered+=("$t")
          break
        fi
      done
    done
  else
    filtered=("${tops[@]}")
  fi
  if [ "$COPY" -eq 1 ]; then
    for p in "${PATTERNS[@]}"; do
      local found=0
      for t in "${filtered[@]}"; do [ "$t" != "$p" ] || { found=1; break; }; done
      if [ "$found" -eq 0 ]; then
        printf 'Not a top-level ignored/untracked copy entry: %s\n' "$p" >&2
        return 1
      fi
    done
  fi

  if [ ${#filtered[@]} -eq 0 ]; then
    echo "No candidates match the provided patterns." >&2
    [ "$COPY" -eq 0 ] && return 0 || return 1
  fi

  local -a chosen
  if command -v fzf >/dev/null 2>&1 && [ "$USE_FZF" -eq 1 ]; then
    local selected
    selected=$(printf "%s\n" "${filtered[@]}" | fzf --multi --height=40% --border --prompt="Select items to link: " --preview "if [ -f '$repo_root'/{} ]; then bat --color always --paging=never --style=plain '$repo_root'/{}; else ls -la '$repo_root'/{}; fi")
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
    # Copying a mixed tracked/untracked directory would duplicate tracked
    # project content. Explicit copy selections must have no tracked files.
    if [ "$COPY" -eq 1 ] && [ "$(git -C "$repo_root" ls-files -z -- ":(literal)$rel" | wc -c)" -gt 0 ]; then
      errors+=("$rel (contains tracked files; not copied)")
      continue
    fi

    if [ ! -e "$src" ]; then
      errors+=("$rel (source missing)")
      continue
    fi

    if [ -L "$dst" ]; then
      echo "Skipping $rel (already symlink)"
      skipped+=("$rel")
      continue
    fi
    if [ -e "$dst" ]; then
      echo "Skipping $rel (destination exists)"
      skipped+=("$rel")
      continue
    fi

    if ! mkdir -p "$(dirname "$dst")"; then
      errors+=("$rel (destination parent failed)")
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$COPY" -eq 1 ]; then echo "DRY RUN: cp -R '$src' '$dst'"
      else echo "DRY RUN: ln -s '$src' '$dst'"; fi
    elif [ "$COPY" -eq 1 ]; then
      if cp -R -- "$src" "$dst"; then
        echo "Copied: $rel"
        created+=("$rel")
      else
        echo "Failed to copy: $rel" >&2
        errors+=("$rel (copy failed)")
      fi
    elif ln -s "$src" "$dst"; then
      echo "Linked: $rel"
      created+=("$rel")
    else
      echo "Failed to link: $rel" >&2
      errors+=("$rel (link failed)")
    fi
  done

  echo
  echo "Summary:"
  if [ "$COPY" -eq 1 ]; then echo "  Copied: ${#created[@]}"; else echo "  Linked: ${#created[@]}"; fi
  [ ${#created[@]} -gt 0 ] && printf '    %s\n' "${created[@]}"
  echo "  Skipped: ${#skipped[@]}"
  [ ${#skipped[@]} -gt 0 ] && printf '    %s\n' "${skipped[@]}"
  echo "  Errors: ${#errors[@]}"
  [ ${#errors[@]} -gt 0 ] && printf '    %s\n' "${errors[@]}"

  [ ${#errors[@]} -eq 0 ]
}
