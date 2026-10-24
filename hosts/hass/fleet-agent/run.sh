#!/bin/sh
set -eu

HOST="$(jq -r '.host // "hass"' /data/options.json 2>/dev/null || echo "hass")"
LISTEN="$(jq -r '.listen // ":9101"' /data/options.json 2>/dev/null || echo ":9101")"
STATE_DIR="/run/fleet-agent"
mkdir -p "$STATE_DIR"

collect_smart() {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${STATE_DIR}/smart.json.tmp.$$"
  raw_entries=""
  sep=""
  for dev in /dev/nvme0 /dev/sda /dev/sdb; do
    [ -e "$dev" ] || continue
    out="$(smartctl -j -a -n standby "$dev" 2>/dev/null || true)"
    if [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      compact="$(printf '%s' "$out" | jq -c .)"
      raw_entries="${raw_entries}${sep}\"${dev}\":${compact}"
      sep=","
    fi
  done
  printf '{"updatedAt":"%s","raw":{%s}}\n' "$now" "$raw_entries" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "${STATE_DIR}/smart.json"
}

(
  while true; do
    collect_smart || true
    sleep 900
  done
) &

exec /usr/local/bin/fleet agent \
  --listen "$LISTEN" \
  --host "$HOST" \
  --state-dir "$STATE_DIR" \
  --mount "/data:data"
