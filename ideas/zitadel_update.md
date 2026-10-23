# Zitadel v2 → v3 → v4 Upgrade Plan (`containers/zitadel`)

## Current Deployment Status (2026-10-23)

Zitadel now runs as a **floating container** at `containers/zitadel/` (migrated from the legacy `hosts/h001/containers/zitadel.nix`).

| Item | Current Status |
| --- | --- |
| **Container definition** | `containers/zitadel/{flake.nix,service.nix,container.nix}` |
| **Pinned Zitadel version** | **2.71.7** via `guestpkgs.url = "github:nixos/nixpkgs/331800de5053fcebacf6813adb5db9c9dca22a0c"` (`containers/zitadel/flake.nix:12`) |
| **Data layout on host (`h001`)** | `/srv/containers/zitadel/{postgres,pgdumps,keys}` (`containers/zitadel/service.nix:31-35`, idmapped ext4) |
| **Masterkey (`M7`)** | ✅ **Done:** Tightened to `0400 zitadel:zitadel` via tmpfiles at `/var/lib/zitadel-keys/masterkey` (`containers/zitadel/container.nix:37,83`) |
| **Backups & Cold-Restore (`ROUTING-PLAN.md` §9.3)** | ✅ **Done (2026-10-22):** Nightly `fleet-backup` (`svc:zitadel` to B2), plus independent off-repo copy of `sec` and `zitadel` and verified cold-restore test using break-glass keys |
| **Inline `FirstInstance` password** | ⚠️ **Still present:** `Password = "Password1!"` in `containers/zitadel/container.nix:70` (only used on empty DB init, but should be removed from the Nix store during the upgrade) |
| **Target upstream versions** | Intermediate **v3.4.x** (`≥ 3.4.15`) → Latest **v4.x** (`≥ 4.19.1`; skip `4.18.0` due to upstream setup bug) |
| **Packaging starting point** | [nixpkgs PR #561044](https://github.com/NixOS/nixpkgs/pull/561044) (packages Zitadel 4.x + Login V2 from source) or checksum-pinned upstream Linux release binary inside `containers/zitadel/flake.nix` |

---

## Key Breaking Changes & Mitigations

### 1. Zitadel v3 Changes (Mandatory Intermediate Step)
- **Signing / Web Keys ([Advisory A-10017](https://zitadel.com/docs/support/advisory/a10017)):**
  - Zitadel `3.4.x` enables web keys by default and creates two RSA/RS256 keys when none exist (one active, one transition).
  - **Why v3.4.x cannot be skipped:** Zitadel v4 removes legacy signing-key verification entirely. Upgrading `2.71.7 → 3.4.x` first transitions keys cleanly; jumping straight to v4 invalidates all active tokens/sessions immediately.
  - Keep **RS256** during the upgrade because `secrets_manager` (`containers/sec`) explicitly verifies RS256 tokens.
- **Actions V1 (`flatRolesClaim`):**
  - The old Actions V1 *management* API was removed in v3, but runtime execution of existing Actions V1 (`ctx.v1` / `api.v1`) remains supported in v3/v4.
  - Export and record the `flatRolesClaim` script, flow type, timeout, and triggers before upgrading; verify role claims still appear in access tokens and userinfo responses after each hop.
- **License change:** Apache-2.0 → **AGPL-3.0-only** in v3+.

### 2. Zitadel v4 Changes
- **Login V2 (Next.js separate process):**
  - Upstream v4 introduces a separate Login V2 daemon, but [explicitly continues to support Login V1 for existing upgraded instances](https://zitadel.com/docs/self-hosting/manage/upgrade-v3-to-v4).
  - **Decision:** Keep Login V1 for the initial v4 upgrade so we don't have to package or route `/ui/v2/login` simultaneously.
- **Resource-based APIs (ConnectRPC):**
  - Core management endpoints move to v2/ConnectRPC, while standard OIDC discovery, Authorization Code + PKCE, JWT bearer (`sec-agent` machine auth), token, and JWKS endpoints remain compatible.
- **Setup vs. Runtime Startup (`start-from-init`):**
  - Upstream recommends running `zitadel setup --init-projections=true` explicitly per new version before `zitadel start`, rather than relying on the NixOS module's combined `start-from-init` on the live DB without prior rehearsal.

---

## Staged Upgrade & Rehearsal Plan

Because Zitadel is now a self-contained floating container (`containers/zitadel/`), we can rehearse the entire upgrade against a cloned `/srv/containers/zitadel` directory in an isolated test container (e.g., on `h003` or a scratch service on `h001`) without touching production SSO.

### Phase 1: Rehearsal on Cloned State
1. **Trigger a fresh backup of production Zitadel:**
   ```sh
   cnt backup zitadel
   ```
   Also record current `/oidc/v1/keys` (JWKS `kid`s), `/.well-known/openid-configuration`, and export the `flatRolesClaim` action definition.
2. **Spin up an isolated clone (e.g. on `h003` or as a test container):**
   - Restore the `zitadel` tarball onto the test host's `/srv/containers/zitadel` (keeping the exact 32-byte `keys/masterkey` and `postgres` cluster).
   - Verify it boots cleanly on current `2.71.7`.
3. **Hop 1 on clone: `2.71.7 → 3.4.15+`:**
   - Package `3.4.15+` in `containers/zitadel/flake.nix` (source override or upstream `zitadel-linux-amd64.tar.gz` binary derivation).
   - Run `zitadel setup --masterkeyFile /var/lib/zitadel-keys/masterkey --config ... --init-projections=true` and observe completion.
   - Start `zitadel`, verify web keys are generated, check JWKS (`RS256`), and verify `flatRolesClaim`.
4. **Hop 2 on clone: `3.4.15+ → 4.19.1+`:**
   - Update package in `containers/zitadel/flake.nix` to `4.19.1+` (adapting [PR #561044](https://github.com/NixOS/nixpkgs/pull/561044) or upstream binary).
   - Remove the `steps.FirstInstance` block (and inline `Password = "Password1!"`) from `containers/zitadel/container.nix:60-75` — the DB is already initialized, so `FirstInstance` is dead weight and leaks a default password into the Nix store.
   - Run `zitadel setup --init-projections=true`, then start `zitadel`.
   - Verify Login V1 UI, Console UI, OIDC auth-code + PKCE flow, `flatRolesClaim` role injection, and `sec-agent` JWT bearer machine authentication.

### Phase 2: Production Cutover Window
1. Run `cnt backup zitadel` on `h001` (and confirm a fresh `svc:zitadel` restic snapshot exists in B2). Keep a local copy of `/srv/containers/zitadel` on `h001` (`/srv/containers/zitadel.pre-v4`) for instant rollback.
2. Deploy the tested `3.4.x` container definition (`cnt deploy zitadel`), verify `setup` and projections finish, and confirm `oauth2-proxy` (`h005`), `open-webui`, `forgejo`, and `sec-agent` authenticate cleanly.
3. Deploy the tested `4.19.1+` container definition (`cnt deploy zitadel`), verify `setup` completes, and run the full login + `sec-agent` check across `h001`/`h005`/`lio`.
4. **Rollback if needed:** `cnt stop zitadel`, swap `/srv/containers/zitadel.pre-v4` back into `/srv/containers/zitadel`, and redeploy the `2.71.7` commit (`cnt deploy zitadel`). Never point `2.71.7` at a DB that has already run v3/v4 migrations.
