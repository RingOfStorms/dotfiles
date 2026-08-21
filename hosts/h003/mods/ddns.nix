# Dynamic DNS — keeps home.joshuabell.xyz pointed at WAN IP via the bunny.net DNS API
# Runs as a systemd timer, checks every 5 minutes, only updates when IP changes.
#
# bunny.net API notes (https://docs.bunny.net/reference/dnszonepublic_index):
#   - Auth header is `AccessKey: <api-key>` (NOT `Authorization: Bearer`).
#   - Record `Type` is a numeric enum; A = 0.
#   - `Name` is the record label relative to the zone ("home" for home.joshuabell.xyz).
#   - Listing zones (view=Full, the default) embeds each zone's records, so a single
#     GET /dnszone gives us both the zone id and the existing record — no extra call.
#   - Add record:    PUT  /dnszone/{zoneId}/records        (returns 201)
#   - Update record: POST /dnszone/{zoneId}/records/{id}   (returns 204)
{
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.ddns;
  tokenFile = c.tokenPath;

  updateScript = pkgs.writeShellScript "ddns-update" ''
    set -euo pipefail
    TOKEN_FILE="$1"
    HOSTNAME="${c.hostname}"
    DOMAIN="${c.domain}"
    TTL=300
    API="https://api.bunny.net"

    TOKEN=$(cat "$TOKEN_FILE")

    # Thin wrapper around curl that attaches the bunny.net auth header.
    # Usage: curl_bunny METHOD PATH [json-body]
    curl_bunny() {
      local method="$1" path="$2"
      if [ "$#" -eq 3 ]; then
        ${lib.getExe pkgs.curl} -sf -X "$method" \
          -H "AccessKey: $TOKEN" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -d "$3" \
          "$API$path"
      else
        ${lib.getExe pkgs.curl} -sf -X "$method" \
          -H "AccessKey: $TOKEN" \
          -H "Accept: application/json" \
          "$API$path"
      fi
    }

    # Get current public IPv4 address (force IPv4 with -4 to avoid getting IPv6)
    CURRENT_IP=$(${lib.getExe pkgs.curl} -4 -sf https://api.ipify.org || ${lib.getExe pkgs.curl} -4 -sf https://ifconfig.me/ip)
    if [ -z "$CURRENT_IP" ]; then
      echo "ERROR: Failed to determine public IP"
      exit 1
    fi

    # Fetch all DNS zones (records are embedded in Full view, the default) and
    # pick out the zone object for our domain.
    ZONE=$(curl_bunny GET "/dnszone?page=1&perPage=1000" \
      | ${lib.getExe pkgs.jq} -c --arg d "$DOMAIN" '.Items[] | select(.Domain == $d)')

    if [ -z "$ZONE" ]; then
      echo "ERROR: Could not find DNS zone $DOMAIN in bunny.net"
      exit 1
    fi

    ZONE_ID=$(echo "$ZONE" | ${lib.getExe pkgs.jq} -r '.Id')

    # Find the existing A record (Type == 0) for our hostname within the zone.
    RECORD_ID=$(echo "$ZONE" | ${lib.getExe pkgs.jq} -r \
      --arg n "$HOSTNAME" '[.Records[] | select(.Type == 0 and .Name == $n)][0].Id // empty')
    RECORD_IP=$(echo "$ZONE" | ${lib.getExe pkgs.jq} -r \
      --arg n "$HOSTNAME" '[.Records[] | select(.Type == 0 and .Name == $n)][0].Value // empty')

    if [ -z "$RECORD_ID" ]; then
      # Record doesn't exist — create it (Type 0 = A). bunny.net uses PUT to add.
      echo "Creating A record $HOSTNAME.$DOMAIN -> $CURRENT_IP"
      BODY=$(${lib.getExe pkgs.jq} -cn \
        --arg name "$HOSTNAME" --arg value "$CURRENT_IP" --argjson ttl "$TTL" \
        '{Type: 0, Name: $name, Value: $value, Ttl: $ttl}')
      curl_bunny PUT "/dnszone/$ZONE_ID/records" "$BODY" > /dev/null
      echo "Created: $HOSTNAME.$DOMAIN -> $CURRENT_IP"
    else
      if [ "$CURRENT_IP" = "$RECORD_IP" ]; then
        echo "IP unchanged ($CURRENT_IP), skipping update"
        exit 0
      fi

      # Update the record. bunny.net uses POST to update.
      echo "Updating $HOSTNAME.$DOMAIN: $RECORD_IP -> $CURRENT_IP"
      BODY=$(${lib.getExe pkgs.jq} -cn \
        --arg name "$HOSTNAME" --arg value "$CURRENT_IP" --argjson ttl "$TTL" \
        '{Type: 0, Name: $name, Value: $value, Ttl: $ttl}')
      curl_bunny POST "/dnszone/$ZONE_ID/records/$RECORD_ID" "$BODY" > /dev/null
      echo "Updated: $HOSTNAME.$DOMAIN -> $CURRENT_IP"
    fi
  '';
in
lib.mkIf (tokenFile != null) {
  systemd.services.ddns-update = {
    description = "Dynamic DNS update for ${c.hostname}.${c.domain} via bunny.net API";
    wants = [ "network-online.target" "sec-secrets-ready.service" ];
    after = [ "network-online.target" "sec-secrets-ready.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${updateScript} ${tokenFile}";
      User = "root";
    };
  };

  systemd.timers.ddns-update = {
    description = "Run DDNS update every ${toString c.interval} minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitInactiveSec = "${toString c.interval}min";
      Persistent = true;
    };
  };
}
