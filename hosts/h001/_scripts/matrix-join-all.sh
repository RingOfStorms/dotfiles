#!/usr/bin/env zsh
#
# matrix-join-all.sh
#
# Joins all pending room invites for a Matrix user.
# Prompts for username and password, then logs in via the client API
# and joins every invited room.
#
# Usage:
#   ./matrix-join-all.sh [homeserver-url]
#
# Default homeserver: https://matrix.joshuabell.xyz

set -euo pipefail

HOMESERVER="${1:-https://matrix.joshuabell.xyz}"

echo "Matrix Auto-Join: Join all pending room invites"
echo "Homeserver: $HOMESERVER"
echo ""

# Prompt for credentials
printf "Username: "
read MATRIX_USER
printf "Password: "
read -s MATRIX_PASS
echo ""

# Login (use jq to build JSON safely — handles special chars in password)
echo "Logging in as $MATRIX_USER..."
LOGIN_BODY=$(jq -n --arg user "$MATRIX_USER" --arg pass "$MATRIX_PASS" \
  '{type: "m.login.password", user: $user, password: $pass}')
LOGIN_RESPONSE=$(curl -s -X POST "$HOMESERVER/_matrix/client/v3/login" \
  -H 'Content-Type: application/json' \
  -d "$LOGIN_BODY")

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$TOKEN" ]]; then
  ERROR=$(echo "$LOGIN_RESPONSE" | jq -r '.error // "Unknown error"')
  echo "Login failed: $ERROR"
  exit 1
fi

USER_ID=$(echo "$LOGIN_RESPONSE" | jq -r '.user_id')
DEVICE_ID=$(echo "$LOGIN_RESPONSE" | jq -r '.device_id')
echo "Logged in as $USER_ID (device: $DEVICE_ID)"

# Disable rate limiting via admin API if we have admin access
# (fails silently if not admin — that's fine)
ENCODED_USER=$(jq -rn --arg v "$USER_ID" '$v | @uri')
curl -s -X POST "$HOMESERVER/_synapse/admin/v1/users/$ENCODED_USER/override_ratelimit" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"messages_per_second": 0, "burst_count": 0}' > /dev/null 2>&1 || true

# Get pending invites via sync — use a tight filter to minimize response size
echo "Fetching pending invites..."
SYNC_RESPONSE=$(curl -s --max-time 120 \
  "$HOMESERVER/_matrix/client/v3/sync" \
  --data-urlencode 'filter={"room":{"join":{"types":[""]},"leave":{"types":[""]},"timeline":{"limit":0}}}' \
  -G \
  -H "Authorization: Bearer $TOKEN")

# Write room IDs to temp file to avoid subshell variable scoping issues
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

echo "$SYNC_RESPONSE" | jq -r '.rooms.invite // {} | keys[]' > "$TMPFILE" 2>/dev/null

TOTAL=$(wc -l < "$TMPFILE" | tr -d ' ')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "No pending invites found."
  exit 0
fi

echo "Found $TOTAL pending invites. Joining..."

COUNT=0
ERRORS=0

while IFS= read -r ROOM_ID; do
  COUNT=$((COUNT + 1))
  ENCODED=$(jq -rn --arg v "$ROOM_ID" '$v | @uri')
  RESULT=$(curl -s -X POST "$HOMESERVER/_matrix/client/v3/join/$ENCODED" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{}')

  if echo "$RESULT" | jq -e '.errcode' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESULT" | jq -r '.error')
    echo "  [$COUNT/$TOTAL] ERROR: $ERROR_MSG"
    ERRORS=$((ERRORS + 1))
  else
    if (( COUNT % 25 == 0 )); then
      echo "  [$COUNT/$TOTAL] Joined..."
    fi
  fi

done < "$TMPFILE"

echo "Done. Joined $((COUNT - ERRORS))/$TOTAL rooms. Errors: $ERRORS"
