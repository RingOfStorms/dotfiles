# Hourly ISP speed measurement executed on the router, not on Home Assistant.
#
# `speedtest --server-id` keeps each measurement comparable. The server IDs are
# Chicago candidates selected from Ookla's nearby-server directory; after the
# first deployment, run `systemctl start h003-isp-speedtest.service` and replace
# any candidate that cannot sustain the WAN link with a tested nearby server.
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:
let
  cfg = constants.services.ispSpeedtest;
  runtimeDir = "h003-isp-speedtest";
  speedtestScript = pkgs.writeShellScript "h003-isp-speedtest" ''
    set -euo pipefail

    readonly token_file="${cfg.tokenPath}"
    readonly hass_url="${cfg.hassUrl}"
    readonly entity_prefix="${cfg.entityPrefix}"
    readonly interface="${cfg.interface}"
    readonly work_dir="$RUNTIME_DIRECTORY"

    if [ ! -s "$token_file" ]; then
      echo "h003-isp-speedtest: missing or empty Home Assistant token: $token_file" >&2
      exit 1
    fi
    token="$(${pkgs.coreutils}/bin/cat "$token_file")"

    run_files=()
    failed_servers=()

    run_server() {
      local server_id="$1"
      local label="$2"
      local output="$work_dir/server-$server_id.json"

      echo "h003-isp-speedtest: testing $label (Ookla server $server_id)"
      if ${pkgs.coreutils}/bin/timeout ${cfg.perServerTimeout} \
        ${pkgs.ookla-speedtest}/bin/speedtest \
          --accept-license --accept-gdpr --format=json \
          --interface="$interface" --server-id="$server_id" > "$output"; then
        if ${pkgs.jq}/bin/jq -e '
          .type == "result"
          and (.download.bandwidth | type == "number" and . > 0)
          and (.upload.bandwidth | type == "number" and . > 0)
          and (.ping.latency | type == "number" and . >= 0)
        ' "$output" >/dev/null; then
          run_files+=("$output")
          return
        fi
        echo "h003-isp-speedtest: invalid result from server $server_id" >&2
      else
        echo "h003-isp-speedtest: test failed or timed out for server $server_id" >&2
      fi
      failed_servers+=("$server_id")
      ${pkgs.coreutils}/bin/rm -f "$output"
    }

    ${lib.concatMapStringsSep "\n" (server: ''
      run_server "${toString server.id}" "${server.name}"
    '') cfg.servers}

    if [ "''${#run_files[@]}" -eq 0 ]; then
      echo "h003-isp-speedtest: every configured server failed; retaining Home Assistant's previous values" >&2
      exit 1
    fi

    # Ookla reports bandwidth in bytes/second; Home Assistant displays Mbit/s.
    # Pick the highest download result, while preserving concise data for all runs.
    combined="$work_dir/combined.json"
    ${pkgs.jq}/bin/jq -s --argjson failed "$(printf '%s\n' "''${failed_servers[@]:-}" | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s 'map(select(length > 0))')" '
      def summary:
        {
          server: {
            id: .server.id,
            name: .server.name,
            location: .server.location,
            country: .server.country,
            host: .server.host
          },
          timestamp: .timestamp,
          download_mbps: ((.download.bandwidth * 8 / 1000000) * 100 | round / 100),
          upload_mbps: ((.upload.bandwidth * 8 / 1000000) * 100 | round / 100),
          latency_ms: ((.ping.latency * 100 | round) / 100),
          jitter_ms: ((.ping.jitter * 100 | round) / 100),
          packet_loss_percent: (.packetLoss // null),
          result_url: (.result.url // null)
        };
      map(summary) as $runs
      | ($runs | max_by(.download_mbps)) as $best
      | {best: $best, runs: $runs, failed_server_ids: $failed}
    ' "''${run_files[@]}" > "$combined"

    post_state() {
      local suffix="$1"
      local state="$2"
      local attributes="$3"
      ${pkgs.curl}/bin/curl --fail-with-body --silent --show-error \
        --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30 \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data "$( ${pkgs.jq}/bin/jq -cn --arg state "$state" --argjson attributes "$attributes" '{state: $state, attributes: $attributes}' )" \
        "$hass_url/api/states/$entity_prefix''${suffix}"
    }

    common_attributes="$(${pkgs.jq}/bin/jq -c '{
      source: "h003",
      interface: "'"$interface"'",
      selected_server: .best.server,
      test_timestamp: .best.timestamp,
      result_url: .best.result_url,
      successful_runs: (.runs | length),
      failed_server_ids: .failed_server_ids,
      runs: .runs
    }' "$combined")"

    publish_measurement() {
      local suffix="$1"
      local value_filter="$2"
      local name="$3"
      local unit="$4"
      local device_class="$5"
      local value attributes
      value="$(${pkgs.jq}/bin/jq -r "$value_filter" "$combined")"
      attributes="$(${pkgs.jq}/bin/jq -cn \
        --arg name "$name" --arg unit "$unit" --arg device_class "$device_class" \
        --argjson common "$common_attributes" \
        '$common + {friendly_name: $name, unit_of_measurement: $unit, device_class: $device_class, state_class: "measurement"}')"
      post_state "$suffix" "$value" "$attributes" >/dev/null
    }

    publish_measurement "_download_speed" '.best.download_mbps' "ISP Download Speed" "Mbit/s" "data_rate"
    publish_measurement "_upload_speed" '.best.upload_mbps' "ISP Upload Speed" "Mbit/s" "data_rate"
    publish_measurement "_latency" '.best.latency_ms' "ISP Latency" "ms" "duration"
    publish_measurement "_jitter" '.best.jitter_ms' "ISP Jitter" "ms" "duration"

    packet_loss="$(${pkgs.jq}/bin/jq -r '.best.packet_loss_percent // empty' "$combined")"
    if [ -n "$packet_loss" ]; then
      publish_measurement "_packet_loss" '.best.packet_loss_percent' "ISP Packet Loss" "%" ""
    fi

    # A non-measurement status entity exposes test age and selected server in
    # dashboards without interfering with long-term measurement statistics.
    status_attributes="$(${pkgs.jq}/bin/jq -cn --argjson common "$common_attributes" \
      '$common + {friendly_name: "ISP Speed Test Status", icon: "mdi:speedometer"}')"
    post_state "_status" "$(${pkgs.jq}/bin/jq -r '.best.timestamp' "$combined")" "$status_attributes" >/dev/null

    echo "h003-isp-speedtest: published best download $(${pkgs.jq}/bin/jq -r '.best.download_mbps' "$combined") Mbit/s"
  '';
in
{
  systemd.services.h003-isp-speedtest = {
    description = "Measure ISP throughput from h003 and publish to Home Assistant";
    wants = [ "network-online.target" "openbao-secrets-ready.service" ];
    after = [ "network-online.target" "openbao-secrets-ready.service" ];
    path = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.ookla-speedtest ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = speedtestScript;
      User = "root";
      Group = "root";
      RuntimeDirectory = runtimeDir;
      RuntimeDirectoryMode = "0700";
      # Ookla persists its accepted-license setting under XDG_CONFIG_HOME.
      # Give it a private, persistent directory rather than letting it attempt
      # to write /root/.config, which ProtectSystem makes read-only.
      StateDirectory = runtimeDir;
      StateDirectoryMode = "0700";
      Environment = [ "XDG_CONFIG_HOME=/var/lib/${runtimeDir}" ];
      TimeoutStartSec = cfg.serviceTimeout;
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [ "/var/lib/openbao-secrets" ];
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  systemd.timers.h003-isp-speedtest = {
    description = "Run ISP speed test from h003 every hour";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = cfg.onCalendar;
      Persistent = true;
      RandomizedDelaySec = cfg.randomizedDelay;
      Unit = "h003-isp-speedtest.service";
    };
  };
}
