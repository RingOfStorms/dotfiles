# Battery charge manager for GPD Pocket 3
#
# Since the GPD Pocket 3 doesn't support software-controlled charge thresholds,
# this module automates a smart plug (via Home Assistant REST API) to keep the
# battery between configurable bounds. A systemd timer polls the battery level
# every few minutes and toggles the plug accordingly.
#
# Requires:
#   - A Home Assistant long-lived access token stored at `tokenPath`
#   - The smart plug entity configured in Home Assistant
#   - LAN connectivity to the Home Assistant instance
{ pkgs, lib, config, constants, ... }:
let
  bm = constants.batteryManager;

  batteryScript = pkgs.writeShellScript "battery-manager" ''
    set -euo pipefail

    TOKEN_FILE="${bm.tokenPath}"
    HASS_URL="${bm.hassUrl}"
    ENTITY_ID="${bm.entityId}"
    CHARGE_ON=${toString bm.chargeOnPercent}
    CHARGE_OFF=${toString bm.chargeOffPercent}

    if [ ! -s "$TOKEN_FILE" ]; then
      echo "battery-manager: token file missing or empty: $TOKEN_FILE" >&2
      exit 1
    fi

    TOKEN="$(${pkgs.coreutils}/bin/cat "$TOKEN_FILE")"

    # Read battery percentage from sysfs (more reliable than parsing acpi output)
    BAT_CAP="/sys/class/power_supply/BAT0/capacity"
    if [ ! -f "$BAT_CAP" ]; then
      # Fallback: try BAT1
      BAT_CAP="/sys/class/power_supply/BAT1/capacity"
    fi
    if [ ! -f "$BAT_CAP" ]; then
      echo "battery-manager: no battery capacity sysfs file found" >&2
      exit 1
    fi

    LEVEL="$(${pkgs.coreutils}/bin/cat "$BAT_CAP")"
    echo "battery-manager: battery at ''${LEVEL}%  (on<=''${CHARGE_ON}%, off>=''${CHARGE_OFF}%)"

    hass_call() {
      local service="$1"
      ${pkgs.curl}/bin/curl -sS --fail-with-body \
        --connect-timeout 5 --max-time 10 \
        -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"entity_id\": \"$ENTITY_ID\"}" \
        "''${HASS_URL}/api/services/switch/''${service}"
    }

    if [ "$LEVEL" -le "$CHARGE_ON" ]; then
      echo "battery-manager: battery low ($LEVEL% <= $CHARGE_ON%) -> turning ON charger"
      hass_call "turn_on"
    elif [ "$LEVEL" -ge "$CHARGE_OFF" ]; then
      echo "battery-manager: battery full ($LEVEL% >= $CHARGE_OFF%) -> turning OFF charger"
      hass_call "turn_off"
    else
      echo "battery-manager: battery in range, no action"
    fi
  '';
in
{
  systemd.services.battery-manager = {
    description = "Toggle smart plug charger based on battery level";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = batteryScript;
      # Run as root to read sysfs and the token file
      User = "root";
      Group = "root";
      # Hardening
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  systemd.timers.battery-manager = {
    description = "Poll battery level and manage charger";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "${toString bm.checkIntervalMin}min";
      Unit = "battery-manager.service";
    };
  };
}
