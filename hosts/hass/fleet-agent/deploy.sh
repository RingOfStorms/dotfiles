#!/usr/bin/env bash
# Build and deploy the local `fleet_agent` Home Assistant add-on to `hass`.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
HASS_HOST="${HASS_HOST:-root@100.64.0.10}"

mkdir -p "${SCRIPT_DIR}/bin"

echo "==> Building static aarch64 fleet binary..."
nix develop "${REPO_ROOT}/flakes/fleet-agent" --command sh -c \
  "cd '${REPO_ROOT}/flakes/fleet-agent' && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags='-s -w' -o '${SCRIPT_DIR}/bin/fleet' ."

echo "==> Copying add-on to ${HASS_HOST}:/local_apps/fleet-agent..."
ssh "${HASS_HOST}" "mkdir -p /local_apps/fleet-agent/bin"
scp -r "${SCRIPT_DIR}/config.yaml" "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/run.sh" "${HASS_HOST}:/local_apps/fleet-agent/"
scp "${SCRIPT_DIR}/bin/fleet" "${HASS_HOST}:/local_apps/fleet-agent/bin/fleet"

echo "==> Reloading store & installing/rebuilding local_fleet_agent..."
ssh "${HASS_HOST}" '
  ha store reload
  if ha apps info local_fleet_agent | grep -q "version: null"; then
    ha apps install local_fleet_agent
    ha apps start local_fleet_agent
  else
    ha apps rebuild local_fleet_agent
  fi
'
echo "==> Done!"
