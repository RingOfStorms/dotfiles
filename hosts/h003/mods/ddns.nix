# Dynamic DNS — keeps home.joshuabell.xyz pointed at WAN IP via Linode API
# Runs as a systemd timer, checks every 5 minutes, only updates when IP changes.
{
  config,
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.ddns;
  baoSecrets = config.ringofstorms.secretsBao.secrets or {};
  tokenFile =
    if baoSecrets ? "linode_rw_domains_2026-03-15"
    then baoSecrets."linode_rw_domains_2026-03-15".path
    else null;

  updateScript = pkgs.writeShellScript "ddns-update" ''
    set -euo pipefail
    TOKEN_FILE="$1"
    HOSTNAME="${c.hostname}"
    DOMAIN="${c.domain}"

    TOKEN=$(cat "$TOKEN_FILE")

    # Get current public IPv4 address (force IPv4 with -4 to avoid getting IPv6)
    CURRENT_IP=$(${lib.getExe pkgs.curl} -4 -sf https://api.ipify.org || ${lib.getExe pkgs.curl} -4 -sf https://ifconfig.me/ip)
    if [ -z "$CURRENT_IP" ]; then
      echo "ERROR: Failed to determine public IP"
      exit 1
    fi

    # Get domain ID
    DOMAIN_ID=$(${lib.getExe pkgs.curl} -sf \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.linode.com/v4/domains" \
      | ${lib.getExe pkgs.jq} -r ".data[] | select(.domain == \"$DOMAIN\") | .id")

    if [ -z "$DOMAIN_ID" ]; then
      echo "ERROR: Could not find domain $DOMAIN in Linode"
      exit 1
    fi

    # Find the A record for our hostname
    RECORD=$(${lib.getExe pkgs.curl} -sf \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.linode.com/v4/domains/$DOMAIN_ID/records" \
      | ${lib.getExe pkgs.jq} -r ".data[] | select(.type == \"A\" and .name == \"$HOSTNAME\")")

    if [ -z "$RECORD" ]; then
      # Record doesn't exist — create it
      echo "Creating A record $HOSTNAME.$DOMAIN -> $CURRENT_IP"
      ${lib.getExe pkgs.curl} -sf \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"type\":\"A\",\"name\":\"$HOSTNAME\",\"target\":\"$CURRENT_IP\",\"ttl_sec\":300}" \
        "https://api.linode.com/v4/domains/$DOMAIN_ID/records" > /dev/null
      echo "Created: $HOSTNAME.$DOMAIN -> $CURRENT_IP"
    else
      RECORD_ID=$(echo "$RECORD" | ${lib.getExe pkgs.jq} -r '.id')
      RECORD_IP=$(echo "$RECORD" | ${lib.getExe pkgs.jq} -r '.target')

      if [ "$CURRENT_IP" = "$RECORD_IP" ]; then
        echo "IP unchanged ($CURRENT_IP), skipping update"
        exit 0
      fi

      # Update the record
      echo "Updating $HOSTNAME.$DOMAIN: $RECORD_IP -> $CURRENT_IP"
      ${lib.getExe pkgs.curl} -sf \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -X PUT \
        -d "{\"target\":\"$CURRENT_IP\",\"ttl_sec\":300}" \
        "https://api.linode.com/v4/domains/$DOMAIN_ID/records/$RECORD_ID" > /dev/null
      echo "Updated: $HOSTNAME.$DOMAIN -> $CURRENT_IP"
    fi
  '';
in
lib.mkIf (tokenFile != null) {
  systemd.services.ddns-update = {
    description = "Dynamic DNS update for ${c.hostname}.${c.domain} via Linode API";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "vault-agent.service" ];
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
