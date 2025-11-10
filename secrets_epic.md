# Secrets Management Migration Epic

Migration from agenix to OpenBao for dynamic secrets management with Zitadel OIDC authentication.

## Goals

- Replace static encrypted secrets (agenix) with dynamic runtime secrets (OpenBao)
- Enable automated host onboarding with single identity token
- Support offline operation through vault-agent caching
- Graceful degradation when secrets unavailable

## Phase 1: OpenBao Setup on h001

### 1.1 Create OpenBao NixOS Module ✅

**File:** `hosts/h001/mods/openbao.nix`

**Tasks:**
- [x] Create basic module structure using `services.openbao`
- [x] Configure file storage backend at `/var/lib/openbao`
- [x] Set up TCP listener on `127.0.0.1:8200`
- [x] Enable UI (`services.openbao.settings.ui = true`)
- [x] Add systemd service hardening options

**Config structure:**
```nix
services.openbao = {
  enable = true;
  settings = {
    ui = true;
    listener.tcp = {
      address = "127.0.0.1:8200";
      tls_disable = true;  # nginx will handle TLS
    };
    storage.file = {
      path = "/var/lib/openbao";
    };
  };
};
```

### 1.2 Configure Nginx Reverse Proxy

**File:** Put this inside of the openbao.nix file as well above or below the existing configuration.

**Tasks:**
- [x] Add virtualHost for `sec.joshuabell.xyz`
- [x] Configure SSL using existing ACME wildcard cert
- [x] Add virtualHost for `sec.joshuabell.xyz`
- [x] Configure SSL using existing ACME wildcard cert
- [x] Set up proxy to `http://127.0.0.1:8200`
- [x] Enable websockets for UI
- [x] Add security headers

**Expected config:**
```nix
services.nginx.virtualHosts."sec.joshuabell.xyz" = {
  addSSL = true;
  sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
  sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
  locations."/" = {
    proxyPass = "http://127.0.0.1:8200";
    proxyWebsockets = true;
    recommendedProxySettings = true;
  };
};
```

### 1.3 Import Module

**File:** `hosts/h001/mods/default.nix`

**Tasks:**
- [ ] Add `./openbao.nix` to imports list

### 1.4 Initial Deployment

**Tasks:**
- [x] Deploy to h001 with `nixos-rebuild switch`
- [x] Verify OpenBao service is running
- [x] Access UI at `https://sec.joshuabell.xyz`
- [x] Initialize OpenBao (generates root token and unseal keys)
- [x] Save unseal keys and root token securely (LastPass/Bitwarden)
- [x] Unseal the vault

**Commands:**
```bash
# Check service status
systemctl status openbao

# Initialize (do once)
openbao operator init

# Unseal (after each restart, requires 3 of 5 keys by default)
openbao operator unseal <key1>
openbao operator unseal <key2>
openbao operator unseal <key3>
```

### 1.5 Enable KV Secrets Engine

**Tasks:**
- [ ] Login to OpenBao with root token
- [ ] Enable KV v2 secrets engine at path `kv/`
- [ ] Create initial secret structure

**Commands:**
```bash
export VAULT_ADDR='https://sec.joshuabell.xyz'
openbao login <root-token>
openbao secrets enable -version=2 kv
openbao kv put kv/test password=hello
openbao kv get kv/test
```

## Phase 2: Zitadel Integration

### 2.1 Configure OpenBao OIDC Auth Method

**Tasks:**
- [ ] Get Zitadel OIDC discovery URL (`https://sso.joshuabell.xyz/.well-known/openid-configuration`)
- [ ] Create service account in Zitadel for OpenBao
- [ ] Generate client ID and client secret
- [ ] Configure OIDC auth method in OpenBao at path `oidc/`
- [ ] Set up bound audiences and claims

**Commands:**
```bash
openbao auth enable oidc

openbao write auth/oidc/config \
  oidc_discovery_url="https://sso.joshuabell.xyz" \
  oidc_client_id="<client-id-from-zitadel>" \
  oidc_client_secret="<client-secret-from-zitadel>" \
  default_role="nixos-host"
```

### 2.2 Create OpenBao Policies

**File:** Document policies in code or external files

**Tasks:**
- [ ] Create `nixos-host-base` policy (read access to host-specific paths)
- [ ] Create `nixos-h001` policy (read `kv/data/hosts/h001/*`)
- [ ] Create `nixos-h002` policy (read `kv/data/hosts/h002/*`)
- [ ] Create `nixos-h003` policy (read `kv/data/hosts/h003/*`)
- [ ] Create admin policy for manual management

**Example policy:**
```hcl
# nixos-h001 policy
path "kv/data/hosts/h001/*" {
  capabilities = ["read", "list"]
}
```

**Commands:**
```bash
openbao policy write nixos-h001 - <<EOF
path "kv/data/hosts/h001/*" {
  capabilities = ["read", "list"]
}
EOF
```

### 2.3 Create OpenBao Roles for Hosts

**Tasks:**
- [ ] Create OIDC role `nixos-h001` bound to Zitadel machine user
- [ ] Create OIDC role `nixos-h002` bound to Zitadel machine user
- [ ] Create OIDC role `nixos-h003` bound to Zitadel machine user
- [ ] Associate each role with corresponding policy

**Commands:**
```bash
openbao write auth/oidc/role/nixos-h001 \
  bound_audiences="<client-id>" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  policies="nixos-h001" \
  bound_claims='{"sub":"<machine-user-id-from-zitadel>"}'
```

### 2.4 Create Machine Users in Zitadel

**Tasks:**
- [ ] Login to Zitadel at `https://sso.joshuabell.xyz`
- [ ] Create machine user `nixos-h001`
- [ ] Create machine user `nixos-h002`
- [ ] Create machine user `nixos-h003`
- [ ] Generate JWT credentials for each
- [ ] Save JWTs securely (these will be injected during install)
- [ ] Note the subject claim (`sub`) for each machine user

### 2.5 Test OIDC Authentication

**Tasks:**
- [ ] Attempt OIDC login from CLI using machine user JWT
- [ ] Verify token is issued
- [ ] Verify policies are attached
- [ ] Test reading a secret with issued token

**Commands:**
```bash
# This will open browser - may need manual flow for machine users
openbao login -method=oidc role=nixos-h001

# Verify token and policies
openbao token lookup
```

## Phase 3: NixOS vault-agent Integration

### 3.1 Create Reusable vault-agent Module

**File:** `flakes/common/nix_modules/vault_agent.nix`

**Tasks:**
- [ ] Create module with options for:
  - Vault address
  - Auth method and role
  - JWT token path
  - Secret definitions (path, destination, owner, restart command)
- [ ] Configure auto-auth with OIDC
- [ ] Set up file sink for token caching at `/var/lib/vault-agent/token`
- [ ] Enable caching for offline operation
- [ ] Create template blocks for each secret
- [ ] Set up systemd tmpfiles for directories
- [ ] Configure proper file permissions and ownership

**Module structure:**
```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.services.vault-agent;
in {
  options.services.vault-agent = {
    enable = lib.mkEnableOption "vault-agent";
    vaultAddress = lib.mkOption { type = lib.types.str; };
    role = lib.mkOption { type = lib.types.str; };
    jwtPath = lib.mkOption { type = lib.types.str; default = "/etc/vault/jwt"; };
    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          path = lib.mkOption { type = lib.types.str; };
          destination = lib.mkOption { type = lib.types.str; };
          owner = lib.mkOption { type = lib.types.str; default = "root"; };
          group = lib.mkOption { type = lib.types.str; default = "root"; };
          permissions = lib.mkOption { type = lib.types.str; default = "0400"; };
          template = lib.mkOption { type = lib.types.str; };
          command = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      });
    };
  };
  
  config = lib.mkIf cfg.enable {
    # systemd service config
    # vault-agent configuration file
    # tmpfiles rules
  };
}
```

### 3.2 Add Module to Common Flake

**File:** `flakes/common/flake.nix`

**Tasks:**
- [ ] Export vault-agent module in `nixosModules`
- [ ] Ensure it's available to host configurations

### 3.3 Create Host-Specific Configuration

**File:** `hosts/h001/mods/vault-integration.nix`

**Tasks:**
- [ ] Import vault-agent module
- [ ] Configure vault-agent for h001:
  - vault address: `https://sec.joshuabell.xyz`
  - role: `nixos-h001`
  - JWT path: `/etc/vault/h001-jwt`
- [ ] Define secrets needed by h001 services
- [ ] Configure service dependencies (services wait for vault-agent)

**Example:**
```nix
services.vault-agent = {
  enable = true;
  vaultAddress = "https://sec.joshuabell.xyz";
  role = "nixos-h001";
  secrets = {
    postgres-password = {
      path = "kv/data/hosts/h001/postgresql";
      destination = "/run/secrets/postgres-password";
      owner = "postgres";
      group = "postgres";
      template = "{{ with secret \"kv/data/hosts/h001/postgresql\" }}{{ .Data.data.password }}{{ end }}";
      command = "systemctl try-reload-or-restart postgresql.service";
    };
  };
};

systemd.services.postgresql = {
  requires = [ "vault-agent.service" ];
  after = [ "vault-agent.service" ];
};
```

### 3.4 Import vault-integration Module

**File:** `hosts/h001/mods/default.nix`

**Tasks:**
- [ ] Add `./vault-integration.nix` to imports

## Phase 4: Migrate First Secret

### 4.1 Choose Test Secret

**Decision:** Start with `openwebui_env.age`
- Non-critical if it fails
- Single host (h001)
- Environment file format (good test case)
- Service can gracefully fail

### 4.2 Add Secret to OpenBao

**Tasks:**
- [ ] Decrypt current `openwebui_env.age` to get values
- [ ] Parse environment variables
- [ ] Add each value to OpenBao at `kv/hosts/h001/openwebui`

**Commands:**
```bash
# Decrypt current secret
ragenix -d openwebui_env.age > /tmp/openwebui.env

# Add to vault (example, adjust based on actual env vars)
openbao kv put kv/hosts/h001/openwebui \
  api_key="xxx" \
  other_var="yyy"
```

### 4.3 Update Service Configuration

**File:** `hosts/h001/mods/openwebui.nix`

**Tasks:**
- [ ] Remove agenix secret reference
- [ ] Change service to use `/run/secrets/openwebui-env`
- [ ] Add vault-agent secret definition for this env file
- [ ] Configure service dependency on vault-agent

### 4.4 Deploy and Test

**Tasks:**
- [ ] Deploy configuration to h001
- [ ] Verify vault-agent service starts
- [ ] Check `/run/secrets/openwebui-env` is created
- [ ] Verify openwebui service starts successfully
- [ ] Test openwebui functionality
- [ ] Test offline scenario (stop openbao, restart host, verify cached secret works)

### 4.5 Remove Old Secret

**Tasks:**
- [ ] Remove `openwebui_env.age` from `flakes/secrets/`
- [ ] Remove from `secrets.nix` definitions
- [ ] Commit changes

## Phase 5: Migrate Remaining Secrets

### 5.1 Migrate Environment Files

**Secrets to migrate:**
- [ ] `obsidian_sync_env.age`
- [ ] `vaultwarden_env.age` (on o001, expand to that host)

**Process per secret:**
1. Add to OpenBao at appropriate path
2. Update service configuration
3. Test deployment
4. Remove old agenix file

### 5.2 Migrate Single-Value Secrets

**Secrets to migrate:**
- [ ] `oauth2_proxy_key_file.age`
- [ ] `zitadel_master_key.age` (careful - currently used in container bind mount)

**Process per secret:**
1. Add to OpenBao
2. Update service to read from vault-agent rendered file
3. Test thoroughly
4. Remove old agenix file

### 5.3 Decide on SSH Keys

**Secrets to evaluate:**
- `nix2*.age` - SSH keys for git/deployment access
- `headscale_auth.age` - network auth
- `us_chi_wg.age` - wireguard config
- `github_read_token.age` - API token
- `linode_rw_domains.age` - DNS API token

**Decision criteria:**
- How often do they change?
- Would dynamic fetching improve security?
- Is rotation feasible?

**Tasks:**
- [ ] Document which secrets stay in agenix
- [ ] Document why (static network config, rotation not needed, etc.)
- [ ] Migrate appropriate ones to OpenBao

### 5.4 Expand to Other Hosts

**Per host (h002, h003):**
- [ ] Create machine user in Zitadel
- [ ] Create policy and role in OpenBao
- [ ] Add secrets to OpenBao at `kv/hosts/h00X/`
- [ ] Create vault-integration module for host
- [ ] Generate and save JWT token
- [ ] Test deployment

**Per host (lio, oren, gpdPocket3):**
- [ ] Evaluate which secrets they need from OpenBao
- [ ] Configure vault-agent for mobile/offline scenarios
- [ ] Test cached operation when offline

## Phase 6: Automated Onboarding Preparation

### 6.1 Document JWT Injection Process

**Tasks:**
- [ ] Create standard location for JWT: `/etc/vault/jwt`
- [ ] Document manual process to inject JWT during install
- [ ] Test manual injection on testbed host

### 6.2 Create Wrapper Script for nixos-anywhere

**File:** `scripts/install-host.sh` or similar

**Tasks:**
- [ ] Create script that takes hostname and target IP
- [ ] Script copies JWT from local secrets store
- [ ] Uses nixos-anywhere with post-partition hooks
- [ ] Injects JWT to `/mnt/etc/vault/jwt` before nixos-install

### 6.3 Test Full Installation Flow

**Tasks:**
- [ ] Boot testbed host to installer
- [ ] Run wrapper script
- [ ] Verify host installs successfully
- [ ] Verify host boots and authenticates to OpenBao
- [ ] Verify services start with secrets

### 6.4 Document New Onboarding Process

**File:** Update `readme.md` or create `docs/onboarding.md`

**Tasks:**
- [ ] Document Zitadel machine user creation
- [ ] Document OpenBao policy/role setup
- [ ] Document adding secrets to OpenBao
- [ ] Document host configuration steps
- [ ] Document install command
- [ ] Document verification steps

## Phase 7: Production Hardening

### 7.1 OpenBao Auto-Unseal

**Tasks:**
- [ ] Research auto-unseal options (cloud KMS, Shamir, etc.)
- [ ] Implement chosen auto-unseal method
- [ ] Test restart without manual unseal

### 7.2 Backup and Recovery

**Tasks:**
- [ ] Set up automated OpenBao snapshots
- [ ] Test restore from backup
- [ ] Document recovery procedures
- [ ] Store unseal keys in secure location (separate from backups)

### 7.3 Monitoring and Alerting

**Tasks:**
- [ ] Add OpenBao metrics to Grafana (already have monitoring on h001)
- [ ] Create alerts for:
  - Sealed state
  - Authentication failures
  - Secret access errors
- [ ] Monitor vault-agent health on each host

### 7.4 Secret Rotation

**Tasks:**
- [ ] Document secret rotation procedures
- [ ] Identify secrets that should rotate regularly
- [ ] Create rotation schedule
- [ ] Test rotation without service interruption

### 7.5 Security Review

**Tasks:**
- [ ] Review OpenBao policies (principle of least privilege)
- [ ] Review network access (firewall rules)
- [ ] Review audit logging
- [ ] Review JWT token expiration and renewal
- [ ] Penetration test (attempt to access secrets without proper auth)

## Success Criteria

- [ ] OpenBao running and accessible at `https://sec.joshuabell.xyz`
- [ ] Zitadel OIDC authentication working for machine users
- [ ] At least 3 secrets migrated from agenix to OpenBao
- [ ] Services on h001 starting successfully with vault-agent secrets
- [ ] Offline operation tested and working (cached secrets)
- [ ] Documentation complete for onboarding new hosts
- [ ] No secrets in git except encrypted agenix files for static configs
- [ ] Clear migration path established for remaining secrets

## Rollback Plan

At any point, can rollback by:
1. Reverting host configuration to use agenix
2. Ensuring agenix secrets still exist and are valid
3. Redeploying previous configuration
4. OpenBao can continue running for future use

## Notes

- Keep agenix infrastructure until migration fully complete
- Test each migration step on h001 before expanding to other hosts
- Prioritize services where dynamic secrets add value
- Some secrets (SSH keys, wireguard) may never migrate - that's ok
- Focus on secrets that would benefit from:
  - Dynamic generation
  - Automatic rotation
  - Centralized management
  - Audit logging
