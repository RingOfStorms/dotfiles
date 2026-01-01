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

    ${pkgs.curl}/bin/curl -sS -X POST "${cfg.zitadelTokenEndpoint}" \
      -H 'content-type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
      --data-urlencode "assertion=$assertion" \
      --data-urlencode "scope=${cfg.zitadelScopes}" \
      | ${pkgs.jq}/bin/jq -r .access_token
  '';

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
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";

            UMask = "0077";
            ExecStart = pkgs.writeShellScript "zitadel-mint-jwt-service" ''
              #!/usr/bin/env bash
              set -euo pipefail

              if [ ! -f "${cfg.zitadelKeyPath}" ]; then
                echo "Missing Zitadel key JSON at ${cfg.zitadelKeyPath}" >&2
                exit 1
              fi

              jwt="$(${mkJwtMintScript})"
              ${pkgs.coreutils}/bin/printf '%s' "$jwt" > "${cfg.zitadelJwtPath}"
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
          wants = [ "network-online.target" ];
          requires = [ "zitadel-mint-jwt.service" ];

          serviceConfig = {
            Type = "simple";
            User = "root";
            Group = "root";
            Restart = "on-failure";
            RestartSec = "2s";

            UMask = "0077";
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
