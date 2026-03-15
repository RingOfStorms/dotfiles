{
  pkgs,
  lib,
  constants,
  ...
}:
let
  c = constants.services.openbao;

  # ── Reserved / built-in names that must never be deleted ──────────────
  reservedPolicies = [ "default" "root" ];
  reservedAuthMethods = [ "token/" ]; # always exists
  builtinSecretsEngines = [ "cubbyhole/" "identity/" "sys/" ]; # always exist

  # ── Secrets engines to ensure exist ──────────────────────────────────
  secretsEngines = {
    "kv/" = {
      type = "kv";
      options = { version = "2"; };
    };
  };

  # ── Auth methods to ensure exist ─────────────────────────────────────
  authMethods = {
    "userpass/" = {
      type = "userpass";
    };
    "zitadel-jwt/" = {
      type = "jwt";
      config = {
        oidc_discovery_url = "https://sso.joshuabell.xyz";
        bound_issuer = "https://sso.joshuabell.xyz";
      };
    };
  };

  # ── Roles under auth methods ─────────────────────────────────────────
  # Key format: "auth/<mount>/role/<rolename>"
  authRoles = {
    "auth/zitadel-jwt/role/machines" = {
      role_type = "jwt";
      user_claim = "sub";
      groups_claim = "flatRolesClaim";
      bound_audiences = [ "344379162166820867" ];
      token_policies = [
        "machine-base"
        "machines-high-trust"
      ];
      token_ttl = "1h";
    };
    "auth/zitadel-jwt/role/machines-lowtrust" = {
      role_type = "jwt";
      user_claim = "sub";
      groups_claim = "flatRolesClaim";
      bound_audiences = [ "344379162166820867" ];
      token_policies = [
        "machine-base"
        "machines-low-trust"
      ];
      token_ttl = "1h";
    };
  };

  # ── Userpass users (config only, password set manually) ──────────────
  # We only reconcile token_policies here. Password is stateful.
  userpassUsers = {
    "auth/userpass/users/josh" = {
      token_policies = [ "admin" ];
    };
  };

  # ── Policies ─────────────────────────────────────────────────────────
  policies = {
    admin = ''
      path "*" {
        capabilities = ["create", "read", "update", "delete", "list", "sudo"]
      }
    '';

    machine-base = ''
      # Baseline for all machines
      path "sys/capabilities-self" { capabilities = ["update"] }
    '';

    machines-high-trust = ''
      path "kv/data/machines/high-trust/*" {
        capabilities = ["read"]
      }
      path "kv/metadata/machines/high-trust/*" {
        capabilities = ["list", "read"]
      }
    '';

    machines-low-trust = ''
      path "kv/data/machines/low-trust/*" {
        capabilities = ["read"]
      }
      path "kv/metadata/machines/low-trust/*" {
        capabilities = ["list", "read"]
      }
    '';

    # Legacy policies from early exploration — kept to preserve state.
    # Remove entries here to have the reconciler clean them up.
    devices = ''
      path "secret/devices/*" {
        capabilities = ["create", "read", "update", "delete", "list"]
      }

      path "secret/shared/*" {
        capabilities = ["read", "list"]
      }
    '';

    device-home = ''
      path "kv/data/hosts/home/*" { capabilities = ["read","list"] }
    '';

    device-roaming = ''
      path "kv/data/hosts/roaming/*" { capabilities = ["read","list"] }
    '';

    device-work = ''
      path "kv/data/hosts/work/*" { capabilities = ["read","list"] }
    '';

    users = ''
      path "secret/users/*" {
        capabilities = ["create", "read", "update", "delete", "list"]
      }

      path "secret/shared/*" {
        capabilities = ["read", "list"]
      }
    '';
  };

  # ── KV secrets registry ───────────────────────────────────────────────
  # Declarative list of every KV secret that should exist.
  # The reconciler creates missing entries with a stub value so vault-agent
  # templates don't error on a missing path. Existing values are NEVER
  # overwritten — only missing keys get the stub.
  #
  # Format: "kv-mount-relative/path" = { fields = { fieldName = "stub"; ... }; }
  # The default field is "value" with stub "TODO:replace_me".
  kvSecrets = {
    # ── high-trust (all trusted machines: h001, juni, lio, etc.) ───────
    "machines/high-trust/headscale_auth"    = {};
    "machines/high-trust/atuin-key-josh"    = { fields = { user = "TODO:replace_me"; password = "TODO:replace_me"; value = "TODO:replace_me"; }; };
    "machines/high-trust/nix2github"        = {};
    "machines/high-trust/nix2bitbucket"     = {};
    "machines/high-trust/nix2gitforgejo"    = {};
    "machines/high-trust/nix2lio"           = {};
    "machines/high-trust/nix2oren"          = {};
    "machines/high-trust/nix2gpdPocket3"    = {};
    "machines/high-trust/nix2t"             = {};
    "machines/high-trust/nix2h001"          = {};
    "machines/high-trust/nix2h002"          = {};
    "machines/high-trust/nix2h003"          = {};
    "machines/high-trust/nix2linode"        = {};
    "machines/high-trust/nix2oracle"        = {};
    "machines/high-trust/nix2nix"           = {};
    "machines/high-trust/github_read_token" = {};
    "machines/high-trust/linode_rw_domains" = {};
    "machines/high-trust/us_chi_wg"         = {};
    "machines/high-trust/openrouter"        = { fields = { api-key = "TODO:replace_me"; }; };
    "machines/high-trust/anthropic-claude"  = { fields = { api-key = "TODO:replace_me"; }; };

    # ── low-trust (gp3 and future untrusted devices) ──────────────────
    # Add secrets here as needed for low-trust devices.
  };

  # Normalize: fill in default fields where not specified
  kvSecretsNormalized = lib.mapAttrs (
    _path: spec:
    if spec ? fields && spec.fields != {} then spec.fields
    else { value = "TODO:replace_me"; }
  ) kvSecrets;

  # ── Helpers ──────────────────────────────────────────────────────────

  # Write each policy body to a file so the shell script can reference it.
  policyFiles = lib.mapAttrs (
    name: body:
    pkgs.writeText "openbao-policy-${name}.hcl" body
  ) policies;

  # Build a JSON file with the full desired-state so the reconciler script
  # can consume it without massive escaping issues.
  desiredState = pkgs.writeText "openbao-desired-state.json" (builtins.toJSON {
    inherit reservedPolicies builtinSecretsEngines reservedAuthMethods;
    policies = lib.mapAttrs (_: _file: null) policies; # names only; bodies in files
    policyFiles = lib.mapAttrs (name: _: policyFiles.${name}) policies;
    secretsEngines = lib.mapAttrs (path: eng: {
      inherit (eng) type;
      options = eng.options or {};
    }) secretsEngines;
    authMethods = lib.mapAttrs (path: am: {
      inherit (am) type;
      config = am.config or {};
    }) authMethods;
    inherit authRoles userpassUsers;
    kvSecrets = kvSecretsNormalized;
  });

in
{
  systemd.services.openbao-apply-config = {
    description = "Declaratively reconcile OpenBao config (policies, auth, roles, engines)";
    after = [ "openbao-auto-unseal.service" ];
    requires = [ "openbao-auto-unseal.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [
      pkgs.openbao
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.diffutils
    ];

    environment = {
      BAO_ADDR = "http://127.0.0.1:${toString c.port}";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "root";
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadOnlyPaths = [ c.keysDir ];
      NoNewPrivileges = true;

      ExecStart = pkgs.writeShellScript "openbao-apply-config" ''
        set -euo pipefail

        STATE_FILE="${desiredState}"

        # ────────────────────────────────────────────────────────────────
        # Step 0: Generate a short-lived root token using unseal key(s)
        # ────────────────────────────────────────────────────────────────
        echo "[config] Generating ephemeral root token via operator generate-root ..."

        # Cancel any stale in-progress generate-root (e.g. from interrupted previous run)
        bao operator generate-root -cancel 2>/dev/null || true

        otp="$(bao operator generate-root -generate-otp)"
        init_json="$(bao operator generate-root -init -otp="$otp" -format=json)"
        nonce="$(printf '%s' "$init_json" | jq -r '.nonce')"

        # Feed each unseal key share (via stdin to avoid /proc/cmdline leak)
        encoded_token=""
        for key_file in ${c.keysDir}/openbao-unseal-*; do
          [ -f "$key_file" ] || continue
          result="$(cat "$key_file" | bao operator generate-root -nonce="$nonce" -format=json -)"
          complete="$(printf '%s' "$result" | jq -r '.complete')"
          if [ "$complete" = "true" ]; then
            encoded_token="$(printf '%s' "$result" | jq -r '.encoded_root_token // .encoded_token')"
            break
          fi
        done

        if [ -z "$encoded_token" ]; then
          echo "[config] ERROR: Failed to generate root token (not enough key shares?)" >&2
          exit 1
        fi

        root_token="$(bao operator generate-root -decode="$encoded_token" -otp="$otp")"
        export VAULT_TOKEN="$root_token"

        echo "[config] Ephemeral root token obtained"

        # ────────────────────────────────────────────────────────────────
        # Step 1: Secrets engines
        # ────────────────────────────────────────────────────────────────
        echo "[config] Reconciling secrets engines ..."

        desired_engines="$(jq -r '.secretsEngines | keys[]' "$STATE_FILE")"
        current_engines="$(bao secrets list -format=json | jq -r 'keys[]')"

        for engine_path in $desired_engines; do
          engine_type="$(jq -r --arg p "$engine_path" '.secretsEngines[$p].type' "$STATE_FILE")"
          engine_opts="$(jq -r --arg p "$engine_path" '.secretsEngines[$p].options | to_entries | map("-options=\(.key)=\(.value)") | join(" ")' "$STATE_FILE")"

          if echo "$current_engines" | grep -qxF "$engine_path"; then
            echo "  [engine] $engine_path already mounted"
          else
            echo "  [engine] Enabling $engine_path (type=$engine_type)"
            eval bao secrets enable -path="''${engine_path%/}" "$engine_type" $engine_opts
          fi
        done

        # ────────────────────────────────────────────────────────────────
        # Step 2: Auth methods
        # ────────────────────────────────────────────────────────────────
        echo "[config] Reconciling auth methods ..."

        desired_auths="$(jq -r '.authMethods | keys[]' "$STATE_FILE")"
        current_auths="$(bao auth list -format=json | jq -r 'keys[]')"
        reserved_auths="$(jq -r '.reservedAuthMethods[]' "$STATE_FILE")"

        for auth_path in $desired_auths; do
          auth_type="$(jq -r --arg p "$auth_path" '.authMethods[$p].type' "$STATE_FILE")"
          mount_path="''${auth_path%/}"

          if echo "$current_auths" | grep -qxF "$auth_path"; then
            echo "  [auth] $auth_path already enabled"
          else
            echo "  [auth] Enabling $auth_path (type=$auth_type)"
            bao auth enable -path="$mount_path" "$auth_type"
          fi

          # Apply config if present
          auth_config="$(jq -r --arg p "$auth_path" '.authMethods[$p].config // {} | to_entries | map("\(.key)=\(.value)") | .[]' "$STATE_FILE")"
          if [ -n "$auth_config" ]; then
            echo "  [auth] Writing config for $auth_path"
            config_args=""
            while IFS= read -r kv; do
              config_args="$config_args $kv"
            done <<< "$auth_config"
            eval bao write "auth/$mount_path/config" $config_args
          fi
        done

        # Remove auth methods not in desired state (skip reserved)
        for current_auth in $current_auths; do
          skip=false
          for reserved in $reserved_auths; do
            if [ "$current_auth" = "$reserved" ]; then
              skip=true
              break
            fi
          done
          if $skip; then continue; fi

          if ! echo "$desired_auths" | grep -qxF "$current_auth"; then
            echo "  [auth] ORPHAN: disabling $current_auth (not in config)"
            bao auth disable "''${current_auth%/}"
          fi
        done

        # ────────────────────────────────────────────────────────────────
        # Step 3: Auth roles
        # ────────────────────────────────────────────────────────────────
        echo "[config] Reconciling auth roles ..."

        for role_path in $(jq -r '.authRoles | keys[]' "$STATE_FILE"); do
          echo "  [role] Writing $role_path"
          role_json="$(jq -r --arg p "$role_path" '.authRoles[$p]' "$STATE_FILE")"

          # Build bao write arguments from JSON object
          write_args=""
          for key in $(printf '%s' "$role_json" | jq -r 'keys[]'); do
            val="$(printf '%s' "$role_json" | jq -r --arg k "$key" '.[$k] | if type == "array" then join(",") else tostring end')"
            write_args="$write_args $key=$val"
          done
          eval bao write "$role_path" $write_args
        done

        # ────────────────────────────────────────────────────────────────
        # Step 4: Userpass user config (policies only, not passwords)
        # ────────────────────────────────────────────────────────────────
        echo "[config] Reconciling userpass users ..."

        for user_path in $(jq -r '.userpassUsers | keys[]' "$STATE_FILE"); do
          echo "  [userpass] Writing $user_path"
          user_json="$(jq -r --arg p "$user_path" '.userpassUsers[$p]' "$STATE_FILE")"

          write_args=""
          for key in $(printf '%s' "$user_json" | jq -r 'keys[]'); do
            val="$(printf '%s' "$user_json" | jq -r --arg k "$key" '.[$k] | if type == "array" then join(",") else tostring end')"
            write_args="$write_args $key=$val"
          done
          eval bao write "$user_path" $write_args
        done

        # ────────────────────────────────────────────────────────────────
        # Step 5: Policies
        # ────────────────────────────────────────────────────────────────
        echo "[config] Reconciling policies ..."

        current_policies="$(bao policy list -format=json | jq -r '.[]')"
        reserved_policies="$(jq -r '.reservedPolicies[]' "$STATE_FILE")"

        # Apply all desired policies
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: file: ''
            echo "  [policy] Writing: ${name}"
            bao policy write "${name}" "${file}"
          '') policyFiles
        )}

        # Remove orphan policies
        for current_policy in $current_policies; do
          skip=false
          for reserved in $reserved_policies; do
            if [ "$current_policy" = "$reserved" ]; then
              skip=true
              break
            fi
          done
          if $skip; then continue; fi

          if ! jq -e --arg p "$current_policy" '.policyFiles | has($p)' "$STATE_FILE" > /dev/null; then
            echo "  [policy] ORPHAN: deleting policy '$current_policy' (not in config)"
            bao policy delete "$current_policy"
          fi
        done

        # ────────────────────────────────────────────────────────────────
        # Step 6: Seed KV secret stubs (never overwrites existing values)
        # ────────────────────────────────────────────────────────────────
        echo "[config] Seeding missing KV secrets with stubs ..."

        for kv_path in $(jq -r '.kvSecrets | keys[]' "$STATE_FILE"); do
          # Check if this secret already exists
          if bao kv get -mount=kv "$kv_path" > /dev/null 2>&1; then
            echo "  [kv] $kv_path exists"
          else
            echo "  [kv] $kv_path MISSING — creating stub"
            # Build key=value pairs from the fields object
            kv_args=""
            for field in $(jq -r --arg p "$kv_path" '.kvSecrets[$p] | keys[]' "$STATE_FILE"); do
              stub_val="$(jq -r --arg p "$kv_path" --arg f "$field" '.kvSecrets[$p][$f]' "$STATE_FILE")"
              kv_args="$kv_args $field=$stub_val"
            done
            eval bao kv put -mount=kv "$kv_path" $kv_args
          fi
        done

        # ────────────────────────────────────────────────────────────────
        # Step 7: Revoke ephemeral root token
        # ────────────────────────────────────────────────────────────────
        echo "[config] Revoking ephemeral root token ..."
        bao token revoke -self || echo "  [warn] Could not revoke root token (may have expired)"

        echo "[config] OpenBao configuration reconciliation complete."
      '';
    };
  };
}
