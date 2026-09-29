#!/usr/bin/env zsh
# Probes the GitHub Copilot API to discover which models are available
# with the current credentials.
#
# Usage:
#   ./probe-copilot-models.sh [--token-dir DIR] [--nix] [--filter TYPE]
#
# Token lookup order:
#   1. --token-dir DIR  (e.g. /var/lib/litellm/github_copilot)
#   2. GH_COPILOT_TOKEN env var (raw OAuth token)
#   3. ~/.config/github-copilot/hosts.json or apps.json
#   4. `gh auth token` (direct models-endpoint authentication)
# Output: model IDs, one per line. With --nix it emits four Nix list
# literals (chat-only, both APIs, responses-only, embeddings) ready to
# paste into the LiteLLM config.
#
# The upstream /models catalog provides supported endpoints; classification
# uses that metadata instead of model-name heuristics.

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────
TOKEN_DIR=""
OUTPUT_FORMAT="plain"  # plain | nix
FILTER=""              # optional grep filter, e.g. "chat"

# ── arg parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token-dir)  TOKEN_DIR="$2";        shift 2 ;;
    --nix)        OUTPUT_FORMAT="nix";   shift ;;
    --filter)     FILTER="$2";           shift 2 ;;
    -h|--help)
      sed -n '2,/^$/s/^# \?//p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── locate OAuth token ──────────────────────────────────────────────
OAUTH_TOKEN=""

# 1. Custom token dir (same layout as ~/.config/github-copilot/)
if [[ -n "$TOKEN_DIR" ]]; then
  for f in "${TOKEN_DIR}/hosts.json" "${TOKEN_DIR}/apps.json"; do
    if [[ -f "$f" ]]; then
      token=$(jq -r 'to_entries[] | select(.key | startswith("github.com")) | .value.oauth_token // empty' "$f" 2>/dev/null || true)
      if [[ -n "$token" ]]; then
        OAUTH_TOKEN="$token"
        echo "Found OAuth token in ${f}" >&2
        break
      fi
    fi
  done
fi

# 2. Environment variable
if [[ -z "$OAUTH_TOKEN" ]]; then
  OAUTH_TOKEN="${GH_COPILOT_TOKEN:-}"
  [[ -n "$OAUTH_TOKEN" ]] && echo "Using GH_COPILOT_TOKEN env var" >&2
fi

# 3. Standard config locations
if [[ -z "$OAUTH_TOKEN" ]]; then
  for f in ~/.config/github-copilot/hosts.json ~/.config/github-copilot/apps.json; do
    if [[ -f "$f" ]]; then
      token=$(jq -r 'to_entries[] | select(.key | startswith("github.com")) | .value.oauth_token // empty' "$f" 2>/dev/null || true)
      if [[ -n "$token" ]]; then
        OAUTH_TOKEN="$token"
        echo "Found OAuth token in ${f}" >&2
        break
      fi
    fi
  done
fi

if [[ -z "$OAUTH_TOKEN" ]]; then
  echo "No GitHub Copilot OAuth token found; will try gh auth token." >&2
fi

# ── exchange for Copilot API token ───────────────────────────────────
echo "Exchanging OAuth token for Copilot API token ..." >&2

TOKEN_RESPONSE=""
if [[ -n "$OAUTH_TOKEN" ]]; then
  TOKEN_RESPONSE=$(curl -sf \
    -H "authorization: token ${OAUTH_TOKEN}" \
    -H "accept: application/json" \
    -H "editor-version: vscode/1.95.0" \
    -H "editor-plugin-version: copilot-chat/0.26.7" \
    -H "user-agent: GitHubCopilotChat/0.26.7" \
    "https://api.github.com/copilot_internal/v2/token" 2>/dev/null) || TOKEN_RESPONSE=""
fi

API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
API_BASE=$(echo "$TOKEN_RESPONSE" | jq -r '.endpoints.api // "https://api.githubcopilot.com"')

if [[ -z "$API_TOKEN" ]]; then
  # `gh auth token` also authenticates directly to the upstream /models
  # endpoint. This is useful when the stored Copilot OAuth token is stale.
  API_TOKEN=$(gh auth token 2>/dev/null || true)
  if [[ -z "$API_TOKEN" ]]; then
    echo "ERROR: Failed to obtain Copilot API token. Check OAuth credentials or run gh auth login." >&2
    exit 1
  fi
  API_BASE="https://api.githubcopilot.com"
  echo "Using GitHub CLI token for the models endpoint." >&2
fi

echo "API base: ${API_BASE}" >&2

# ── fetch models ─────────────────────────────────────────────────────
echo "Fetching available models ..." >&2

MODELS_RESPONSE=$(curl -sf \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "editor-version: vscode/1.95.0" \
  -H "editor-plugin-version: copilot-chat/0.26.7" \
  -H "user-agent: GitHubCopilotChat/0.26.7" \
  -H "copilot-integration-id: vscode-chat" \
  -H "x-github-api-version: 2025-04-01" \
  "${API_BASE}/models" 2>/dev/null) || {
    echo "ERROR: Failed to fetch models." >&2
    exit 1
  }

# The upstream catalog includes legacy IDs without supported endpoints.
# Keep picker models, plus embedding models that the API exposes separately.
AVAILABLE_MODELS=$(echo "$MODELS_RESPONSE" | jq --arg f "$FILTER" '
  [.data[]
    | select(($f == "") or (.capabilities.type == $f))
    | select(.model_picker_enabled == true or .capabilities.type == "embeddings")
    | select(
        ((.supported_endpoints // []) | index("/chat/completions") != null)
        or ((.supported_endpoints // []) | index("/responses") != null)
        or (.capabilities.type == "embeddings")
      )]
  | sort_by(.id)
')
MODEL_IDS=$(echo "$AVAILABLE_MODELS" | jq -r '.[].id')

TOTAL=$(echo "$MODEL_IDS" | grep -c . || true)

# ── summary table (stderr) ──────────────────────────────────────────
echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "Found ${TOTAL} supported models" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "" >&2

echo "$AVAILABLE_MODELS" | jq -r '
  .[] |
  "  \(.id)\t\(.vendor // "-")\t\(.capabilities.type // "-")\t\(if .billing.is_premium then "premium" else "included" end)"
' >&2
echo "" >&2

# Classify by actual upstream endpoint support.
CHAT_ONLY_MODELS=$(echo "$AVAILABLE_MODELS" | jq -r '
  [.[] | select((.supported_endpoints // []) | index("/chat/completions") != null)
        | select((.supported_endpoints // []) | index("/responses") == null)]
  | .[].id
')
BOTH_MODELS=$(echo "$AVAILABLE_MODELS" | jq -r '
  [.[] | select((.supported_endpoints // []) | index("/chat/completions") != null)
        | select((.supported_endpoints // []) | index("/responses") != null)]
  | .[].id
')
RESPONSES_MODELS=$(echo "$AVAILABLE_MODELS" | jq -r '
  [.[] | select((.supported_endpoints // []) | index("/responses") != null)
        | select((.supported_endpoints // []) | index("/chat/completions") == null)]
  | .[].id
')
EMBEDDING_MODELS=$(echo "$AVAILABLE_MODELS" | jq -r '
  [.[] | select(.capabilities.type == "embeddings")]
  | .[].id
')

CHAT_ONLY_COUNT=$(echo "$CHAT_ONLY_MODELS" | grep -c . || true)
BOTH_COUNT=$(echo "$BOTH_MODELS" | grep -c . || true)
RESPONSES_COUNT=$(echo "$RESPONSES_MODELS" | grep -c . || true)
EMBEDDING_COUNT=$(echo "$EMBEDDING_MODELS" | grep -c . || true)
echo "  Chat-only: ${CHAT_ONLY_COUNT}, both APIs: ${BOTH_COUNT}, responses-only: ${RESPONSES_COUNT}, embeddings: ${EMBEDDING_COUNT}" >&2
echo "" >&2

# ── output (stdout) ─────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "nix" ]]; then
  for group in CHAT_ONLY BOTH RESPONSES EMBEDDING; do
    case "$group" in
      CHAT_ONLY) models="$CHAT_ONLY_MODELS"; label="Chat-only models" ;;
      BOTH) models="$BOTH_MODELS"; label="Models supporting both APIs" ;;
      RESPONSES) models="$RESPONSES_MODELS"; label="Responses-only models" ;;
      EMBEDDING) models="$EMBEDDING_MODELS"; label="Embedding models" ;;
    esac
    echo "# ${label}"
    echo "["
    echo "$models" | while read -r m; do
      [[ -z "$m" ]] && continue
      echo "  \"${m}\""
    done
    echo "]"
    if [[ "$group" != "EMBEDDING" ]]; then
      echo ""
    fi
  done
else
  echo "$MODEL_IDS"
fi
