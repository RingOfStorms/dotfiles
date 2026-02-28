#!/usr/bin/env bash
#
# generate-room-map.sh
#
# Generates a JSON room map from the mautrix-gmessages bridge database.
# Maps normalized phone numbers to Matrix room IDs for DM conversations.
#
# Must run inside the matrix container as a user with psql peer auth
# to the mautrix_gmessages database.
#
# Usage (from h001):
#   sudo nixos-container run matrix -- su -s /bin/sh postgres -c \
#     'bash /tmp/generate-room-map.sh' > /tmp/room-map.json
#
# Output: JSON object mapping normalized phone -> { room_id, display_name, ghost_mxid }

set -euo pipefail

BRIDGE_DB="${BRIDGE_DB:-mautrix_gmessages}"
SERVER_NAME="${SERVER_NAME:-matrix.joshuabell.xyz}"

# Query DM portals: join portal -> ghost to get phone numbers.
# ghost.metadata->>'phone' stores the contact's phone number.
# ghost.id is used to derive the Matrix ghost MXID (@gmessages_<id>:<server>).
#
# We use psql JSON functions to produce clean output without needing jq.
psql -t -A "$BRIDGE_DB" <<SQL
SELECT json_object_agg(normalized_phone, json_build_object(
  'room_id', room_id,
  'display_name', display_name,
  'ghost_mxid', ghost_mxid
))
FROM (
  SELECT
    -- Normalize phone: if 10 digits, prepend country code 1
    CASE
      WHEN length(regexp_replace(g.metadata->>'phone', '[^0-9]', '', 'g')) = 10
      THEN '+1' || regexp_replace(g.metadata->>'phone', '[^0-9]', '', 'g')
      ELSE '+' || regexp_replace(g.metadata->>'phone', '[^0-9]', '', 'g')
    END AS normalized_phone,
    p.mxid AS room_id,
    COALESCE(NULLIF(p.name, ''), NULLIF(g.name, ''), 'Unknown') AS display_name,
    '@gmessages_' || g.id || ':${SERVER_NAME}' AS ghost_mxid
  FROM portal p
  JOIN ghost g ON g.bridge_id = p.bridge_id AND g.id = p.other_user_id
  WHERE p.mxid IS NOT NULL
    AND p.mxid != ''
    AND g.metadata->>'phone' IS NOT NULL
    AND g.metadata->>'phone' != ''
) sub;
SQL
