# Commit with an AI-proposed message. Commits directly by default; pass -e to
# review/edit the message in vi first.
_gcpropose_commit() {
  local edit=0 msg
  local -a propose_args commit_args
  propose_args=()
  commit_args=()
  if [ "$1" = "-a" ]; then
    propose_args=(-a)
    commit_args=(-a)
    shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      -e|--edit) edit=1 ;;
      -h|--help)
        echo "Usage: gcamp|gcmp [-e]  (-e: review message in vi before committing)"
        return 0
        ;;
      *) echo "Unknown argument: $1" >&2; return 1 ;;
    esac
    shift
  done

  msg=$(gcpropose "${propose_args[@]}") || return 1
  if [ "$edit" -eq 1 ]; then
    msg=$(printf '%s\n' "$msg" | VISUAL=vi EDITOR=vi vipe) || return 1
  fi
  if [ -z "${msg//[[:space:]]/}" ]; then
    echo "Empty commit message; aborting." >&2
    return 1
  fi
  git commit "${commit_args[@]}" -m "$msg"
}

gcamp() {
  _gcpropose_commit -a "$@"
}

gcmp() {
  _gcpropose_commit "$@"
}

gcpropose() {
  local mode="staged"
  while [ $# -gt 0 ]; do
    case "$1" in
      -a) mode="all"; shift ;;
      -h|--help)
        cat <<EOF
Usage: gcpropose [-a]

Propose a short git commit subject line using the fast LLM tier (${MODEL_FAST:-unset}).

Defaults:
  - without -a: uses staged diff (git diff --staged)
  - with -a   : uses full diff vs HEAD (git diff HEAD)
EOF
        return 0
        ;;
      *)
        echo "Unknown arg: $1" >&2
        return 2
        ;;
    esac
  done

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a git repository." >&2
    return 1
  fi

  local diff
  if [ "$mode" = "all" ]; then
    diff=$(git diff --no-color --no-ext-diff --unified=0 HEAD | sed '/^ /d')
  else
    diff=$(git diff --no-color --no-ext-diff --unified=0 --staged | sed '/^ /d')
  fi

  if [ -z "$diff" ]; then
    if [ "$mode" = "all" ]; then
      echo "No changes vs HEAD." >&2
    else
      echo "No staged changes." >&2
    fi
    return 1
  fi

  local git_status
  git_status=$(git status --porcelain=v1 2>/dev/null || true)

  local max_chars=10000
  diff=$(printf "%s" "$diff" | head -c "$max_chars")

  local name_status
  if [ "$mode" = "all" ]; then
    name_status=$(git diff --name-status HEAD 2>/dev/null || true)
  else
    name_status=$(git diff --name-status --staged 2>/dev/null || true)
  fi

  local prompt
  prompt=$(cat <<EOF
Propose a concise git commit subject line based on the changes.

Rules:
- Output ONLY the commit subject line.
- Imperative mood.
- Max 72 characters.
- No quotes, no backticks, no trailing period.

git status --porcelain:
${git_status}

files changed:
${name_status}

git diff (truncated):
${diff}
EOF
  )

  local message
  message=$(llm_chat fast \
    "You write excellent, conventional git commit subject lines." \
    "$prompt") || return 1
  message=$(printf "%s" "$message" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [ -z "$message" ]; then
    echo "Model returned an empty commit subject." >&2
    return 1
  fi

  printf "%s\n" "$message"
}
