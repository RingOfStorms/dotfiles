# OpenBao Secrets Migration

## Overview

This document covers migrating from ragenix (age-encrypted secrets) to OpenBao for centralized secret management, enabling zero-config machine onboarding.

## Goals

1. **Zero-config machine onboarding**: New machine = install NixOS + add Zitadel machine key + done
2. **Eliminate re-keying workflow**: No more updating secrets.nix and re-encrypting .age files for each new machine
3. **Runtime secret dependencies**: Services wait for secrets via systemd, not build-time conditionals
4. **Consolidated SSH keys**: Use single `nix2nix` key for all NixOS machine SSH (keep `nix2t` for work)
5. **Declarative policy management**: OpenBao policies auto-applied after unseal with reconciliation
6. **Directional Tailscale ACLs**: Restrict work machine from reaching NixOS hosts (one-way access)
7. **Per-host variable registry**: `_variables.nix` pattern for ports/UIDs/GIDs to prevent conflicts

## Current State

### Ragenix Secrets in Use (21 active)

**SSH Keys (for client auth):**
- nix2github, nix2bitbucket, nix2gitforgejo
- nix2nix (shared), nix2t (work - keep separate)
- nix2lio (remote builds), nix2oren, nix2gpdPocket3
- nix2h001, nix2h003, nix2linode, nix2oracle

**API Tokens:**
- github_read_token (Nix private repo access)
- linode_rw_domains (ACME DNS challenge)
- litellm_public_api_key (nginx auth)

**VPN:**
- headscale_auth (Tailscale auth)
- us_chi_wg (NixArr WireGuard)

**Application Secrets:**
- oauth2_proxy_key_file
- openwebui_env
- zitadel_master_key
- vaultwarden_env

**Skipping (unused):**
- nix2h002, nix2joe, nix2l002, nix2gitjosh, obsidian_sync_env

### Already Migrated to OpenBao (juni)
- headscale_auth, atuin-key-josh, 12 SSH keys

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        New Machine Onboarding                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Install NixOS with full config                              │
│     - All services defined but waiting on secrets               │
│                                                                 │
│  2. Create Zitadel machine user + copy key                      │
│     - /machine-key.json → JWT auth to OpenBao                   │
│                                                                 │
│  3. vault-agent fetches secrets                                 │
│     - kv/data/machines/home_roaming/* → /var/lib/openbao-secrets│
│                                                                 │
│  4. systemd dependencies resolve                                │
│     - secret-watcher completes → hardDepend services start      │
│                                                                 │
│  5. Machine fully operational                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### Secret Path Convention

```
kv/data/machines/
├── home_roaming/        # Shared across all NixOS machines
│   ├── nix2nix          # SSH key
│   ├── nix2github       # SSH key  
│   ├── headscale_auth   # Tailscale auth
│   └── ...
├── home/                # h001-specific (not roaming)
│   ├── linode_rw_domains
│   ├── zitadel_master_key
│   └── ...
└── oracle/              # o001-specific
    ├── vaultwarden_env
    └── ...
```

### Runtime Dependencies vs Build-Time Conditionals

**Before (ragenix pattern - bad for onboarding):**
```nix
let hasSecret = name: (config.age.secrets or {}) ? ${name};
in {
  config = lib.mkIf (hasSecret "openwebui_env") {
    services.open-webui.enable = true;
  };
}
```

**After (OpenBao pattern - zero-config onboarding):**
```nix
ringofstorms.secretsBao.secrets.openwebui_env = {
  kvPath = "kv/data/machines/home_roaming/openwebui_env";
  hardDepend = [ "open-webui" ];  # Service waits for secret at runtime
  configChanges.services.open-webui = {
    enable = true;
    environmentFile = "$SECRET_PATH";
  };
};
```

### Per-Host File Structure

```
hosts/h001/
├── _variables.nix       # Ports, UIDs, GIDs - single source of truth
├── secrets.nix          # All secrets + their configChanges
├── flake.nix            # Imports, basic host config
├── nginx.nix            # Pure config (no conditionals)
└── mods/
    ├── openbao-policies.nix  # Auto-apply after unseal
    └── ...
```

### OpenBao Policy Management

Policies auto-apply after unseal with full reconciliation:

```nix
# openbao-policies.nix
let
  policies = {
    machines = ''
      path "kv/data/machines/home_roaming/*" {
        capabilities = ["read", "list"]
      }
    '';
  };
  reservedPolicies = [ "default" "root" ];
in {
  systemd.services.openbao-apply-policies = {
    after = [ "openbao-auto-unseal.service" ];
    requires = [ "openbao-auto-unseal.service" ];
    wantedBy = [ "multi-user.target" ];
    # Script: apply all policies, delete orphans not in config
  };
}
```

### Headscale ACL Policy

Directional access control:

```nix
# nix machines: full mesh access
{ action = "accept"; src = ["group:nix-machines"]; dst = ["group:nix-machines:*"]; }

# nix machines → work: full access  
{ action = "accept"; src = ["group:nix-machines"]; dst = ["tag:work:*"]; }

# work → nix machines: LIMITED (only specific ports)
{ action = "accept"; src = ["tag:work"]; dst = ["h001:22,443"]; }
```

## Implementation Phases

### Phase 1: SSH Key Preparation
- [ ] Add nix2nix SSH key to all hosts authorized_keys (alongside existing)
- [ ] Deploy with `nh os switch` to all hosts

### Phase 2: Infrastructure
- [ ] Create `_variables.nix` pattern for h001 (pilot)
- [ ] Create `openbao-policies.nix` with auto-apply + reconciliation
- [ ] Create `headscale-policy.nix` with directional ACLs
- [ ] Create per-host `secrets.nix` pattern

### Phase 3: Secret Migration
- [ ] Migrate h001 secrets (linode_rw_domains, us_chi_wg, oauth2_proxy_key_file, openwebui_env, zitadel_master_key)
- [ ] Migrate o001 secrets (vaultwarden_env, litellm_public_api_key)
- [ ] Migrate common modules (tailnet, ssh, nix_options)
- [ ] Migrate SSH client keys

### Phase 4: Consumer Updates
- [ ] Update ssh.nix to use OpenBao paths
- [ ] Remove hasSecret conditionals from all modules
- [ ] Remove ragenix imports and secrets flake

### Phase 5: Testing & Finalization
- [ ] Populate all secrets in OpenBao KV store
- [ ] Test onboarding workflow on fresh VM
- [ ] Document new machine onboarding process

## Related Ideas

- `impermanence_everywhere.md` - Impermanence persists `/var/lib/openbao-secrets` and `/machine-key.json`
- `resilience.md` - OpenBao server (h001) is a SPOF; consider backup/failover
- `service_backups.md` - `/var/lib/openbao` and `/bao-keys` need backup

## Notes

- OpenBao hosted on h001 at sec.joshuabell.xyz
- JWT auth via Zitadel machine users
- vault-agent on each host fetches secrets
- `sec` CLI tool available for manual lookups
