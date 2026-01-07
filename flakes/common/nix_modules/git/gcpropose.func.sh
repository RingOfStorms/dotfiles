gcamp() {
  VISUAL=vi EDITOR=vi git commit -a -m "$(gcpropose -a | vipe)"
}

gcmp() {
  VISUAL=vi EDITOR=vi git commit -m "$(gcpropose | vipe)"
}

gcpropose() {
  local LITELLM_BASE_URL="http://h001.net.joshuabell.xyz:8094"
  local LITELLM_MODEL="azure-gpt-5-mini-2025-08-07"

  local mode="staged"
  while [ $# -gt 0 ]; do
    case "$1" in
      -a) mode="all"; shift ;;
      -h|--help)
        cat <<EOF
Usage: gcpropose [-a]

Propose a short git commit subject line using a LiteLLM model.

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

  if ! command -v curl >/dev/null 2>&1; then
    echo "Missing dependency: curl" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Missing dependency: jq" >&2
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

  local payload_chat
  payload_chat=$(jq -n \
    --arg model "$LITELLM_MODEL" \
    --arg content "$prompt" \
    '{
      model: $model,
      messages: [
        {
          role: "system",
          content: "You write excellent, conventional git commit subject lines."
        },
        {
          role: "user",
          content: $content
        }
      ],
      temperature: 0.2
    }')

  local curl_out http_code body
  curl_out=$(curl -sS -w "\n%{http_code}" \
    -X POST "${LITELLM_BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${LITELLM_API_KEY:+-H "Authorization: Bearer ${LITELLM_API_KEY}"} \
    -d "$payload_chat") || return 1

  http_code=$(printf "%s" "$curl_out" | tail -n 1)
  body=$(printf "%s" "$curl_out" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "LiteLLM request failed (HTTP $http_code)." >&2
    printf "%s\n" "$body" >&2
    return 1
  fi

  local message
  message=$(printf "%s" "$body" | jq -r '
    .choices[0].message.content
    | if type == "string" then .
      elif type == "array" then (map(select(.type=="text") | .text) | join(""))
      else ""
      end
  ' 2>/dev/null || true)
  message=$(printf "%s" "$message" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [ -n "$message" ] && [ "$message" != "null" ]; then
    printf "%s\n" "$message"
    return 0
  fi

  local payload_responses
  payload_responses=$(jq -n \
    --arg model "$LITELLM_MODEL" \
    --arg input "$prompt" \
    '{
      model: $model,
      input: $input,
      max_output_tokens: 64
    }')

  curl_out=$(curl -sS -w "\n%{http_code}" \
    -X POST "${LITELLM_BASE_URL}/v1/responses" \
    -H "Content-Type: application/json" \
    ${LITELLM_API_KEY:+-H "Authorization: Bearer ${LITELLM_API_KEY}"} \
    -d "$payload_responses") || return 1

  http_code=$(printf "%s" "$curl_out" | tail -n 1)
  body=$(printf "%s" "$curl_out" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "LiteLLM request failed (HTTP $http_code)." >&2
    printf "%s\n" "$body" >&2
    return 1
  fi

  message=$(printf "%s" "$body" | jq -r '(.output_text // empty)' 2>/dev/null || true)
  message=$(printf "%s" "$message" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [ -z "$message" ] || [ "$message" = "null" ]; then
    echo "Failed to parse model response." >&2
    printf "%s\n" "$body" >&2
    return 1
  fi

  printf "%s\n" "$message"
}
