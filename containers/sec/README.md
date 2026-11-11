# sec + zitadel cutover (h001, in place)

Done on h001 on 2026-10-17; kept as the recipe for a re-run or a move.

`containers/zitadel` and `containers/sec` replace h001's old
`containers/zitadel.nix` nspawn container and `mods/sec.nix` unit. The
host-side removal is in the same change, so **deploying the h001 config and
the containers is one window.** Agents keep their hydrated cache, so a short
outage is harmless. Don't delete the old data until both containers work.

Steps marked 🔑 move secret material. Copy it with `cp -a`/`rsync` only;
never print it.

1. Make sure a recent restic snapshot exists, and that the break-glass kit
   (db.key, masterkey) is at hand.
2. On h001, stop the old units. Then take a final dump of the old cluster
   while it is still runnable:
   ```
   nixos-container run zitadel -- systemctl start postgresqlBackup.service
   nixos-container stop zitadel
   systemctl stop sec
   ```
3. 🔑 Copy the data into persist. The postgres cluster is owned by 71:71
   (same uid in the guest). Persist is idmapped, so host uids equal guest
   uids:
   ```
   install -d /srv/containers/zitadel/{postgresql,pgdumps,keys,nixos} /srv/containers/sec/{data,nixos}
   rsync -aHAX /var/lib/zitadel/postgres/ /srv/containers/zitadel/postgresql/17/
   rm -f /srv/containers/zitadel/postgresql/17/postgresql.conf /srv/containers/zitadel/postgresql/17/postmaster.pid
   cp -a /var/lib/zitadel/backups/postgres/. /srv/containers/zitadel/pgdumps/
   cp -a /var/lib/zitadel/masterkey /srv/containers/zitadel/keys/masterkey   # 0444 root, keep as is
   sqlite3 /var/lib/secrets_manager/sec.db ".backup '/srv/containers/sec/data/sec.db'"
   cp -a /var/lib/secrets_manager/db.key /srv/containers/sec/data/db.key     # 0400 root
   chmod 700 /srv/containers/sec/data
   ```
4. Switch h001 to the new config (it drops the old container and unit, and
   NAT for `ve-*`). Then deploy the containers, zitadel first. The default
   repo is forgejo, which needs no SSO; `CONTAINERS_REPO=git+file://…` is
   the fallback.
   ```
   cnt deploy zitadel && cnt deploy sec
   ```
5. Check:
   - `curl -s https://sso.joshuabell.xyz/.well-known/openid-configuration`
   - log in to secrets.joshuabell.xyz/ui
   - `systemctl restart sec-agent` on one host, then on another host
   - log in via life, open-webui, trilium
6. Run restic once (`systemctl start restic-backups-h001`). Check that the
   zitadel hook ran and that `staging/sqlite/sec/data/sec.db` exists.
7. **Done 2026-10-22.** Archived `/var/lib/zitadel` and
   `/var/lib/secrets_manager` to
   `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001, then deleted them.

**Rollback** (order matters):
1. `cnt destroy sec`, then `cnt destroy zitadel`. Do not pass `--purge`.
   `destroy` removes the extra-container units, the nginx snippets and the
   port files, and keeps `/srv/containers/<svc>`. Don't use `cnt stop` here.
   It only disables the unit and leaves its nginx snippet behind, so that
   snippet would clash with the old host vhosts.
2. Then switch h001 to the previous generation
   (`nixos-rebuild switch --rollback`, or the pre-cutover commit). If you
   switch first and stop afterwards, you also stop the restored old
   `container@zitadel`, because it has the same unit name.

The old dirs (`/var/lib/zitadel`, `/var/lib/secrets_manager`) were archived
to `/root/retired-2026-10-22-zitadel-sec.tar.zst` on h001 and deleted on
2026-10-22 (step 7 above). `secrets_manager_hydrated` is unrelated and was
not touched.

## Break-glass kit and cold restore

The kit lives outside the fleet, in the password manager, and holds **keys
only**:

- the restic env (repository, password, backend credentials);
- sec's encryption key, `/srv/containers/sec/data/db.key`;
- zitadel's master key, `/srv/containers/zitadel/keys/masterkey` (32 raw
  bytes, stored base64);
- the emergency ssh key `root_fleet_backup`, whose public half is authorized
  for root on every host by the common `hardening.nix`.

The keys decrypt data but don't contain it. `sec.db` and zitadel's
PostgreSQL state otherwise exist only on the bound host and in the one restic
repository. A second, independent copy of `/srv/containers/sec/data` and
`/srv/containers/zitadel/{pgdumps,keys}` shares neither that repo nor its
credentials (e.g. a second restic repo on h004, or a periodic encrypted
export); without it, a damaged repo plus a lost host means key recovery only,
no restore.

**Cold-restore test**, on a spare host, twice: once from a restic snapshot,
once from the independent copy plus the password-manager keys alone. It
passes when a zitadel login works and a sec-agent fetches its secrets.

## Rauthy 0.37.2 spike

Probed against a throwaway Rauthy 0.37.2 on 2026-11-10 (`pub_url =
localhost:8443`, HTTP on `:8080`, bootstrap roles/client/API key).
**This is a compatibility spike, not a migration.** No production sec,
sec-agent or fleet-edge configuration changed. The separate Zitadel upgrade
is prepared in `containers/zitadel` but has not been deployed; see the
[upgrade guide](../../ideas/zitadel_update.md).

The [Rauthy decision record](../../ideas/rauthy.md) consolidates the identity
model, security tradeoffs and proposed migration. Decision: stay with Zitadel
for now; this section remains the detailed 0.37.2 token-spike evidence.

Version note: the working tree that supplied most source references
reports `0.37.3-20261026-ios-rk-test` (unreleased master), not 0.37.2.
Where they differ, the 0.37.2 binary and the `v0.37.2` tag decided the
answer; each such case is called out below.

### What was actually demonstrated

- `POST {issuer}oidc/token` with `grant_type=client_credentials` and the
  client secret in the **form body** returns an RS256 `at+jwt`.
  `aud` was `["sec-high-trust","344379162166820867"]`, `sub` and `azp`
  were `sec-high-trust`, and the admin-defined claim came out flat as
  `flatRolesClaim:["device_high_trust"]`.
- The signature verifies against `{issuer}oidc/certs` (`kid`
  `ZNx559ku5vcEcKZaTSOGofOW`, 2048-bit) with a plain
  RSASSA-PKCS1-v1_5/SHA-256 check — no Rauthy-specific verifier.
- A throwaway port of sec's verifier checked the signature, RS256 algorithm,
  JWKS key lookup, expiry/time bounds, issuer, project audience, subject and
  roles against the configured Rauthy fixture. This did not run sec itself or
  exercise its replay cache. The existing production Zitadel issuer does not
  match Rauthy's issuer, so the token is not accepted by unchanged production
  configuration, even though its audience includes sec's current project ID.

That is *cryptographic* compatibility only. Rauthy is not a drop-in for
the two paths sec uses today; both need code changes before any cutover.

### Issuer, trailing slash and path

Rauthy's issuer is **not configurable**: `{scheme}://{server.pub_url}/auth/v1/`
(`src/data/src/rauthy_config.rs`). It always carries the `/auth/v1/`
path and a trailing slash, so the best-case issuer is
`https://sso.joshuabell.xyz/auth/v1/`, never the bare
`https://sso.joshuabell.xyz`. sec trims trailing slashes on both sides
(`strings.TrimRight`), so `…/auth/v1/` and `…/auth/v1` compare equal —
but the host and the `/auth/v1` segment must match. Every consumer
hardcodes the Zitadel issuer: `containers/sec/container.nix:20`,
`containers/sec/service.nix:20`, `sec-agent.nix` (`zitadel.issuer`),
`fleet-edge` (`auth.zitadel.issuer`, `zitadel.issuer`), and the DCR at
`/oauth/v2/keys` fallback in sec's `refresh_jwks`.

### Per-client claims: admin API only

`claims` (JSON object, ≤1024 serialized chars), `claims_at_root`,
`allowed_resources` (RFC 8707 allow-list) and `default_aud` are client
fields on the admin API, `PUT /auth/v1/clients/{id}` (`GET` returns
them; the update request needs the full body, including
`confidential`). `claims` are emitted only for `client_credentials`
— there is no user, so nothing else populates them.

- Default is nested: `custom: {flatRolesClaim: [...]}`. With
  `claims_at_root = true` the same keys land at the token root
  (verified both).
- A root key that collides with a reserved claim fails issuance with
  `500` rather than shadowing it; `roles` is reserved, so a machine
  claim **must** be named something like `flatRolesClaim`
  (`src/jwt/src/claims.rs`, `RESERVED_ROOT_CLAIMS`).
- `default_aud` is the only way to get the project id into `aud`
  without a `resource` parameter. Without it `aud` is the bare string
  `sec-high-trust`, which sec's `check_audience` rejects. `resource=`
  works only when `allowed_resources` contains the value, otherwise
  `400 invalid_target` (verified).
- `CLIENT_CREDENTIALS_MAP_SUB=true` is **required**. Default `false`
  omits `sub` entirely (only `azp` remains); sec then falls through
  `sub` → `urn:zitadel:iam:user:id` → `client_id`, none of which
  Rauthy emits, and rejects the login with "token has no subject".

### Bootstrap cannot carry these settings

In 0.37.2 `bootstrap/clients.json` has no `claims`, `claims_at_root`,
`default_aud` or `allowed_resources` — `types.rs::Client` at v0.37.2
stops at `restrict_group_prefix`. Confirmed live: a fresh 0.37.2 given
those keys bootstraps with `claims_at_root=0`, `default_aud=NULL`,
`claims=NULL`, and unknown keys are silently ignored. They must be
applied with an admin API `PUT` after the first start.

`BOOTSTRAP_RECONCILE` (re-apply the bootstrap files on every start)
exists only on unreleased master — CHANGELOG `UNRELEASED` plus
`book/config/bootstrap.md` — and is absent from the 0.37.2 binary,
which has no reconcile path (on an existing DB its startup logs go
straight from migrations to serving). So on 0.37.2 nothing repairs
claim drift. Even upstream's newer `to_entity()` deliberately
*preserves* an existing client's `claims`/`claims_at_root`/
`default_aud`/`allowed_resources` instead of taking them from the
file. Claims survive a restart because hiqlite persists them
(verified: unchanged in `clients` across a restart), not because
bootstrap re-applies them.

Client secrets are stored encrypted in `clients.secret` (blob) with
`secret_kid` pointing at the active `ENC_KEY` entry. A `Plain` secret
from `clients.json` is only used when the database is empty; rotating
one means `PUT /auth/v1/clients/{id}/secret`, which needs a
`Secrets`/`Update` API key (the `Clients`-only key gets `403`).

### Machine auth: client_secret_post only

Rauthy 0.37.2 advertises `token_endpoint_auth_methods_supported =
["client_secret_post","client_secret_basic"]`, but the
`client_credentials` grant bails out with `'client_secret' is missing`
when the secret is only in an HTTP Basic header (verified, both with
and without `scope`). Effectively **`client_secret_post` only**.
`urn:ietf:params:oauth:grant-type:jwt-bearer` is rejected at
deserialization ("unknown variant", listing only the six supported
grants), and adding a `client_assertion` /
`urn:ietf:params:oauth:client-assertion-type:jwt-bearer` pair changed
nothing. So for token requests: **no `private_key_jwt`**. (The
`private_key_jwt` strings in the binary belong to the *dynamic client
registration* validator, not the token endpoint.) That is the hard
blocker for sec-agent, which today mints an RS256 assertion from the
Zitadel machine key (`/machine-key.json`, an RSA private key) and
exchanges it with the `jwt-bearer` grant
(`src/agent.lis:fetch_zitadel_token`).

So the credential model changes materially:

- Zitadel: an RSA private key in `/machine-key.json`, provisioned out-of-band.
  The private key signs assertions locally; it is not sent to the token endpoint.
- Rauthy: a distinct `client_id` and 64-character `client_secret` per host.
  Store them in a root-readable credential file (for example mode `0400`) on
  persisted storage, seeded by the installer or an independent encrypted-secret
  mechanism. **Never place plaintext credentials in Nix expressions or the
  world-readable Nix store.** A JSON file containing those two fields could
  replace `/machine-key.json` after updating its consumers. The shared secret
  is transmitted on each token request, so TLS is required in production.
  sec-agent cannot fetch its own bootstrap credential from sec.

### Roles: user tokens vs machine tokens

User flows (`password`, `authorization_code`) put the user's roles in
a `roles` array and fill `email`, groups etc. `client_credentials` has
no user, so it carries **no `roles`, no `email`, no groups** — the
machine's entitlements have to be re-expressed as a client claim
(`flatRolesClaim`, root-emitted) whose values still match the
`device_high_trust` / `device_low_trust` role grants in
`containers/sec/registry.nix`. Zitadel got there with an Actions V1
script; Rauthy does it as static per-client configuration, which is
closer to the registry's own model but has to be re-provisioned per
host and cannot express anything dynamic (no Zitadel "project roles"
scope, no org/project claims, no `urn:zitadel:iam:*` claims at all).

### Still required before a real cutover

- `sec`: migrate issuer/claim configuration and verify discovery/JWKS endpoint
  handling with the real server. Exercise replay-cache behavior and the human
  login flow end to end; a verifier port is not that integration test.
- `sec-agent`: replace `jwt-bearer` + machine key with
  `client_credentials` + per-host secret, and change what is seeded
  on disk.
- `fleet-edge`: `auth.zitadel.issuer` / `projectId` options and the
  `flatRolesClaim` default, plus whatever validates `aud`.
- Host onboarding docs and the break-glass kit: provision the per-host client
  credential in place of the old machine key at cutover. Retain the old key
  securely only for the rollback window, not as a permanent dual-auth scheme.

### Source references

- Rauthy [v0.37.2 release](https://github.com/sebadob/rauthy/releases/tag/v0.37.2)
  ([CHANGELOG](https://github.com/sebadob/rauthy/blob/v0.37.2/CHANGELOG.md)).
- Client claims: [PR #1604](https://github.com/sebadob/rauthy/pull/1604);
  RFC 8707 resource indicators / `default_aud` in the same release.
- Bootstrap format and the forthcoming reconcile:
  [bootstrap docs](https://sebadob.github.io/rauthy/config/bootstrap.html)
  ([source](https://github.com/sebadob/rauthy/blob/v0.37.2/src/data/src/migration/bootstrap/types.rs)).
- Issuer construction:
  [`rauthy_config.rs`](https://github.com/sebadob/rauthy/blob/v0.37.2/src/data/src/rauthy_config.rs);
  auth methods:
  [`well_known.rs`](https://github.com/sebadob/rauthy/blob/v0.37.2/src/data/src/entity/well_known.rs);
  grant handling:
  [`client_credentials.rs`](https://github.com/sebadob/rauthy/blob/v0.37.2/src/service/src/oidc/grant_types/client_credentials.rs).
