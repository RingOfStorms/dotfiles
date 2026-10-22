#!/usr/bin/env bash
# Regression test for containers/cli/nginx/oauth2-cookie-strip.conf.
# Runs a real nginx (no root) on a high port; the front server includes the
# snippet and proxies to a back server that echoes the Cookie it received.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
snippet="$here/../../flakes/fleet-agent/internal/containers/nginx/oauth2-cookie-strip.conf"
prefix=$(mktemp -d)
trap 'kill "$(cat "$prefix/nginx.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$prefix"' EXIT
front=${FRONT_PORT:-18471}
back=${BACK_PORT:-18472}
mkdir -p "$prefix/logs"
cat >"$prefix/nginx.conf" <<CONF
daemon on;
pid $prefix/nginx.pid;
error_log $prefix/logs/error.log;
events {}
http {
  access_log off;
  client_body_temp_path $prefix/tmp_body;
  proxy_temp_path $prefix/tmp_proxy;
  fastcgi_temp_path $prefix/tmp_fcgi;
  uwsgi_temp_path $prefix/tmp_uwsgi;
  scgi_temp_path $prefix/tmp_scgi;
  server {
    listen 127.0.0.1:$front;
    include $snippet;
    location / {
      proxy_pass http://127.0.0.1:$back;
      proxy_set_header Cookie \$fleet_cookie;
    }
  }
  server {
    listen 127.0.0.1:$back;
    location / { return 200 "[\$http_cookie]"; }
  }
}
CONF
nginx -e "$prefix/logs/error.log" -p "$prefix" -c "$prefix/nginx.conf" -t -q
nginx -e "$prefix/logs/error.log" -p "$prefix" -c "$prefix/nginx.conf"
sleep 0.3

fail=0
get() { if [ -n "$1" ]; then curl -fsS -H "Cookie: $1" "http://127.0.0.1:$front/"; else curl -fsS "http://127.0.0.1:$front/"; fi; }
check() { # name cookie expected
  local out; out=$(get "$2")
  if [ "$out" = "$3" ] && [[ $out != *_oauth2_proxy* && $out != *secret* ]]; then
    echo "PASS $1: $out"
  else
    echo "FAIL $1: got $out want $3"; fail=1
  fi
}
decoys() { local s="" i; for ((i = 1; i <= $1; i++)); do s+="_oauth2_proxy_x$i=d$i; "; done; printf %s "$s"; }

check middle 'a=1; _oauth2_proxy=s; b=2' '[a=1; b=2]'
check two '_oauth2_proxy=secret; _oauth2_proxy_csrf=secret2' '[]'
check four-decoys "$(decoys 4)_oauth2_proxy=secret" '[]'
check ten-decoys "a=1; $(decoys 10)_oauth2_proxy=secret; b=2" '[]'
check none '' '[]'
check plain 'a=1; b=2' '[a=1; b=2]'
check first '_oauth2_proxy=secret; a=1' '[a=1]'
exit $fail
