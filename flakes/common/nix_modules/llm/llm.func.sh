# llm_chat <smart|fast> <system-prompt> <user-prompt>
#
# Sends one chat completion to LiteLLM and prints the reply text. Model and
# reasoning come from MODEL_<TIER> / MODEL_<TIER>_REASONING (set by the
# ringofstorms.llm NixOS module); export them to override per shell session.
# Temperature and token limits are intentionally never sent.
llm_chat() {
  if [ $# -ne 3 ]; then
    printf 'Usage: llm_chat <smart|fast> <system-prompt> <user-prompt>\n' >&2
    return 2
  fi

  local model reasoning dep payload curl_out http_code body message
  case "$1" in
    smart) model=${MODEL_SMART:-}; reasoning=${MODEL_SMART_REASONING:-} ;;
    fast) model=${MODEL_FAST:-}; reasoning=${MODEL_FAST_REASONING:-} ;;
    *)
      printf 'llm_chat: unknown tier: %s (expected smart or fast)\n' "$1" >&2
      return 2
      ;;
  esac

  if [ -z "$model" ] || [ -z "${LLM_BASE_URL:-}" ]; then
    printf 'llm_chat: LLM_BASE_URL and the model for tier "%s" must be set.\n' "$1" >&2
    return 1
  fi

  for dep in curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      printf 'Missing dependency: %s\n' "$dep" >&2
      return 1
    fi
  done

  payload=$(jq -n \
    --arg model "$model" \
    --arg reasoning "$reasoning" \
    --arg system "$2" \
    --arg user "$3" \
    '{
      model: $model,
      messages: [
        { role: "system", content: $system },
        { role: "user", content: $user }
      ]
    } + (if $reasoning == "" then {} else { reasoning_effort: $reasoning } end)') || return 1

  # Fail fast when the endpoint is unreachable. LLM_MAX_TIME (seconds) caps the
  # whole request for background callers; interactive tools leave it unset
  # since reasoning models can take a while.
  # An empty "Authorization:" header makes curl send no Authorization header.
  curl_out=$(printf '%s' "$payload" | curl -sS --noproxy '*' -w '\n%{http_code}' \
    --connect-timeout 5 ${LLM_MAX_TIME:+--max-time "$LLM_MAX_TIME"} \
    -X POST "${LLM_BASE_URL%/}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization:${LITELLM_API_KEY:+ Bearer ${LITELLM_API_KEY}}" \
    --data-binary @-) || return 1
  http_code=${curl_out##*$'\n'}
  body=${curl_out%$'\n'*}

  case "$http_code" in
    2??) ;;
    *)
      printf 'LiteLLM request failed (HTTP %s, model %s).\n%s\n' "$http_code" "$model" "$body" >&2
      return 1
      ;;
  esac

  message=$(printf '%s' "$body" | jq -r '
    .choices[0].message.content
    | if type == "string" then .
      elif type == "array" then (map(select(.type == "text") | .text) | join(""))
      else "" end
  ' 2>/dev/null) || message=""

  if [ -z "$message" ]; then
    printf 'Failed to parse model response (model %s).\n%s\n' "$model" "$body" >&2
    return 1
  fi

  printf '%s\n' "$message"
}
