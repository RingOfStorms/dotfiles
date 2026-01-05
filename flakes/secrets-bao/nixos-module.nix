{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.secretsBao;

  mkJwtMintScript = pkgs.writeShellScript "zitadel-mint-jwt" ''
    #!/usr/bin/env bash
    set -euo pipefail

    key_json="${cfg.zitadelKeyPath}"

    kid="$(${pkgs.jq}/bin/jq -r .keyId "$key_json")"
    sub="$(${pkgs.jq}/bin/jq -r .userId "$key_json")"

    pem_file="$(${pkgs.coreutils}/bin/mktemp)"
    trap '${pkgs.coreutils}/bin/rm -f "$pem_file"' EXIT

    ${pkgs.jq}/bin/jq -r .key "$key_json" >"$pem_file"
    ${pkgs.coreutils}/bin/chmod 600 "$pem_file"

    now="$(${pkgs.coreutils}/bin/date +%s)"
    exp="$(( now + ${toString cfg.jwtLifetimeSeconds} ))"
    jti="$(${pkgs.openssl}/bin/openssl rand -hex 16)"

    header="$(${pkgs.jq}/bin/jq -cn --arg kid "$kid" '{alg:"RS256",typ:"JWT",kid:$kid}')"
    payload="$(${pkgs.jq}/bin/jq -cn \
      --arg iss "$sub" \
      --arg sub "$sub" \
      --arg aud "${cfg.zitadelTokenEndpoint}" \
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

    resp=""
    if ! resp="$(${pkgs.curl}/bin/curl -sS --fail-with-body -X POST "${cfg.zitadelTokenEndpoint}" \
      -H 'content-type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
      --data-urlencode "assertion=$assertion" \
      --data-urlencode "scope=${cfg.zitadelScopes}" \
    )"; then
      echo "Zitadel token endpoint returned error; response:" >&2
      echo "$resp" >&2
      exit 1
    fi

    token="$(${pkgs.jq}/bin/jq -r '.access_token // empty' <<<"$resp" 2>/dev/null || true)"
    if [ -z "$token" ] || [ "$token" = "null" ]; then
      echo "Zitadel token mint did not return access_token; response:" >&2
      echo "$resp" >&2
      exit 1
    fi

    # Quick sanity check: JWT should have 2 dots.
    if ! ${pkgs.gnugrep}/bin/grep -q '\\.' <<<"$token"; then
      echo "Zitadel access_token does not look like a JWT; response:" >&2
      echo "$resp" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/printf '%s' "$token"
  '';

  zitadelHost =
    let
      noProto = lib.strings.removePrefix "https://" (lib.strings.removePrefix "http://" cfg.zitadelTokenEndpoint);
    in
    builtins.head (lib.strings.splitString "/" noProto);

  mkAgentConfig = pkgs.writeText "vault-agent.hcl" ''
    vault {
      address = "${cfg.openBaoAddr}"
    }

    auto_auth {
      method "jwt" {
        mount_path = "${cfg.jwtAuthMountPath}"
        config = {
          role     = "${cfg.openBaoRole}"
          jwt_file = "${cfg.zitadelJwtPath}"
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
  options.age.secrets = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Compatibility shim for modules that expect config.age.secrets.<name>.path.";
  };

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

    zitadelScopes = lib.mkOption {
      type = lib.types.str;
      default = "openid profile email";
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
                default = null;
                description = "KV v2 secret API path (ex: kv/data/machines/home_roaming/nix2github).";
              };

              field = lib.mkOption {
                type = lib.types.str;
                default = "value";
                description = "Field under .Data.data to render.";
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

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: s: {
      assertion = (s.template != null) || (s.kvPath != null);
      message = "ringofstorms.secretsBao.secrets.${name} must set either template or kvPath";
    }) cfg.secrets;
    environment.systemPackages = [
      pkgs.jq
      pkgs.curl
      pkgs.openssl
      pkgs.openbao
    ];

    systemd.tmpfiles.rules = [
      "d /run/openbao 0700 root root - -"
      "d /run/secrets 0711 root root - -"
    ];

    systemd.services = lib.mkMerge [
      {
        zitadel-mint-jwt = {
          description = "Mint Zitadel access token (JWT) for OpenBao";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "nss-lookup.target"
            "NetworkManager-wait-online.service"
            "systemd-resolved.service"
          ];
          wants = [ "network-online.target" "NetworkManager-wait-online.service" "systemd-resolved.service" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            Restart = "on-failure";
            RestartSec = "30s";

            UMask = "0077";
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

              dns_ok() {
                ${pkgs.systemd}/bin/resolvectl query ${zitadelHost} >/dev/null 2>&1 && return 0
                ${pkgs.glibc}/bin/getent hosts ${zitadelHost} >/dev/null 2>&1 && return 0
                return 1
              }

              # Wait for DNS to be usable.
              for i in {1..180}; do
                if dns_ok; then
                  break
                fi
                sleep 1
              done

              if ! dns_ok; then
                echo "DNS still not ready for ${zitadelHost}" >&2
                ${pkgs.systemd}/bin/resolvectl status >&2 || true
                exit 1
              fi

              # Mint token (retry a bit for transient network issues).
              jwt=""
              for i in {1..10}; do
                if jwt="$(${mkJwtMintScript})"; then
                  break
                fi
                sleep 2
              done

              if [ -z "$jwt" ] || [ "$jwt" = "null" ]; then
                echo "Failed to mint Zitadel access token" >&2
                exit 1
              fi

              tmp="$(${pkgs.coreutils}/bin/mktemp)"
              trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
              ${pkgs.coreutils}/bin/printf '%s' "$jwt" > "$tmp"
              ${pkgs.coreutils}/bin/mv -f "$tmp" "${cfg.zitadelJwtPath}"
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
            Restart = "on-failure";
            RestartSec = "30s";

            TimeoutStartSec = "5min";
            UMask = "0077";
            ExecStartPre = pkgs.writeShellScript "openbao-wait-jwt" ''
              #!/usr/bin/env bash
              set -euo pipefail

              for i in {1..240}; do
                if [ -s "${cfg.zitadelJwtPath}" ]; then
                  jwt="$(cat "${cfg.zitadelJwtPath}")"
                  # very cheap sanity check: JWT has at least 2 dots
                  if ${pkgs.gnugrep}/bin/grep -q '\\..*\\.' <<<"$jwt"; then
                    exit 0
                  fi
                fi

                if [ $((i % 30)) -eq 0 ]; then
                  echo "vault-agent: waiting for ${cfg.zitadelJwtPath} (t=${"$"}i s)" >&2
                fi

                sleep 1
              done

              echo "Missing or invalid Zitadel JWT at ${cfg.zitadelJwtPath}" >&2
              exit 1
            '';

            ExecStart = "${pkgs.openbao}/bin/bao agent -config=${mkAgentConfig}";
          };
        };
      }

      (lib.mapAttrs' (
        name: secret:
        lib.nameValuePair "openbao-secret-${name}" {
          description = "Wait for OpenBao secret ${name}";
          after = [ "vault-agent.service" ];
          requires = [ "vault-agent.service" ];
          startLimitIntervalSec = 300;
          startLimitBurst = 3;

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            UMask = "0077";
            ExecStart = pkgs.writeShellScript "openbao-wait-secret-${name}" ''
              #!/usr/bin/env bash
              set -euo pipefail

              p=${lib.escapeShellArg secret.path}

              for i in {1..60}; do
                if [ -s "$p" ]; then
                  exit 0
                fi
                sleep 1
              done

              echo "Secret file not rendered: $p" >&2
              exit 1
            '';
          };
        }
      ) cfg.secrets)
    ];

    age.secrets = lib.mapAttrs' (
      name: secret:
      lib.nameValuePair name {
        file = null;
        path = secret.path;
      }
    ) cfg.secrets;
  };
}

