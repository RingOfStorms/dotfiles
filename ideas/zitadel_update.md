
## Nixpkgs/Zitadel pin status

**There is already a dedicated Zitadel nixpkgs input.** It is in the host flake, not the root flake:

- `hosts/h001/flake.nix:11`
- Used by `hosts/h001/containers/zitadel.nix:21,146`
- Currently locked at `331800de...`, packaging Zitadel `2.71.7`

However, **there is no currently usable nixpkgs PR for upstream Zitadel `4.17.1`**.

The closest candidate is nixpkgs PR [#448518](https://github.com/NixOS/nixpkgs/pull/448518):

- Only updates to Zitadel `4.3.0`
- Still open and marked stale/needs-changes
- `nixpkgs-review` reports the `zitadel` package failing on Linux and Darwin
- It is therefore not suitable as a production pin or as the latest-release solution

Nixpkgs master also still contains Zitadel `2.71.7`. Upstream `4.17.1` was released on August 14, 2026, so reaching it requires one of:

1. A new, buildable Zitadel-specific nixpkgs branch/fork.
2. A pinned upstream Zitadel source input plus a local package/overlay.
3. A verified upstream Linux binary derivation as a fallback.

The existing `4.3.0` PR is not a small version bump: v4 requires new ConnectRPC generation and a pnpm/Nx frontend build, while `4.17.1` uses Go 1.25 and pnpm 10. I would prefer a reproducible source package, but the upstream `zitadel-linux-amd64.tar.gz` binary is a reasonable emergency fallback if the source build delays the security update.

## Breaking changes and mitigations

### 1. Zitadel v3 changes

- **CockroachDB support was removed.** This does not affect this deployment because it already uses PostgreSQL 17.
- The repository license changed from Apache-2.0 to **AGPL-3.0-only**. This needs to be recorded in the package metadata and deployment documentation.
- The old Actions management API was removed in favor of Actions V2 APIs.
- The old web-key management API was removed in favor of the API V2/V2-beta web-key APIs.

The existing `flatRolesClaim` action is a runtime Actions V1 action using `ctx.v1` and `api.v1`. It should not be replaced automatically. The action code, flow type, timeout, and both triggers must be exported and tested first. If v4 still executes it correctly, retaining it avoids unnecessary integration changes.

### 2. Web-key and signing changes

Zitadel `3.4.1` enabled web keys by default. Setup creates two RSA/RS256 keys when none exist, with one active and the other available for transition.

Potential impact:

- A signing-key change can invalidate cached sessions or tokens.
- Consumers that cache JWKS may temporarily reject new tokens.
- The secrets-manager verifier should handle unknown key IDs, but oauth2-proxy and other clients still need testing.
- The old keys are stored in Zitadel’s database and encrypted using the master key.

Mitigation:

- Preserve both the PostgreSQL database and the unchanged master key.
- Capture the current JWKS/key IDs before migration.
- Keep RS256 during the initial upgrade because the current secrets-manager verifier explicitly requires it.
- Do not delete old/inactive keys immediately after migration.
- Test JWKS refresh and unknown-`kid` handling.

### 3. Zitadel v4 API changes

v4 moves core resources to resource-based APIs:

- Instances
- Organizations
- Projects
- Applications
- Authorizations
- Users
- Permissions

Many older V1 management endpoints are deprecated, including machine-user, machine-key, application, project, grant, and membership management endpoints. New APIs use ConnectRPC.

This should not inherently break the current OIDC flows because the deployment primarily relies on:

- OIDC discovery
- Authorization-code + PKCE
- JWT bearer/service-account authentication
- Token endpoint
- JWKS
- Role claims

Nevertheless, any future scripts that recreate clients, projects, or machine users need a v2/ConnectRPC equivalent documented.

### 4. Login V2 packaging

Upstream v4 uses a separate Next.js Login V2 process. The current deployment proxies the entire `sso.joshuabell.xyz` namespace to the single Zitadel API container.

The safest initial rollout is:

- Determine whether the existing instance uses Login V1.
- Keep Login V1 if it remains compatible.
- Do not enable Login V2 as part of the package upgrade unless the separate process is packaged and routed.
- If Login V2 is required, add a separate service and route `/ui/v2/login` to it.

### 5. Setup and migration lifecycle

Upstream recommends:

1. `init` once over the instance lifetime.
2. `setup` for every new Zitadel version.
3. `start` only after setup completes.

The current NixOS module always runs `start-from-init`, combining all phases. That may work, but it means migrations run as part of service startup. The upgrade should first be tested against a cloned database. For production, either:

- Use a controlled one-shot `setup --init-projections=true` during the maintenance window, then start the runtime; or
- Retain `start-from-init` only after it has been proven safe against the cloned production database.

The current `FirstInstance` password is also embedded in the Nix store at `hosts/h001/containers/zitadel.nix:228-235`. That should be moved to an external steps file or otherwise removed from the store as part of the upgrade work.

## Backup set that must exist before migration

Preserve and independently back up:

- `/var/lib/zitadel/postgres`
- `/var/lib/zitadel/backups/postgres/all.sql.gz`
- A fresh PostgreSQL dump, preferably including:
  - database contents
  - PostgreSQL globals/roles
  - a separately restorable custom-format dump
- `/var/lib/zitadel/masterkey`
  - exactly 32 raw bytes
  - despite the `.age` suffix, this is not age-encrypted
- `/var/lib/secrets_manager/sec.db`
- `/var/lib/secrets_manager/db.key`
  - these must be backed up together
- Every host’s `/machine-key.json`
- Actual encrypted secrets-manager values, especially:
  - oauth2-proxy client credentials/cookie secret
  - Open WebUI OIDC credentials and `WEBUI_SECRET_KEY`
- Zitadel-side configuration:
  - projects and grants
  - project roles
  - clients and redirect URIs
  - machine users and keys
  - the `flatRolesClaim` action and triggers
  - Login and feature settings

The current PostgreSQL backup is local-only and has no verified restore procedure, so it should not be treated as the rollback plan until an isolated restore succeeds.

## Recommended migration sequence

1. Build and verify a v4.17.1 package.
2. Restore a production database copy into an isolated test container.
3. Run the current v2.71.7 package against that copy and record a baseline.
4. Upgrade the clone through a suitable latest v3.4.x intermediate.
5. Verify web-key creation, JWKS compatibility, actions, users, projects, and clients.
6. Upgrade the clone to v4.17.1.
7. Run the full OIDC and machine-auth regression matrix.
8. Perform a final production dump and maintenance-window cutover.
9. Keep the old package pin, database backup, master key, and restore commands available until the new deployment is proven.

The tracked TODO list now contains the implementation sequence, including package creation, backup validation, cloned-database rehearsal, integration testing, production cutover, and a later isolated Logto exploration.

Logto should remain separate and non-blocking for now. When the Zitadel upgrade is accepted, it can be deployed as a disposable instance with independent data, secrets, hostname/port, and no production OIDC changes.


Security note: repository inspection encountered an inline Zitadel first-instance password in `hosts/h001/containers/zitadel.nix`. I have not opened the key or secrets-manager files, and I won’t repeat the password. Its presence in source and generated Nix configuration should be treated as exposure during the upgrade.Josh, the plan’s main assumption has changed: **there is now a credible source-packaging starting point, but no merged nixpkgs package for the latest ZITADEL.** I would keep the staged database migration and update the target.

**Version and package status, checked September 24, 2026**

| Item | Current status |
| --- | --- |
| This host’s dedicated `zitadel-nixpkgs` input | Locked to `331800de…`, packaging **2.71.7** (`hosts/h001/flake.nix:11`, `hosts/h001/containers/zitadel.nix:21,146`) |
| Latest upstream stable | **[4.19.1](https://github.com/zitadel/zitadel/releases/tag/v4.19.1)**, released September 23; fixes a setup-step-79 backfill issue |
| Latest v3.4.x intermediate | **[3.4.15](https://github.com/zitadel/zitadel/releases/tag/v3.4.15)** |
| nixpkgs master and unstable | Still package **2.71.7** |
| [nixpkgs PR #561044](https://github.com/NixOS/nixpkgs/pull/561044) | Open, unmerged **4.17.3** source package, plus separate Login V2 package. Its author reports Linux builds and runtime smoke tests; I have not reproduced them. The NixOS module has not been reviewed for v4. |
| [PR #448518](https://github.com/NixOS/nixpkgs/pull/448518) | Still open, stale **4.3.0** attempt with reported build failures; no longer the best starting point. |

**Recommended path**

1. **Establish a restorable baseline before changing the pin.** Take a fresh PostgreSQL database dump, globals/roles dump, and custom-format dump; independently preserve the database directory, unchanged 32-byte master key, secrets-manager database **with** its key, machine keys, and encrypted client secrets. Restore into an isolated instance and verify it runs on **2.71.7**. The configured PostgreSQL backup is local (`hosts/h001/containers/zitadel.nix:33-50,195-198`); enabling that service does not demonstrate an off-host, restorable backup.
2. **Inventory behavior on the clone.** Record issuer/discovery and JWKS key IDs, login mode, clients and redirects, service accounts, and the installed `flatRolesClaim` code, timeout, flow, and both triggers. The repository documents the action (`hosts/h001/containers/zitadel.md:3-42`) but does not declaratively install it. Test oauth2-proxy, Open WebUI, PKM, and secrets-manager machine authentication against this baseline.
3. **Package and rehearse 3.4.15 first.** Use a fixed source derivation if feasible, or a checksum-pinned upstream binary for a time-sensitive rehearsal. Run setup on the cloned database, verify web keys are active, RS256/JWKS behavior and Actions V1, then allow legacy-signed tokens and sessions to expire before v4. This intermediate is **not optional for a seamless signing-key transition**: [advisory A-10017](https://zitadel.com/docs/support/advisory/a10017) says v4 removes legacy signing-key verification. If a re-login window is acceptable, document it explicitly rather than assuming old tokens survive.
4. **Target 4.19.1, not 4.17.1 or 4.18.0.** Start from the build approach in #561044 and update and verify it for 4.19.1; it is not evidence that 4.19.1 already builds. A checksum-pinned upstream binary derivation is a defensible fallback if source packaging delays the security update. Upstream explicitly says to [skip 4.18.0](https://github.com/zitadel/zitadel/releases/tag/v4.18.0) because setup fails. Keep package metadata and documentation aligned with the v3+ AGPL licensing.
5. **Separate migration from runtime startup.** On the clone, test `setup --init-projections=true` followed by `start` for **each** new version. The current module’s combined `start-from-init` startup should not silently perform the production migration. Upstream describes `init` as ordinarily once per installation and `setup` as required per new version ([lifecycle guide](https://zitadel.com/docs/self-hosting/manage/updating_scaling)). Preserve the existing issuer and PostgreSQL 17 configuration.
6. **Keep Login V1 for this cutover.** [Upstream explicitly supports it for existing v4 instances](https://zitadel.com/docs/self-hosting/manage/upgrade-v3-to-v4). Do not add Login V2 routing or replace `flatRolesClaim` as part of the upgrade. Test the existing action in v4; migrate to Actions V2 only as separate work if a required flow demands it.
7. **Cut over only after a full cloned-database regression.** Exercise interactive authorization-code/PKCE login, role claims in access-token and user-info flows, logout/re-login, Console, JWKS refresh after an unknown `kid`, and JWT/service-account authentication. At the maintenance window, take a final consistent dump, run the same tested version sequence, and retain the **pre-migration database snapshot with its matching master key and old package pin**. Do not point 2.71.7 at a database already migrated to v4 and call that rollback.

The inline first-instance password noted during inspection is a separate security task: remove it from Nix-generated configuration and assess rotation. It is not necessary to change Login V2 or the Actions integration to do that. I made no deployment or repository changes and did not run builds or restore tests, so package suitability and migration success remain **verification gates**, not established outcomes.
