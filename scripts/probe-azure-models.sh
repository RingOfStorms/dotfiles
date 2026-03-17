#!/usr/bin/env zsh
# Probes an Azure OpenAI-compatible endpoint to discover which chat/completion
# models are actually callable with the current credentials.
#
# Usage:
#   ./probe-azure-models.sh [--base URL] [--api-version VER] [--api-key KEY] [--type chat|embedding|all]
#
# Defaults match the h001 litellm config (upstream proxy on tailscale).
#
# Output: a list of working model IDs, one per line, suitable for pasting
# into the nix config.  With --nix it emits a nix list literal.

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────
BASE_URL="http://100.64.0.8:9010/azure"
API_VERSION="2025-04-01-preview"
API_KEY="na"
MODEL_TYPE="all"   # chat | embedding | all
OUTPUT_FORMAT="plain"  # plain | nix
PARALLEL=10

# ── arg parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)       BASE_URL="$2";      shift 2 ;;
    --api-version) API_VERSION="$2";  shift 2 ;;
    --api-key)    API_KEY="$2";       shift 2 ;;
    --type)       MODEL_TYPE="$2";    shift 2 ;;
    --nix)        OUTPUT_FORMAT="nix"; shift ;;
    --parallel)   PARALLEL="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,/^$/s/^# \?//p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── fetch model list ─────────────────────────────────────────────────
echo "Fetching model list from ${BASE_URL} ..." >&2

ALL_MODELS=$(curl -sf "${BASE_URL}/openai/models?api-version=${API_VERSION}" \
  -H "api-key: ${API_KEY}" \
  | jq -r '.data[].id')

if [[ -z "$ALL_MODELS" ]]; then
  echo "ERROR: Could not fetch models from ${BASE_URL}" >&2
  exit 1
fi

TOTAL=$(echo "$ALL_MODELS" | wc -l)
echo "Found ${TOTAL} models listed. Probing which are callable ..." >&2

# ── filter to interesting models ─────────────────────────────────────
# Skip obviously non-chat models (images, audio, realtime, whisper, dall-e,
# sora, search, similarity, transcribe, tts, diarize) unless explicitly requested.
filter_models() {
  local models="$1"
  case "$MODEL_TYPE" in
    chat)
      echo "$models" | grep -v -iE '(dall-e|whisper|sora|embedding|search|similarity|image|audio|realtime|transcribe|tts|diarize|text-embedding|code-search|text-search|text-similarity|davinci$|babbage$|curie$|ada$|instruct|canvas)'
      ;;
    embedding)
      echo "$models" | grep -iE '(embedding)'
      ;;
    all)
      echo "$models"
      ;;
  esac
}

CANDIDATE_MODELS=$(filter_models "$ALL_MODELS")
CANDIDATE_COUNT=$(echo "$CANDIDATE_MODELS" | wc -l)
echo "After filtering for type='${MODEL_TYPE}': ${CANDIDATE_COUNT} candidates" >&2

# ── probe function ───────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

probe_chat_model() {
  local model="$1"
  local result_file="$2"

  # Use max_completion_tokens (newer models reject the legacy max_tokens param)
  local body
  body=$(curl -s --max-time 15 \
    "${BASE_URL}/openai/deployments/${model}/chat/completions?api-version=${API_VERSION}" \
    -H "Content-Type: application/json" \
    -H "api-key: ${API_KEY}" \
    -d '{
      "messages": [{"role": "user", "content": "Say ok"}],
      "max_completion_tokens": 3
    }' 2>/dev/null) || body=""

  local returned_model
  returned_model=$(echo "$body" | jq -r '.model // empty' 2>/dev/null)
  local err_code
  err_code=$(echo "$body" | jq -r '.error.code // empty' 2>/dev/null)

  if [[ -n "$returned_model" ]]; then
    echo "$model" >> "$result_file"
    echo "  ✓ ${model}" >&2
  else
    echo "  ✗ ${model} (${err_code:-unknown})" >&2
  fi
}

probe_embedding_model() {
  local model="$1"
  local result_file="$2"

  local response
  response=$(curl -sf -w "\n%{http_code}" --max-time 15 \
    "${BASE_URL}/openai/deployments/${model}/embeddings?api-version=${API_VERSION}" \
    -H "Content-Type: application/json" \
    -H "api-key: ${API_KEY}" \
    -d '{
      "input": "test"
    }' 2>/dev/null) || response=$'\n000'

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "200" ]]; then
    echo "$model" >> "$result_file"
    echo "  ✓ ${model}" >&2
  else
    local err_code=""
    err_code=$(echo "$body" | jq -r '.error.code // empty' 2>/dev/null)
    echo "  ✗ ${model} (HTTP ${http_code}, ${err_code:-unknown})" >&2
  fi
}

# ── run probes in parallel ───────────────────────────────────────────
RESULTS_FILE="${TMPDIR}/results.txt"
touch "$RESULTS_FILE"

RUNNING=0
echo "$CANDIDATE_MODELS" | while read -r model; do
  [[ -z "$model" ]] && continue

  is_embedding=false
  if echo "$model" | grep -qiE 'embedding'; then
    is_embedding=true
  fi

  if $is_embedding; then
    probe_embedding_model "$model" "$RESULTS_FILE" &
  else
    probe_chat_model "$model" "$RESULTS_FILE" &
  fi

  RUNNING=$((RUNNING + 1))
  if [[ $RUNNING -ge $PARALLEL ]]; then
    wait -n 2>/dev/null || wait
    RUNNING=$((RUNNING - 1))
  fi
done

wait

# ── output ───────────────────────────────────────────────────────────
WORKING=$(sort "$RESULTS_FILE")
WORKING_COUNT=$(echo "$WORKING" | grep -c . || true)

echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "Results: ${WORKING_COUNT}/${CANDIDATE_COUNT} models are callable" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

if [[ "$OUTPUT_FORMAT" == "nix" ]]; then
  echo "["
  echo "$WORKING" | while read -r m; do
    [[ -z "$m" ]] && continue
    echo "  \"${m}\""
  done
  echo "]"
else
  echo "$WORKING"
fi
