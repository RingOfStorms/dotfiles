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
  # Zitadel roles: device_high_trust, device_low_trust
  authRoles = {
    "auth/zitadel-jwt/role/machines-hightrust" = {
      role_type = "jwt";
      user_claim = "sub";
      groups_claim = "flatRolesClaim";
      bound_audiences = [ "344379162166820867" ];
      bound_claims = { flatRolesClaim = "device_high_trust"; };
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
      bound_claims = { flatRolesClaim = "device_low_trust"; };
      token_policies = [
        "machine-base"
        "machines-low-trust"
      ];
      token_ttl = "1h";
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
  };

  # ── KV secrets registry ───────────────────────────────────────────────
  # Declarative list of every KV secret that should exist.
  # The reconciler creates missing entries with a stub value so vault-agent
  # templates don't error on a missing path. Existing values are NEVER
  # overwritten — only missing keys get the stub.
  #
  # Format: "kv-mount-relative/path" = { fields = { fieldName = "stub"; ... }; }
  # The default field is "value" with stub "TODO:replace_me".
  #
  # All secrets use _2026-03-15 date suffix to mark post-rotation versions.
  # The reconciler deletes any KV entries under managed prefixes that are
  # not declared here.
  kvSecrets = {
    # ── high-trust: SSH keys ──────────────────────────────────────────
    # Single consolidated inter-machine key replaces all per-host nix2* keys
    "machines/high-trust/nix2nix_2026-03-15"        = {};
    # External git service keys (not inter-machine)
    "machines/high-trust/nix2github_2026-03-15"      = {};
    "machines/high-trust/nix2gitforgejo_2026-03-15"  = {};

    # ── high-trust: tailnet ───────────────────────────────────────────
    "machines/high-trust/headscale_auth_2026-03-15"  = {};

    # ── high-trust: nix / build ───────────────────────────────────────
    "machines/high-trust/github_read_token_2026-03-15" = {};

    # ── high-trust: h001 service secrets ──────────────────────────────
    "machines/high-trust/linode_rw_domains_2026-03-15"      = {};
    "machines/high-trust/us_chi_wg_2026-03-15"              = {};
    "machines/high-trust/zitadel_master_key_2026-03-15"     = {};
    "machines/high-trust/oauth2_proxy_key_file_2026-03-15"  = {};
    "machines/high-trust/openwebui_env_2026-03-15"          = {};
    "machines/high-trust/openrouter_2026-03-15"             = { fields = { api-key = "TODO:replace_me"; }; };

    # ── high-trust: per-host service secrets ──────────────────────────
    "machines/high-trust/atuin-key-josh_2026-03-15"         = { fields = { user = "TODO:replace_me"; password = "TODO:replace_me"; value = "TODO:replace_me"; }; };
    "machines/high-trust/litellm_public_api_key_2026-03-15" = {};
    "machines/high-trust/vaultwarden_env_2026-03-15"        = {};

    # ── low-trust (gp3, joe, i001) ────────────────────────────────────
    "machines/low-trust/headscale_auth_lowtrust_2026-03-15" = {};
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
    inherit authRoles;
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
            if ! eval bao write "auth/$mount_path/config" $config_args 2>&1; then
              echo "  [auth] WARNING: failed to write config for $auth_path (OIDC discovery may be down)" >&2
              echo "  [auth] Continuing — config will be applied on next run" >&2
            fi
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
          jq --arg p "$role_path" '.authRoles[$p]' "$STATE_FILE" \
            | bao write "$role_path" -
        done

        # ────────────────────────────────────────────────────────────────
        # Step 4: Policies
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
        # Step 5: Seed KV secret stubs (never overwrites existing values)
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
        # Step 6: Delete orphan KV secrets (not in declared kvSecrets)
        # ────────────────────────────────────────────────────────────────
        echo "[config] Cleaning orphan KV secrets ..."

        # Managed prefixes — only delete under these paths
        for prefix in "machines/high-trust" "machines/low-trust"; do
          current_keys="$(bao kv list -mount=kv -format=json "$prefix" 2>/dev/null | jq -r '.[]' || true)"
          for key in $current_keys; do
            full_path="$prefix/$key"
            if ! jq -e --arg p "$full_path" '.kvSecrets | has($p)' "$STATE_FILE" > /dev/null; then
              echo "  [kv] ORPHAN: deleting $full_path (not in config)"
              bao kv metadata delete -mount=kv "$full_path"
            fi
          done
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
