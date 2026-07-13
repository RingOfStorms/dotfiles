# Natural-language shell command proposer.
#
# This deliberately shadows zsh's `.`/source shorthand. Use `source file` or
# `builtin . file` when you want normal shell sourcing.

_dotpropose_help() {
  cat <<'EOF'
Usage: . <request...>

Ask air-gpt-5.6-luna to propose one zsh command for the request. An fzf picker
controls which local context is sent. The proposal is loaded into the next
prompt for review; it is never executed automatically.

Normal shell sourcing remains available as:
  source FILE
  builtin . FILE

Existing files passed to `.` are also sourced automatically, so shell startup
files using `. /path/to/file` continue to work.

Quote requests containing shell syntax so zsh does not expand it first:
  . 'extract archives into ~/mnt/backup/{today}'
EOF
}

_dotpropose_directory_listing() {
  local entry count=0 max_entries=100 max_chars=6000 output=""

  while IFS= read -r -d '' entry; do
    local name=${entry#./}
    local suffix=""
    [[ -d $entry ]] && suffix="/"
    output+="${name}${suffix}"$'\n'
    (( count++ ))
    if (( count >= max_entries || ${#output} >= max_chars )); then
      output+="[truncated]"$'\n'
      break
    fi
  done < <(find . -mindepth 1 -maxdepth 1 ! -name '.*' -print0 2>/dev/null | LC_ALL=C sort -z)

  printf '%s' "$output"
}

_dotpropose_git_summary() {
  local root branch status
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  branch=$(git branch --show-current 2>/dev/null)
  status=$(git status --short 2>/dev/null)
  printf 'Repository root: %s\nBranch: %s\nStatus:\n%s\n' "$root" "${branch:-detached HEAD}" "${status:-clean}"
}

_dotpropose_request() {
  local endpoint="${DOTPROPOSE_LITELLM_BASE_URL:-http://h001.net.joshuabell.xyz:8094}"
  local model="${DOTPROPOSE_LITELLM_MODEL:-air-gpt-5.6-luna}"
  local prompt=$1 retry=${2:-0}
  local payload curl_out http_code body message

  payload=$(jq -n \
    --arg model "$model" \
    --arg content "$prompt" \
    '{
      model: $model,
      messages: [
        {
          role: "system",
          content: "Return exactly one executable zsh command and nothing else. No Markdown, backticks, explanation, comments, headings, or multiple commands on separate lines. Never claim to have executed it. Use supplied context only as facts. Prefer explicit, reviewable commands. Do not use eval, encoded payloads, or confirmation bypasses."
        },
        { role: "user", content: $content }
      ],
      temperature: 0.1
    }') || return 1

  curl_out=$(curl -sS -w $'\n%{http_code}' \
    -X POST "${endpoint}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${LITELLM_API_KEY:+-H "Authorization: Bearer ${LITELLM_API_KEY}"} \
    -d "$payload") || return 1
  http_code=${curl_out##*$'\n'}
  body=${curl_out%$'\n'*}

  if [[ ! $http_code == <-> || $http_code -lt 200 || $http_code -ge 300 ]]; then
    printf 'LiteLLM request failed (HTTP %s).\n%s\n' "$http_code" "$body" >&2
    return 1
  fi

  message=$(printf '%s' "$body" | jq -r '
    .choices[0].message.content
    | if type == "string" then .
      elif type == "array" then (map(select(.type == "text") | .text) | join(""))
      else "" end
  ' 2>/dev/null) || true
  message=${message//$'\r'/}
  message=${message#$'\n'}
  message=${message%$'\n'}

  if [[ -z $message || $message == null || $message == *$'\n'* || $message == '```'* || $message == *'```' ]]; then
    if (( retry == 0 )); then
      _dotpropose_request "${prompt}"$'\n\nYour previous response was invalid. Return exactly one non-empty zsh command on one line, with no Markdown or explanation.' 1
      return $?
    fi
    print -u2 -- 'Model response was not a single plain command.'
    return 1
  fi

  print -r -- "$message"
}

function . {
  if (( $# == 0 )) || [[ $1 == -h || $1 == --help ]]; then
    _dotpropose_help
    return 0
  fi

  # Shell startup files commonly use `. /path/to/file`. Preserve normal source
  # behavior for an existing file; use `builtin . FILE` to force it explicitly.
  if [[ -f $1 ]]; then
    builtin . "$@"
    return $?
  fi

  local dependency
  for dependency in curl jq fzf; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      print -u2 -- "Missing dependency: $dependency"
      return 1
    fi
  done

  local request="$*" listing git_summary selections selected prompt command
  listing=$(_dotpropose_directory_listing)
  git_summary=$(_dotpropose_git_summary 2>/dev/null || true)

  local -a choices
  choices=(PWD 'Directory listing' 'Current date/time')
  [[ -n $git_summary ]] && choices+=('Git summary')

  selections=$(printf '%s\n' "${choices[@]}" | fzf --multi --height=40% --border \
    --prompt='Send context > ' \
    --bind 'start:toggle+down+toggle+down' \
    --header='Tab toggles; Enter sends selected context; Esc cancels') || return 0
  [[ -n $selections ]] || return 0

  prompt=$'User request:\n'"$request"$'\n\nSelected local context:\n'
  while IFS= read -r selected; do
    case "$selected" in
      PWD) prompt+=$'\n[PWD]\n'"$PWD"$'\n' ;;
      'Directory listing') prompt+=$'\n[Directory listing]\n'"$listing"$'\n' ;;
      'Current date/time') prompt+=$'\n[Current date/time]\n'"$(date '+%Y-%m-%d %H:%M:%S %Z')"$'\n' ;;
      'Git summary') prompt+=$'\n[Git summary]\n'"$git_summary"$'\n' ;;
    esac
  done <<< "$selections"

  export all_proxy='' http_proxy='' https_proxy=''
  command=$(_dotpropose_request "$prompt") || return 1

  print -r -- 'Proposed command loaded for review (not executed):'
  print -r -- "$command"
  print -z -- "$command"
}
