# Zitadel 4.20.2 upgrade (`containers/zitadel`)

## Repository state (2026-11-10; not deployed)

- `containers/zitadel/flake.nix` pins the Zitadel package from
  [nixpkgs PR #561044](https://github.com/NixOS/nixpkgs/pull/561044), revision
  `b1d866102a281a5c7a2d083eedd4d27f628c9b41` of `byteflavour/nixpkgs`.
  The pin includes the setup migration fix; do not substitute an unpatched
  upstream binary merely because its version is also 4.20.2.
- The host-side nixpkgs and guest nixpkgs pins are unchanged. PostgreSQL stays
  **17.10**, with its existing cluster at `/var/lib/postgresql/17`; no PostgreSQL
  major-version migration is involved.
- Startup explicitly runs `zitadel setup --init-projections=true`, then
  `exec zitadel start`, using the same generated configuration, masterkey and
  external TLS mode. A failed setup prevents startup. Migrations are idempotent
  and run again on service restart.
- Removed `steps.FirstInstance` and its inline default password. This deployment
  expects an initialized database: restore it before starting a replacement
  container. It is not a fresh-install bootstrap recipe. Old Nix store
  generations may still contain the former default password.
- Keep **Login V1**. The pinned nixpkgs also provides `zitadel-login`, but this
  container deliberately does not deploy the separate Login V2 process.
  [Upstream](https://zitadel.com/docs/self-hosting/manage/upgrade-v3-to-v4)
  says existing instances keep Login V1; `DefaultInstance`/`FirstInstance`
  feature settings affect creation, not existing instances. Do not try to change
  an existing instance's login version by setting those environment variables.
- No production issuer, client IDs, roles, machine keys, routes or sec-agent
  configuration change in this upgrade. The decision is to stay with Zitadel
  for now; see the [Rauthy evaluation and migration questions](rauthy.md) and
  [token-spike evidence](../containers/sec/README.md#rauthy-0372-spike).

## Verification and limits

The 4.20.2 package built from source, and the complete x86_64-linux container
built successfully with `nix build --no-link --no-write-lock-file
./containers/zitadel#packages.x86_64-linux.default`.

A disposable PostgreSQL 17.10 database was initialized by Zitadel 2.71.7, then
migrated directly with the pinned 4.20.2 `setup`: exit 0, setup completed.
The migrated 4.20.2 server returned HTTP 200 from `/debug/healthz`.
This was a newly initialized test instance, **not a copy of the production
users, applications or Actions V1 configuration**. It proves that this direct
schema hop can work, not that every production login/claim survives it.
The test had no pre-upgrade issued tokens, so it did not test token continuity.
An empty pre-upgrade JWKS alone is not proof of any particular signing-key state.

Further disposable-instance checks exercised the exact `setup
--init-projections=true` then `start --tlsMode=external` sequence, including
repeat setup. Discovery advertised the HTTPS issuer and JWT-bearer grant;
JWKS contained RSA/RS256 keys. An HTTP form client completed Login V1,
authorization-code + PKCE, token exchange and userinfo. A test machine's RS256
assertion obtained a JWT access token and authenticated API requests; expired
assertions, wrong audience, unknown key IDs and forged signatures were rejected.
This verifies the protocol path, not visual browser rendering or the fleet's
custom `flatRolesClaim` action.

Keep `--tlsMode=external`: `disabled` overrides `ExternalSecure` and produces an
HTTP issuer. Keep the existing Login V1 feature state: explicitly enabling Login
V2 on a disposable instance redirected authorization to an absent endpoint (404).
During first startup the test briefly returned `Errors.WebKey.NoActive` while
projections caught up; check readiness and successful token issuance after
convergence rather than treating health alone as sufficient.

## Migration choice: recommended staged path vs direct hop

[Advisory A-10017](https://zitadel.com/docs/support/advisory/a10017) is the key
operational risk. v4 removes legacy OIDC signing; setup creates web keys if
missing, and old legacy-signed JWTs may immediately stop verifying. Users may
need to log in again; stale `id_token_hint`/Console session storage can break
logout or re-login until cleared.

**Recommended production path:** latest suitable v3.4.x (at least v3.4.1),
verify web keys, let legacy-signed tokens/sessions expire, then 4.20.2. The
intermediate v3 package is not included in this repository change. Do not assume
the final v4 pin automatically performs a v3 soak.

**Direct 2.71.7 → 4.20.2:** the disposable migration succeeded, so v3 is not an
unconditional schema prerequisite for this patched package. A direct production
hop still requires a successful rehearsal on a production backup and an accepted
re-login/token refresh window. Existing machine private keys and server signing
keys have different purposes: do not rotate machine keys just because JWKS
changes. Verify a fresh machine-token exchange and a real secrets fetch.

Keep RS256 for sec's verifier. Export the existing `flatRolesClaim` action,
flow/triggers and user grants before migration. Actions V1 code remains in the
4.20.2 source, but source presence is not proof that the production action emits
the expected claim; check newly issued human and machine access tokens.
Adopting Login V2/Actions V2 is a separate migration.

## Rehearsal and cutover

1. While SSO is healthy, determine the current binding with
   `sudo fleet containers place --verify` and confirm the live service with
   `cnt status zitadel`. Record the verified bound host outside SSO-dependent
   storage; historical h001 placement is not authoritative. In every command
   below, substitute that recorded host for `<verified-bound-host>`.
   Placement lookup needs Zitadel machine authentication. Without an explicit
   host, failed registry access falls back to discovery, which refuses when
   hosts are unreachable or multiple copies exist. `--host` avoids relying on
   that discovery fallback; it does not override a different readable binding.
   On the bound host, run `sudo systemctl start fleet-backup-svc@zitadel`
   and check success, then `cnt restore-check zitadel`. Separately,
   `cnt backup zitadel -o ~/backups/` produces a local tar, **not** a restic
   snapshot: for a running container it runs the dump hook, stops for the tar,
   then restarts. Keep the 32-byte masterkey and sec break-glass kit accessible
   without SSO. Record the exact old deployed revision/closure for rollback.
2. Restore the backup to an **isolated** clone, with no production routing or
   outbound notifications. Persist paths on the host are
   `/srv/containers/zitadel/{postgresql,pgdumps,keys,nixos}`. Use a valid database
   dump or a consistent stopped-cluster snapshot; never `cp` a running PostgreSQL
   data directory. Boot the clone with 2.71.7 before testing the upgrade.
3. Rehearse the chosen staged or direct path. Confirm setup completes before
   opening login traffic. Record discovery and its advertised `jwks_uri`
   (`/oauth/v2/keys`, not `/oidc/v1/keys`), key algorithms and IDs, browser login,
   Console access, authorization-code + PKCE, and `flatRolesClaim` in both human
   and machine tokens. Exercise sec UI, sec-agent secrets fetch, oauth2-proxy,
   life and open-webui. A health response alone is not an acceptance test.
4. Immediately before production cutover, take a fresh stopped-cluster archive
   with `cnt backup zitadel -o ~/backups/`, then run
   `cnt stop zitadel --host <verified-bound-host>` to prevent further
   application writes before migration. The command's logical dump
   precedes the stop; its cold cluster archive is the consistent rollback copy.
   If already stopped, the dump hook is skipped. Verify the archive and protect
   the masterkey's permissions. Never copy a live PostgreSQL data directory.
5. Commit and push the tested definition, then deploy the exact revision with
   `cnt deploy zitadel --host <verified-bound-host> --rev <pushed-dotfiles-commit>`.
   This builds on that host by default; no host rebuild is required. For a staged upgrade, deploy,
   verify and soak the separately prepared v3 build first, then this v4 pin.
   Inspect `cnt logs zitadel --unit --no-follow` and `cnt health zitadel`, then
   repeat the functional checks from step 3. Check one sec-agent before
   restarting others. Hydrated caches do not prove token issuance or retrieval.
6. Retain the pre-upgrade database and matching old definition until all checks
   pass. Refresh backups after acceptance, without losing the rollback snapshot.

## Rollback

Use the host recorded while SSO was healthy, not a fresh placement lookup:

```sh
cnt stop zitadel --host <verified-bound-host>
cnt restore zitadel <pre-upgrade-archive> --host <verified-bound-host> --force
cnt deploy zitadel --host <verified-bound-host> --rev <matching-old-commit>
```

`restore` requires the service stopped and preserves the replaced data by
renaming it. Restore the **pre-upgrade database and matching masterkey**,
preserving ownership and permissions, before starting the matching 2.71.7
definition. Do not run 2.71.7 against a v3/v4-migrated database; rolling back
only the Nix generation is insufficient. Any changes made after the snapshot
are lost on rollback. Keep the recorded host, archive, old revision/closure and
SSH access available without SSO. `cnt` here denotes `sudo fleet containers`.
