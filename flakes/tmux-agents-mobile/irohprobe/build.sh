#!/usr/bin/env bash
# Build the probe: native server + browser wasm client into ./out.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o out/client.wasm ./cmd/probe-client
cp -f --no-preserve=mode "$(find "$(go env GOROOT)" -name wasm_exec.js -path "*/wasm/*" | head -n1)" out/
cp web/index.html out/
CGO_ENABLED=0 go build -trimpath -o out/probe-server ./cmd/probe-server
ls -lh out
