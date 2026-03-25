#!/usr/bin/env zsh
# Probes the GitHub Copilot API to discover which models are available
# with the current credentials.
#
# Usage:
#   ./probe-copilot-models.sh [--token-dir DIR] [--nix] [--filter TYPE]
#
# Token lookup order:
#   1. --token-dir DIR  (e.g. /var/lib/litellm/github_copilot)
#   2. GH_COPILOT_TOKEN env var (raw oauth token)
#   3. ~/.config/github-copilot/hosts.json or apps.json
#
# Output: a list of model IDs, one per line.  With --nix it emits two
# nix list literals (chat models and responses-only models) ready to
# paste into the litellm config.
#
# Some models (codex variants, gpt-5.4+) only support the /responses
# API, not /chat/completions.  The --nix output separates these so
# litellm can be configured with model_info.mode = "responses".

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
  echo "ERROR: No GitHub Copilot OAuth token found." >&2
  echo "Searched:" >&2
  [[ -n "$TOKEN_DIR" ]] && echo "  ${TOKEN_DIR}/hosts.json|apps.json" >&2
  echo "  GH_COPILOT_TOKEN env var" >&2
  echo "  ~/.config/github-copilot/hosts.json|apps.json" >&2
  exit 1
fi

# ── exchange for Copilot API token ───────────────────────────────────
echo "Exchanging OAuth token for Copilot API token ..." >&2

TOKEN_RESPONSE=$(curl -sf \
  -H "authorization: token ${OAUTH_TOKEN}" \
  -H "accept: application/json" \
  -H "editor-version: vscode/1.95.0" \
  -H "editor-plugin-version: copilot-chat/0.26.7" \
  -H "user-agent: GitHubCopilotChat/0.26.7" \
  "https://api.github.com/copilot_internal/v2/token" 2>/dev/null) || {
    echo "ERROR: Token exchange request failed." >&2
    exit 1
  }

API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
API_BASE=$(echo "$TOKEN_RESPONSE" | jq -r '.endpoints.api // "https://api.githubcopilot.com"')

if [[ -z "$API_TOKEN" ]]; then
  echo "ERROR: Failed to obtain API token. Response:" >&2
  echo "$TOKEN_RESPONSE" | jq . >&2
  exit 1
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

# Extract model IDs, optionally filtering by capability type
if [[ -n "$FILTER" ]]; then
  MODEL_IDS=$(echo "$MODELS_RESPONSE" | jq -r --arg f "$FILTER" \
    '[.data[] | select(.capabilities.type == $f)] | sort_by(.id) | .[].id')
else
  MODEL_IDS=$(echo "$MODELS_RESPONSE" | jq -r '[.data[]] | sort_by(.id) | .[].id')
fi

TOTAL=$(echo "$MODEL_IDS" | grep -c . || true)

# ── summary table (stderr) ──────────────────────────────────────────
echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "Found ${TOTAL} models" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "" >&2

# Print a table to stderr with extra info
echo "$MODELS_RESPONSE" | jq -r '
  .data | sort_by(.id) | .[] |
  "  \(.id)\t\(.vendor // "-")\t\(.capabilities.type // "-")\t\(if .billing.is_premium then "premium" else "included" end)"
' >&2

echo "" >&2

# ── classify models ──────────────────────────────────────────────────
# Models matching these patterns only support the /responses endpoint,
# not /chat/completions.  This list is maintained manually since the
# /models API does not expose endpoint capabilities.
is_responses_only() {
  local m="$1"
  # codex models and gpt-5.4+ are responses-only
  [[ "$m" == *codex* ]] && return 0
  [[ "$m" == gpt-5.4* ]] && return 0
  return 1
}

CHAT_MODELS=""
RESPONSES_MODELS=""
echo "$MODEL_IDS" | while read -r m; do
  [[ -z "$m" ]] && continue
  if is_responses_only "$m"; then
    RESPONSES_MODELS="${RESPONSES_MODELS}${m}\n"
  else
    CHAT_MODELS="${CHAT_MODELS}${m}\n"
  fi
done

# Subshell piping loses variables, so re-classify here
CHAT_MODELS=$(echo "$MODEL_IDS" | while read -r m; do
  [[ -z "$m" ]] && continue
  is_responses_only "$m" || echo "$m"
done)
RESPONSES_MODELS=$(echo "$MODEL_IDS" | while read -r m; do
  [[ -z "$m" ]] && continue
  is_responses_only "$m" && echo "$m"
done)

CHAT_COUNT=$(echo "$CHAT_MODELS" | grep -c . || true)
RESPONSES_COUNT=$(echo "$RESPONSES_MODELS" | grep -c . || true)
echo "  Chat models: ${CHAT_COUNT}, Responses-only models: ${RESPONSES_COUNT}" >&2
echo "" >&2

# ── output (stdout) ─────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "nix" ]]; then
  echo "# Chat models (/chat/completions)"
  echo "["
  echo "$CHAT_MODELS" | while read -r m; do
    [[ -z "$m" ]] && continue
    echo "  \"${m}\""
  done
  echo "]"
  echo ""
  echo "# Responses-only models (/responses) — need model_info.mode = \"responses\""
  echo "["
  echo "$RESPONSES_MODELS" | while read -r m; do
    [[ -z "$m" ]] && continue
    echo "  \"${m}\""
  done
  echo "]"
else
  echo "$MODEL_IDS"
fi
