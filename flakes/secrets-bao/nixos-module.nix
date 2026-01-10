{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.secretsBao;

  mkJwtMintScript = pkgs.writeShellScript "zitadel-mint-jwt-impl" ''
    #!/usr/bin/env bash
    set -euo pipefail

    key_json="${cfg.zitadelKeyPath}"
    token_endpoint="${cfg.zitadelTokenEndpoint}"
    issuer="${cfg.zitadelIssuer}"

    debug_enabled="${if cfg.debugMint then "true" else "false"}"
    request_roles="${if cfg.requestProjectRoles then "true" else "false"}"

    debug() {
      if [ "$debug_enabled" = "true" ] || [ -n "${"DEBUG:-"}" ]; then
        echo "[zitadel-mint] $*" >&2
      fi
    }

    if [ ! -f "$key_json" ]; then
      echo "KEY_JSON not found: $key_json" >&2
      exit 1
    fi

    kid="$(${pkgs.jq}/bin/jq -r .keyId "$key_json")"
    sub="$(${pkgs.jq}/bin/jq -r .userId "$key_json")"

    pem_file="$(${pkgs.coreutils}/bin/mktemp)"
    trap '${pkgs.coreutils}/bin/rm -f "$pem_file"' EXIT

    ${pkgs.jq}/bin/jq -r .key "$key_json" >"$pem_file"
    ${pkgs.coreutils}/bin/chmod 600 "$pem_file"

    now="$(${pkgs.coreutils}/bin/date +%s)"
    exp="$(( now + ${toString cfg.jwtLifetimeSeconds} ))"
    jti="$(${pkgs.openssl}/bin/openssl rand -hex 16)"

    debug "kid=$kid sub=$sub iss=$sub aud=$issuer iat=$now exp=$exp jti=$jti"

    header="$(${pkgs.jq}/bin/jq -cn --arg kid "$kid" '{alg:"RS256",typ:"JWT",kid:$kid}')"
    payload="$(${pkgs.jq}/bin/jq -cn \
      --arg iss "$sub" \
      --arg sub "$sub" \
      --arg aud "$issuer" \
      --arg jti "$jti" \
      --argjson iat "$now" \
      --argjson exp "$exp" \
      '{iss:$iss,sub:$sub,aud:$aud,iat:$iat,exp:$exp,jti:$jti}'
    )"

    b64url() {
      ${pkgs.openssl}/bin/openssl base64 -A | ${pkgs.gnused}/bin/sed -e 's/+/-/g' -e 's/\//_/g' -e 's/=*$//'
    }

    h64="$(${pkgs.coreutils}/bin/printf '%s' "$header" | b64url)"
    p64="$(${pkgs.coreutils}/bin/printf '%s' "$payload" | b64url)"
    sig="$(${pkgs.coreutils}/bin/printf '%s' "$h64.$p64" | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign "$pem_file" | b64url)"
    assertion="$h64.$p64.$sig"

    scope="${cfg.zitadelScope}"
    roles_scope="urn:zitadel:iam:org:projects:roles"

    if [ -z "$scope" ]; then
      scope="openid urn:zitadel:iam:org:project:id:${cfg.zitadelProjectId}:aud"
    fi

    # Always request project roles unless explicitly disabled.
    if [ "$request_roles" = "true" ]; then
      if [[ " $scope " != *" $roles_scope "* ]]; then
        scope="$scope $roles_scope"
      fi
    fi

    debug "token_endpoint=$token_endpoint"
    debug "scope=$scope"

    response_with_status="$(${pkgs.curl}/bin/curl -sS --fail-with-body \
      --connect-timeout 3 --max-time 15 \
      --retry 8 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
      -X POST "$token_endpoint" \
      -H 'content-type: application/x-www-form-urlencoded' \
      -w $'\n%{http_code}' \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
      --data-urlencode "assertion=$assertion" \
      --data-urlencode "scope=$scope" \
    )"

    http_status="${"$"}{response_with_status##*$'\n'}"
    response_body="${"$"}{response_with_status%$'\n'*}"

    if [ "$http_status" != "200" ]; then
      echo "token endpoint failed (HTTP $http_status):" >&2
      echo "$response_body" >&2
      exit 1
    fi

    if [ "${toString cfg.debugMint}" = "true" ]; then
      debug "token endpoint response: $response_body"
    fi

    access_token="$(${pkgs.coreutils}/bin/printf '%s' "$response_body" | ${pkgs.jq}/bin/jq -r '.access_token // empty')"
    id_token="$(${pkgs.coreutils}/bin/printf '%s' "$response_body" | ${pkgs.jq}/bin/jq -r '.id_token // empty')"

    decode_payload() {
      local token="$1"
      local payload_b64 payload_json

      payload_b64="$(${pkgs.coreutils}/bin/printf '%s' "$token" | ${pkgs.coreutils}/bin/cut -d. -f2)"
      payload_json="$(${pkgs.coreutils}/bin/printf '%s' "$payload_b64" | ${pkgs.jq}/bin/jq -Rr '
        gsub("-"; "+")
        | gsub("_"; "/")
        | . + ("=" * ((4 - (length % 4)) % 4))
        | @base64d
      ' 2>/dev/null || true)"

      ${pkgs.coreutils}/bin/printf '%s' "$payload_json"
    }

    has_roles_claim() {
      local token="$1"
      local payload
      payload="$(decode_payload "$token")"
      if [ -z "$payload" ]; then
        return 1
      fi
      ${pkgs.jq}/bin/jq -e 'has("urn:zitadel:iam:org:projects:roles") or has("urn:zitadel:iam:org:project:roles") or has("flatRolesClaim")' <<<"$payload" >/dev/null 2>&1
    }

    token=""
    token_source=""

    if [[ "$access_token" == *.*.* ]] && has_roles_claim "$access_token"; then
      token="$access_token"
      token_source="access_token(with_roles)"
    elif [[ "$id_token" == *.*.* ]] && has_roles_claim "$id_token"; then
      token="$id_token"
      token_source="id_token(with_roles)"
    elif [[ "$access_token" == *.*.* ]]; then
      token="$access_token"
      token_source="access_token"
    elif [[ "$id_token" == *.*.* ]]; then
      token="$id_token"
      token_source="id_token"
    else
      echo "no JWT found in response (.access_token/.id_token)." >&2
      echo "Response was:" >&2
      echo "$response_body" >&2
      exit 1
    fi

    debug "selected=$token_source"

    if [ "${toString cfg.debugMint}" = "true" ] || [ -n "${"DEBUG:-"}" ]; then
      payload="$(decode_payload "$token")"
      if [ -n "$payload" ]; then
        debug "jwt.payload=$(echo "$payload" | ${pkgs.jq}/bin/jq -c '.')"
      else
        debug "jwt.payload=<decode_failed>"
      fi
    fi

    ${pkgs.coreutils}/bin/printf '%s' "$token"
  '';

  zitadelMintJwt = pkgs.writeShellScriptBin "zitadel-mint-jwt" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Keep behavior consistent between CLI + systemd.
    export KEY_JSON="${cfg.zitadelKeyPath}"
    export TOKEN_ENDPOINT="${cfg.zitadelTokenEndpoint}"
    export ZITADEL_ISSUER="${cfg.zitadelIssuer}"
    export ZITADEL_PROJECT_ID="${cfg.zitadelProjectId}"
    export ZITADEL_SCOPE="${cfg.zitadelScope}"
    export ZITADEL_REQUEST_PROJECT_ROLES="${if cfg.requestProjectRoles then "true" else "false"}"

    if [ "${toString cfg.debugMint}" = "true" ]; then
      export DEBUG=1
    fi

    exec ${mkJwtMintScript}
  '';

  zitadelHost =
    let
      noProto = lib.strings.removePrefix "https://" (
        lib.strings.removePrefix "http://" cfg.zitadelTokenEndpoint
      );
    in
    builtins.head (lib.strings.splitString "/" noProto);

  sec = pkgs.writeShellScriptBin "sec" ''
    #!/usr/bin/env bash
    set -euo pipefail

    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      exec ${pkgs.sudo}/bin/sudo "$0" "$@"
    fi

    vault_addr=${lib.escapeShellArg cfg.openBaoAddr}
    jwt_mount_path=${lib.escapeShellArg cfg.jwtAuthMountPath}
    role=${lib.escapeShellArg cfg.openBaoRole}
    jwt_path=${lib.escapeShellArg cfg.zitadelJwtPath}
    token_path=${lib.escapeShellArg cfg.vaultAgentTokenPath}

    usage() {
      echo "usage: sec <kv-path> [field]" >&2
      echo "  examples:" >&2
      echo "    sec machines/home_roaming/test value" >&2
      echo "    sec kv/data/machines/home_roaming/test value" >&2
    }

    die() {
      echo "sec: $*" >&2
      exit 1
    }

    kv_path="''${1-}"
    field="''${2:-value}"

    if [ -z "$kv_path" ] || [ "$kv_path" = "-h" ] || [ "$kv_path" = "--help" ]; then
      usage
      exit 2
    fi

    export VAULT_ADDR="$vault_addr"

    token=""

    if [ -r "$token_path" ] && [ -s "$token_path" ]; then
      token="$(cat "$token_path")"
    else
      if [ ! -r "$jwt_path" ] || [ ! -s "$jwt_path" ]; then
        die "Missing JWT at $jwt_path (try: systemctl start zitadel-mint-jwt)"
      fi

      token="$(${pkgs.openbao}/bin/bao write -field=token "$jwt_mount_path/login" role="$role" jwt="$(cat "$jwt_path")")"
    fi

    if [ -z "$token" ] || [ "$token" = "null" ]; then
      die "Failed to get OpenBao token"
    fi

    export VAULT_TOKEN="$token"

    # Accept either KV v2 logical paths (machines/foo/bar) or raw API paths (kv/data/machines/foo/bar).
    if [[ "$kv_path" == kv/data/* ]]; then
      json="$(${pkgs.openbao}/bin/bao read -format=json "$kv_path")"
    else
      json="$(${pkgs.openbao}/bin/bao kv get -format=json -mount=kv "$kv_path")"
    fi

    value="$(${pkgs.jq}/bin/jq -er --arg field "$field" '.data.data[$field]' <<<"$json" 2>/dev/null || true)"

    if [ -z "$value" ] || [ "$value" = "null" ]; then
      die "Field not found: $field"
    fi

    printf '%s\n' "$value"
  '';

  mkAgentConfig = pkgs.writeText "vault-agent.hcl" ''
    vault {
      address = "${cfg.openBaoAddr}"
    }

    auto_auth {
      method "jwt" {
        mount_path = "${cfg.jwtAuthMountPath}"
        config = {
          role = "${cfg.openBaoRole}"
          path = "${cfg.zitadelJwtPath}"
          remove_jwt_after_reading = false
        }
      }

      sink "file" {
        config = {
          path = "${cfg.vaultAgentTokenPath}"
          mode = 0400
        }
      }
    }

    ${lib.concatStringsSep "\n\n" (
      lib.mapAttrsToList (
        name: secret:
        let
          renderedTemplate =
            if secret.template != null then
              secret.template
            else
              ''{{- with secret "${secret.kvPath}" -}}{{- .Data.data.${secret.field} -}}{{- end -}}'';
        in
        ''
                    template {
                      destination = "${secret.path}"
                      perms       = "${secret.mode}"
                      contents    = <<EOH
          ${renderedTemplate}
          EOH
                      command     = "${pkgs.runtimeShell} -c '${pkgs.coreutils}/bin/chown ${lib.escapeShellArg secret.owner}:${lib.escapeShellArg secret.group} ${lib.escapeShellArg secret.path} && ${pkgs.coreutils}/bin/chmod ${lib.escapeShellArg secret.mode} ${lib.escapeShellArg secret.path}'"
                    }
        ''
      ) cfg.secrets
    )}
  '';

in
{
  options.ringofstorms.secretsBao = {
    enable = lib.mkEnableOption "Fetch runtime secrets via OpenBao";

    zitadelKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/machine-key.json";
      description = "Path to Zitadel service account key JSON (persistent, root-only).";
    };

    zitadelTokenEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://sso.joshuabell.xyz/oauth/v2/token";
    };

    # If empty, the mint script will build a scope.
    zitadelScope = lib.mkOption {
      type = lib.types.str;
      default = "";
    };

    zitadelIssuer = lib.mkOption {
      type = lib.types.str;
      default = "https://sso.joshuabell.xyz";
      description = "Issuer / audience for the JWT bearer assertion (base URL, not /oauth/*).";
    };

    zitadelProjectId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Zitadel Project -> Resource ID (used to request aud scope).";
    };

    requestProjectRoles = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Request urn:zitadel:iam:org:projects:roles in scope.";
    };

    debugMint = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose mint logs (stderr).";
    };

    jwtLifetimeSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Lifetime of signed assertion JWT sent to Zitadel token endpoint.";
    };

    zitadelJwtPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/openbao/zitadel.jwt";
    };

    openBaoAddr = lib.mkOption {
      type = lib.types.str;
      default = "https://sec.joshuabell.xyz";
    };

    jwtAuthMountPath = lib.mkOption {
      type = lib.types.str;
      default = "auth/zitadel-jwt";
    };

    openBaoRole = lib.mkOption {
      type = lib.types.str;
      default = "machines";
    };

    vaultAgentTokenPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/openbao/vault-agent.token";
    };

    vaultAgentLogLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Log level for `bao agent` (debug is very noisy).";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                default = "/run/secrets/${name}";
              };

              owner = lib.mkOption {
                type = lib.types.str;
                default = "root";
              };

              group = lib.mkOption {
                type = lib.types.str;
                default = "root";
              };

              mode = lib.mkOption {
                type = lib.types.str;
                default = "0400";
              };

              kvPath = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "kv/data/machines/home_roaming/${name}";
                description = "KV v2 secret API path (ex: kv/data/machines/home_roaming/nix2github).";
              };

              field = lib.mkOption {
                type = lib.types.str;
                default = "value";
                description = "Field under .Data.data to render.";
              };

              softDepend = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Systemd service names to try-restart when this secret changes (does not block startup).";
              };

              hardDepend = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Systemd service names that should only start when this secret exists; started when the secret changes.";
              };

              configChanges = lib.mkOption {
                type = lib.types.attrs;
                default = { };
                description = "Extra NixOS config applied when enabled; supports '$SECRET_PATH' string substitution.";
              };

              hmChanges = lib.mkOption {
                type = lib.types.attrs;
                default = { };
                description = "Extra Home Manager config applied when enabled; supports '$SECRET_PATH' string substitution.";
              };

              template = lib.mkOption {
                type = lib.types.nullOr lib.types.lines;
                default = null;
                description = "Optional raw template contents (overrides kvPath/field).";
              };
            };
          }
        )
      );
      default = { };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = lib.mapAttrsToList (name: s: {
          assertion = (s.template != null) || (s.kvPath != null);
          message = "ringofstorms.secretsBao.secrets.${name} must set either template or kvPath";
        }) cfg.secrets;

        environment.systemPackages = [
          pkgs.jq
          pkgs.curl
          pkgs.openssl
          pkgs.openbao
          zitadelMintJwt
          sec
        ];

         systemd.tmpfiles.rules = [
           "d /run/openbao 0700 root root - -"
           "f /run/openbao/zitadel.jwt 0400 root root - -"
           "d /run/secrets 0711 root root - -"
         ];

         systemd.paths =
           (lib.mapAttrs' (
             name: secret:
             lib.nameValuePair "openbao-secret-${name}" {
               description = "Path unit for OpenBao secret ${name}";
               wantedBy = [ "multi-user.target" ];

               pathConfig = {
                 PathChanged = secret.path;
                 Unit = "openbao-secret-changed-${name}.service";
                 TriggerLimitIntervalSec = 30;
                 TriggerLimitBurst = 3;
               };
             }
           ) cfg.secrets)
           // {
             openbao-zitadel-jwt = {
               description = "React to Zitadel JWT changes (restart vault-agent)";
               wantedBy = [ "multi-user.target" ];

               pathConfig = {
                 PathChanged = cfg.zitadelJwtPath;
                 Unit = "openbao-jwt-changed.service";
                 TriggerLimitIntervalSec = 30;
                 TriggerLimitBurst = 3;
               };
             };

             openbao-secrets-ready = {
               description = "Re-check OpenBao secrets readiness";
               wantedBy = [ "multi-user.target" ];

               pathConfig = {
                 PathChanged = "/run/secrets";
                 Unit = "openbao-secrets-ready.service";
                 TriggerLimitIntervalSec = 30;
                 TriggerLimitBurst = 3;
               };
             };
           };

          systemd.timers.zitadel-mint-jwt = {
            description = "Refresh Zitadel JWT for OpenBao";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "30s";
              OnUnitInactiveSec = "10min";
              Unit = "zitadel-mint-jwt.service";
            };
          };

         systemd.services = lib.mkMerge [
             (
               lib.mkMerge (
                 lib.concatLists (
                   lib.mapAttrsToList (
                     secretName: secret:
                     map (
                       svc: {
                         ${svc} = {
                           unitConfig.ConditionPathExists = secret.path;
                           wants = lib.mkAfter [ "openbao-secret-${secretName}.path" ];
                           after = lib.mkAfter [ "openbao-secret-${secretName}.path" ];
                           partOf = lib.mkAfter [ "openbao-secret-changed-${secretName}.service" ];
                         };
                       }
                     ) secret.hardDepend
                   ) cfg.secrets
                 )
               )
             )
             {
               openbao-secrets-ready = {
                 description = "OpenBao: all configured secrets present";
                 wantedBy = [ "multi-user.target" ];
                 wants = [ "vault-agent.service" ];
                 after = [ "vault-agent.service" ];

                 serviceConfig = {
                   Type = "oneshot";
                   RemainAfterExit = true;
                   User = "root";
                   Group = "root";
                   UMask = "0077";
                   ExecStart = pkgs.writeShellScript "openbao-secrets-ready" ''
                     #!/usr/bin/env bash
                     set -euo pipefail

                     ${lib.concatStringsSep "\n" (
                       lib.mapAttrsToList (name: secret: ''
                         if [ ! -s ${lib.escapeShellArg secret.path} ]; then
                           echo "Missing secret: ${secret.path}" >&2
                           exit 1
                         fi
                       '') cfg.secrets
                     )}

                     echo "All configured OpenBao secrets present." >&2
                   '';
                 };
               };

               openbao-jwt-changed = {
                 description = "Restart vault-agent after Zitadel JWT refresh";
                 wants = [ "vault-agent.service" ];
                 after = [ "vault-agent.service" ];

                 serviceConfig = {
                   Type = "oneshot";
                   User = "root";
                   Group = "root";
                   UMask = "0077";
                   ExecStart = pkgs.writeShellScript "openbao-jwt-changed" ''
                     #!/usr/bin/env bash
                     set -euo pipefail
                     systemctl try-restart --no-block vault-agent.service || true
                   '';
                 };
               };

               zitadel-mint-jwt = {
                 description = "Mint Zitadel access token (JWT) for OpenBao";

                 after = [
                   "network-online.target"
                   "nss-lookup.target"
                   "NetworkManager-wait-online.service"
                   "systemd-resolved.service"
                   "time-sync.target"
                 ];
                 wants = [
                   "network-online.target"
                   "NetworkManager-wait-online.service"
                   "systemd-resolved.service"
                 ];

               serviceConfig = {
                 Type = "oneshot";
                 User = "root";
                 Group = "root";
                 Restart = "on-failure";
                 RestartSec = "30s";
                 TimeoutStartSec = "2min";
                 UMask = "0077";
                 StartLimitIntervalSec = 0;


                   ExecStart = pkgs.writeShellScript "zitadel-mint-jwt-service" ''

                  #!/usr/bin/env bash
                  set -euo pipefail

                  if [ ! -d "/run/openbao" ]; then
                    ${pkgs.coreutils}/bin/mkdir -p /run/openbao
                    ${pkgs.coreutils}/bin/chmod 0700 /run/openbao
                  fi

                  if [ ! -f "${cfg.zitadelKeyPath}" ]; then
                    echo "Missing Zitadel key JSON at ${cfg.zitadelKeyPath}" >&2
                    exit 1
                  fi

                  echo "zitadel-mint-jwt: starting (host=${zitadelHost})" >&2

                  # Best-effort: wait briefly for time sync + DNS.
                  for i in {1..10}; do
                    if ${pkgs.systemd}/bin/timedatectl show -p NTPSynchronized --value 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qi true; then
                      break
                    fi
                    sleep 1
                  done

                  for i in {1..10}; do
                    if ${pkgs.systemd}/bin/resolvectl query ${zitadelHost} >/dev/null 2>&1; then
                      break
                    fi
                    sleep 1
                  done

                  jwt_is_valid() {
                    local token="$1"
                    local payload_b64 payload_json exp now

                    payload_b64="$(${pkgs.coreutils}/bin/printf '%s' "$token" | ${pkgs.coreutils}/bin/cut -d. -f2)"
                    payload_b64="$(${pkgs.coreutils}/bin/printf '%s' "$payload_b64" | ${pkgs.gnused}/bin/sed -e 's/-/+/g' -e 's/_/\//g')"

                    case $((${pkgs.coreutils}/bin/printf '%s' "$payload_b64" | ${pkgs.coreutils}/bin/wc -c)) in
                      *1) payload_b64="$payload_b64=" ;;
                      *2) payload_b64="$payload_b64==" ;;
                      *3) : ;;
                      *0) : ;;
                    esac

                    payload_json="$(${pkgs.coreutils}/bin/printf '%s' "$payload_b64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null || true)"
                    exp="$(${pkgs.jq}/bin/jq -r '.exp // empty' <<<"$payload_json" 2>/dev/null || true)"
                    if [ -z "$exp" ]; then
                      return 1
                    fi

                    now="$(${pkgs.coreutils}/bin/date +%s)"
                    if [ "$exp" -gt $(( now + 60 )) ]; then
                      return 0
                    fi
                    return 1
                  }

                  if [ -s "${cfg.zitadelJwtPath}" ] && jwt_is_valid "$(cat "${cfg.zitadelJwtPath}")"; then
                    echo "zitadel-mint-jwt: existing token still valid; skipping" >&2
                    exit 0
                  fi

                  jwt="$(${zitadelMintJwt}/bin/zitadel-mint-jwt)"

                  if [ -z "$jwt" ] || [ "$jwt" = "null" ]; then
                    echo "Failed to mint Zitadel access token" >&2
                    exit 1
                  fi

                  tmp="$(${pkgs.coreutils}/bin/mktemp)"
                  trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
                  ${pkgs.coreutils}/bin/printf '%s' "$jwt" > "$tmp"

                  if [ -s "${cfg.zitadelJwtPath}" ] && ${pkgs.coreutils}/bin/cmp -s "$tmp" "${cfg.zitadelJwtPath}"; then
                    echo "zitadel-mint-jwt: token unchanged; skipping" >&2
                    exit 0
                  fi

                  # Update the token file (the agent watches it).
                  ${pkgs.coreutils}/bin/cat "$tmp" > "${cfg.zitadelJwtPath}"
                  ${pkgs.coreutils}/bin/chmod 0400 "${cfg.zitadelJwtPath}" || true
                '';
              };
            };

              vault-agent = {
                description = "OpenBao agent for rendering secrets";
                wantedBy = [ "multi-user.target" ];

                after = [
                  "network-online.target"
                  "zitadel-mint-jwt.service"
                ];
                wants = [
                  "network-online.target"
                  "zitadel-mint-jwt.service"
                ];

                serviceConfig = {
                  Type = "simple";
                  User = "root";
                  Group = "root";
                  Restart = "always";
                  RestartSec = "10s";
                  TimeoutStartSec = "30s";
                  UMask = "0077";
                  StartLimitIntervalSec = 0;
                  ExecStart = "${pkgs.openbao}/bin/bao agent -log-level=${lib.escapeShellArg cfg.vaultAgentLogLevel} -config=${mkAgentConfig}";
                };

             };

          }

          (lib.mapAttrs' (
            name: secret:
            lib.nameValuePair "openbao-secret-changed-${name}" {
              description = "React to OpenBao secret ${name} changes";
              wants = [ "vault-agent.service" ];
              after = [ "vault-agent.service" ];
              startLimitIntervalSec = 300;
              startLimitBurst = 6;

              serviceConfig = {
                Type = "oneshot";
                User = "root";
                Group = "root";
                UMask = "0077";
                ExecStart = pkgs.writeShellScript "openbao-secret-changed-${name}" ''
                  #!/usr/bin/env bash
                  set -euo pipefail

                  p=${lib.escapeShellArg secret.path}

                  if [ ! -s "$p" ]; then
                    echo "Secret not present (skipping): $p" >&2
                    exit 0
                  fi

                  ${lib.concatStringsSep "\n" (
                    map (svc: ''
                      echo "Trying restart of ${svc} due to secret ${name}" >&2
                      systemctl try-restart --no-block ${lib.escapeShellArg (svc + ".service")} || true
                    '') secret.softDepend
                  )}

                  ${lib.concatStringsSep "\n" (
                    map (svc: ''
                      echo "Starting ${svc} due to secret ${name}" >&2
                      systemctl start --no-block ${lib.escapeShellArg (svc + ".service")} || true
                    '') secret.hardDepend
                  )}

                  # Mark overall readiness when all secrets exist.
                  systemctl try-restart --no-block openbao-secrets-ready.service || true
                '';
              };
            }
          ) cfg.secrets)

        ];
      }
    ]
  );
}
