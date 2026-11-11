# Rauthy evaluation and possible migration

## Questions to answer before deciding

- [ ] **What problem am I solving?** Is simpler administration and lower resource
  use worth changing the system that authenticates access to fleet secrets?
  Would a maintained Zitadel with unused features left disabled be sufficient?
- [ ] **Will I operate Rauthy better?** Will its simplicity actually produce faster
  security updates, fewer mistakes and more reliable restores, rather than just
  a nicer UI?
- [ ] **Am I comfortable with concentrated maintenance?** Rauthy and its embedded
  Hiqlite dependency rely heavily on the same lead maintainer. What would I do
  if that person could not ship an urgent fix?
- [ ] **Can I keep following current releases?** The reviewed Rauthy security
  policy promises neither LTS releases nor security backports. Can I rehearse
  upgrades promptly even when a security fix requires adopting other changes?
- [ ] **Do I accept the machine-credential tradeoff?** Our tested Rauthy path uses
  a per-host shared client secret sent over TLS, rather than Zitadel's locally
  signed assertions whose private key never leaves the machine.
- [ ] **How declarative must this be?** Am I willing to own an API-based
  provisioning service, its privileged credential, drift handling and deletion
  policy? Bootstrap JSON alone is not ongoing management in 0.37.2.
- [ ] **Are global roles/groups sufficient?** Do I need project-scoped grants or
  client-specific role isolation, or are namespaced flat memberships adequate?
- [ ] **Can I recover without this IdP or sec?** Are encryption keys, machine
  bootstrap credentials, backups and emergency SSH access available independently?
  Can I prove a cold restore and a new machine's first secret fetch?
- [ ] **What is the identity/account migration plan?** How will each app map new
  `(issuer, subject)` identities to existing data? Will users need password resets
  or passkey re-enrollment? Which apps cannot safely be moved one at a time?
- [ ] **How much outage and rollback complexity is acceptable?** Can I tolerate
  forced re-login and a bounded cutover window? What writes or new identities
  would be lost or need reconciliation after rollback?
- [ ] **Which features will remain out of scope?** In particular, can PAM/Linux
  login management, extra identity providers, dynamic registration and unused
  grant types stay out of the first deployment?
- [ ] **What evidence would make me confident enough?** Require real sec fetches,
  denial tests, browser login, revocation/rotation and restore drills—not merely
  a valid JWT or a successful health check. Recheck advisories and capabilities
  for the exact version selected at the time.

## Decision and scope

**Decision: stay with Zitadel for now.** Keep it maintained; use
[the Zitadel upgrade plan](zitadel_update.md) for that work. The Rauthy evaluation
is not authorization to deploy a replacement or change production authentication.

This note consolidates the November 2026 discussion and Rauthy **0.37.2** spike.
It separates observed behavior, versioned source/documentation findings, and a
proposed migration that has **not** been implemented. Detailed token experiments
are also recorded in [sec's spike notes](../containers/sec/README.md#rauthy-0372-spike).

The reasons to consider Rauthy are simpler administration, a smaller deployment
and a model closer to our needs: human login, app SSO and machine access to sec.
It is not justified to claim its code is safer merely because it is smaller or
written in Rust. The security-first preference from this evaluation was maintained
Zitadel, particularly for maintenance depth and asymmetric machine authentication.
Rauthy remains a credible simplicity-first option if we accept its tradeoffs.

## What was tested, and what was not

### Version discipline

The tested executable reported **0.37.2**. The `/tmp/rauthy` source checkout used
in some initial investigation reported **0.37.3-20261026-ios-rk-test**, an
unreleased version. Runtime evidence and the `v0.37.2` source tag take precedence.

A material correction: `BOOTSTRAP_RECONCILE` existed in the newer checkout, not
in the tested 0.37.2 binary. Claims surviving a restart demonstrated persistence,
not reconciliation. Do not rely on unversioned documentation describing newer
features when designing against 0.37.2.

### Observed machine-token behavior

A disposable Hiqlite-backed instance bootstrapped roles, a client and an API key.
The test client was named `sec-high-trust`; this was a fixture, **not** the proposed
production scheme of sharing one credential among high-trust hosts.

- `client_credentials` with `client_secret_post` returned HTTP 200 and an RS256
  `at+jwt`. Its signature verified against the advertised JWKS.
- The token contained `sub` and `azp` = `sec-high-trust`, audience
  `["sec-high-trust", "344379162166820867"]`, a 300-second test lifetime, `jti`,
  and root-level `flatRolesClaim: ["device_high_trust"]`.
- A throwaway port of sec's verifier checked signature, key lookup, algorithm,
  time bounds, issuer, audience, subject and roles. It was **not the real sec
  server**, and did not exercise sec's replay cache or retrieve secrets.
- The unchanged production issuer rejects this token. Its audience included
  sec's existing project ID; that alone does not make it a production credential.
- Machine tokens have no human `roles`, email or groups. Their entitlements came
  from administrator-controlled client custom claims.
- The default `CLIENT_CREDENTIALS_MAP_SUB=false` omits `sub`; setting it to
  `true` was necessary for compatibility with sec's subject extraction.
- Discovery advertised both Basic and POST client-secret authentication, but
  the tested client-credentials flow rejected a Basic-only secret as missing.
  Use the **observed `client_secret_post` behavior**, not discovery alone.
- JWT-bearer grant requests were rejected. Supplying a client assertion did not
  provide a working `private_key_jwt` alternative.
- Root custom claims colliding with reserved fields such as `roles` failed token
  issuance rather than overriding those fields.

### Verification limits

No Rauthy production migration, real sec integration, fleet machine bootstrap,
account linking, TLS/proxy deployment, PAM integration or restore drill was done.
The exploration server's admin page and discovery returned HTTP 200, but browser
automation could not connect; successful interactive admin login was not verified.
The Zitadel HTTP login/migration tests are separate evidence and do not establish
Rauthy browser-flow compatibility.

### Retained playground

At the last restart, the supervised service `rauthy-playground-local` was left
running on **lio**, with `/tmp/rs` as its working directory and retained database.
This is historical state, not a promise that it is still running when reading this
note. It is not installed as a boot service, and `/tmp` is not durable storage.

- Admin UI: `http://localhost:8080/auth/v1/admin`
- Account UI: `http://localhost:8080/auth/v1/account`
- Test admin: `admin@spike.local`; the initial password is in `/tmp/rs/serve.log`
  just after the first-time setup message near line 137. It may have been changed
  during subsequent exploration. Do not copy passwords or tokens into this repo.
- Remote access: `ssh -N -L 8080:127.0.0.1:8080 josh@lio`, then use the same URL.
- HTTP, Raft and Hiqlite API were bound to loopback on 8080, 8100 and 8200.
  Startup used `CLIENT_CREDENTIALS_MAP_SUB=true`,
  `HQL_LISTEN_ADDR_API=127.0.0.1` and `HQL_LISTEN_ADDR_RAFT=127.0.0.1`.
- Earlier token experiments advertised `http://localhost:8443/auth/v1/` while
  serving HTTP on 8080. The playground was corrected to `localhost:8080` in both
  `server.pub_url` and `webauthn.rp_origin`; old tokens therefore have an old issuer.
- `/tmp/rs` contains test API keys, encryption material and tokens. Treat it as
  sensitive test state, not a production template. Never publish its contents.

## Identity model: how our configuration would map

### Clients, projects and audiences

A Rauthy client maps most closely to a **Zitadel application**, not a project.
There is no need to recreate the surrounding Zitadel project hierarchy.

| Existing use | Proposed Rauthy object |
| --- | --- |
| Open WebUI login | `open-webui` OIDC client |
| Life web and native login | Separate `life-web` and `life-native` clients |
| Shared oauth2-proxy | One `oauth2-proxy` client; retain per-service proxy authorization |
| sec browser UI | `sec-web` client |
| sec-agent on h001 | `sec-agent-h001` machine client |
| sec-agent on lio | `sec-agent-lio` machine client |

Human clients use authorization code with S256 PKCE; whether a client also has a
secret depends on whether it can keep one confidential. Machine clients allow
client credentials and do not need interactive login flows.

The **client** is who requests the token; the **audience** is the API intended to
accept it. Multiple host clients can request tokens for the same sec audience
without sharing credentials. The spike retained sec's numeric project ID as an
audience for compatibility. A future cutover could use a stable API identifier,
but both issuer and verifier must agree; do not weaken audience checking.

One distinct client per host gives individual identity, rotation and revocation.
Hosts with identical permissions should still have different secrets.

### Scopes versus claims

Scopes describe requested/allowed access or information. Claims are assertions
actually placed in a token: requesting `email` can yield an `email` claim; it is
not the email value itself. Creating a scope named `admin` does not independently
grant administration rights—an application must enforce a meaningful policy.

Rauthy configures allowed and default scopes per client. Custom scopes map user
attributes into claims, with per-client scope permission. Standard `openid`,
`profile`, `email` and, where needed, `groups` should cover most initial needs.

Versioned 0.37.2 source showed that human roles are emitted in access and ID tokens
without a special `roles` scope. Groups are emitted in access tokens and userinfo
when the `groups` scope is present; the inspected ID-token builder does not emit
groups. Check which artifact each relying party actually consumes.

### Roles versus OIDC groups

Both are **flat, instance-wide user memberships**, not project/client-scoped role
grants. Roles can represent application entitlements such as `life-admin`,
`notes-user` or `sec-admin`. Namespace app-specific names to avoid collisions;
namespacing does not isolate them from other clients receiving role claims.

Groups can represent cohorts and also drive Rauthy's built-in client admission
rule, `restrict_group_prefix`. A client configured with prefix `app-life-` admits
a user belonging to, for example, `app-life-users`. It is a **starts-with check**,
not exact group equality. Choose prefixes carefully.

This rule gates client authorization; it does **not** filter unrelated group
claims out of tokens. There is no `restrict_role_prefix` in the inspected 0.37.2
client model. Applications must still enforce their own permissions after login.

Proposed convention: retain roles for app permissions, use groups where IdP-level
login gating is useful, and do not duplicate every membership in both systems.
Human roles and machine client claims need an explicit, tested normalization
contract in sec; do not assume every token will contain `flatRolesClaim`.

### PAM is a separate project, not the machine-token mechanism

PAM (Pluggable Authentication Modules) handles Linux authentication. Rauthy's NSS
integration resolves Linux users, groups and hosts over the network.

- A PAM user links to an existing Rauthy human user and adds Linux identity data
  such as username and UID. It follows the human account's lifetime.
- PAM groups are separate from OIDC groups and govern Linux membership/access.
- PAM hosts authenticate to dedicated PAM endpoints with a host ID and secret.
  They are **not OAuth machine clients** for accessing sec.

Our sec-agents would be client-credentials clients, not PAM hosts or human users
with special passwords. Keep PAM/Linux SSH authentication outside the initial
migration. Adding it would increase both trust and availability dependence on the
IdP and requires separate lockout/recovery testing.

## Machine credentials and custom claims

For each host, the proposed configuration includes a confidential client, its
allowed client-credentials flow, sec audience and administrator-defined permission
claims. The tested API exposes these via `PUT /auth/v1/clients/{id}`; it expects
a full update body rather than a small partial patch.

Relevant fields:

- `claims`: JSON object, at most 1024 serialized characters in the tested version.
- `claims_at_root=true`: emits `flatRolesClaim` at the root; otherwise it is
  nested beneath `custom`.
- `default_aud`: includes sec's expected audience without a request `resource`.
- `allowed_resources`: allow-list for explicit resource indicators; unapproved
  `resource` requests returned `invalid_target`.
- `CLIENT_CREDENTIALS_MAP_SUB=true`: maps the machine client ID to `sub`.
- RS256 signing for compatibility with the current sec verifier.

Client claims live in Rauthy's database and persist across restarts. They cannot
be populated by the 0.37.2 bootstrap client schema: unsupported keys were silently
ignored in a fresh-instance test. They need an admin API update after bootstrap.
The newer checkout's reconcile logic also preserved existing claim settings rather
than deriving them from bootstrap JSON; re-evaluate future releases individually.

Zitadel's `/machine-key.json` holds an RSA private key used to sign assertions
locally. Rauthy's tested equivalent would instead be a protected file containing
`client_id` and a 64-character `client_secret`, read by an updated sec-agent.
Store it root-readable, e.g. mode `0400`, on persisted storage and provision it
out-of-band. **Never put plaintext credentials into Nix expressions or the
world-readable Nix store.** sec-agent cannot obtain its own bootstrap credential
from sec: it needs that credential to make the first request.

Rauthy stores client secrets encrypted, with `secret_kid` identifying the relevant
encryption key. Secret rotation uses a separate client-secret API and needs
`Secrets/Update` permission, not just client-update permission. Encryption at rest
does not remove the need to protect the running server and its encryption keys.

Shared-secret client authentication over TLS is standard, but it changes risk:
the long-lived secret is transmitted on each exchange, unlike the private key in
the assertion flow. Root compromise can steal either host credential. Prevent
secret-bearing request bodies from entering proxy, application or debug logs.

## Declarative NixOS management

The inspected guest nixpkgs pin supplied an older Rauthy package (0.35.2) and **no
`services.rauthy` module**. This was a finding about that pin, not a claim about all
future nixpkgs versions. The spike used a separately built 0.37.2 package.

A production implementation would have two layers:

1. **NixOS/container configuration:** pinned package, service user, runtime TOML,
   secret files, private networking, TLS proxy, persistent storage and backups.
2. **Database object provisioning:** desired clients, roles, groups and managed
   memberships applied through the management API.

Bootstrap JSON can initialize an empty database. In 0.37.2 it does not reconcile
subsequent changes; changing JSON and rebuilding does not update live objects.
The API-based provisioner is proposed work, not an existing implementation.

Its contract should be explicit:

- Idempotently create/update managed objects and apply machine claims/audiences.
- Check resulting live state and fail visibly on incomplete provisioning.
- Deliberately remove stale managed objects without deleting unrelated UI-created
  objects. Define how UI edits to managed objects are treated.
- Preserve runtime account state: passwords, passkeys and sessions are not reset
  on every deployment. Define which memberships are declaratively owned.
- Use least-privilege runtime API credentials, an explicit rotation policy and
  no secrets in Nix derivations or logs. Bootstrap and ongoing credentials may
  have different lifetimes and permissions.
- Test denied grants and removals as well as successful creation. Provisioning
  is security-sensitive code with authority over the entire authentication model.

Rauthy's own encryption keys, provisioning access and host bootstrap credentials
must be recoverable without depending exclusively on sec. Back up both database
state and required encryption keys; Nix configuration does not reconstruct human
credentials, passkeys or all runtime state.

## Security and project-continuity assessment

This is an evidence-based comparison, **not a full code audit** of either current
release. No numeric security score or claim that one implementation is proven
safer is justified. Advisory counts alone are not comparable: exposure, scrutiny,
feature breadth and disclosure practices differ.

### Evidence in Rauthy's favor

The public 0.32-era Radically Open Security source-assisted audit was performed
in July–August 2025. It described security-conscious design, minimal unsafe Rust,
and a well-managed project that addressed most reported issues within hours.
It found one elevated, three low and three N/A-severity issues, including stored
SVG XSS, secret comparison timing and a Hiqlite panic. Findings and fixes are
publicly documented. This is stronger evidence than an unsupported claim of
being secure by design.

Limits: this was one version and one engagement. The report recommended targeted
additional audits of **Hiqlite and PAM**, which were not covered as full component
audits. It does not establish the safety of every later feature.

Recent Rauthy disclosures also revealed core security-invariant failures:

| Failure | Fixed version | Relevant lesson |
| --- | --- | --- |
| Refresh token not bound to redeeming client | 0.36.1 | A JWT rewrite lost a client-binding check; token theft could cross client boundaries |
| Unauthenticated malformed token input could abort the process | 0.36.2 | Safe Rust still permits logic-driven denial of service |
| Authorization code not bound to original redirect URI | 0.37.0 | Protocol bindings matter even with mitigating PKCE/client authentication |

All three fixes precede the 0.37.2 spike. They are engineering-history evidence,
not a claim those specific flaws remain exploitable in the playground. Neither
this list nor the old audit replaces checking advisories before any future deploy.

### Zitadel's strengths and weaknesses

Zitadel reports annual third-party penetration testing and organizational security
attestations. Public advisories credit independent testers. Its organizational
capacity and broader maintenance base are advantages, but SOC 2/ISO 27001 do not
prove a self-hosted binary's authentication logic correct; restricted reports were
not inspected during this evaluation.

Zitadel has also disclosed serious logic/design bugs, including premature MFA
session authentication and external-IdP intent tokens without authenticated
integrity protection. The latter was fixed in 4.17.3 and required external-IdP
flows; deployments without those providers were outside that advisory's scope.
Its broad APIs, event store/projections and login generations create real
complexity. Retaining Login V1 avoids adding the separate Login V2 process now.

Rust versus Go is not decisive: both backend languages are largely memory-safe.
The dangerous failures here include wrong-client token acceptance, incorrect MFA
state, account linking, recovery, authorization checks and resource exhaustion.
Neither language prevents those.

### Simplicity and attack surface

Simpler administration can reduce configuration mistakes and make updates more
likely. However, fewer UI concepts, fewer processes and less reachable code are
three different things. Rauthy still includes many OAuth flows, federation,
registration/recovery, PAM integration and embedded storage/clustering machinery.
Some complexity moves inside its binary rather than disappearing.

Unused features reduce exposure only when genuinely disabled or unreachable;
not clicking a UI tab is not a security boundary. A narrow deployment should
avoid unneeded registrations, grant types and integrations, and keep management
and storage endpoints appropriately isolated. Verify which endpoints must remain
public for ordinary account/login functionality rather than guessing proxy blocks.

PostgreSQL costs operational work but has a broad independent ecosystem. Hiqlite
reduces external service management but adds reliance on a smaller storage project.
The custom Nix/API provisioner must be included in Rauthy's trusted computing base.

### Bus factor and maintenance policy

Lower bus factor means more dependence on a few people, not worse code by
necessity. The contribution snapshot reviewed in November 2026 attributed about
91% of Rauthy commits and 87% of Hiqlite commits to the same lead maintainer.
Zitadel had multiple contributors with hundreds of commits and a much broader
population. Counts include bots, depend on GitHub attribution and are historical
proxies—not measurements of current release permissions or security expertise.

Concentration matters because illness/burnout can delay urgent fixes and affect
both the identity service and its storage dependency. It can also limit independent
review. A coherent single-maintainer design can still be excellent.

The reviewed Rauthy security policy states **no LTS releases and no security
backports** while below v1. Staying secure requires moving forward to newer
releases. Zitadel instead brings corporate funding, roadmap and business-policy
risk; a larger team does not eliminate dependence on the company.

For this fleet, the IdP controls entry to secrets, not merely a convenience login.
Outage affects bootstrap and fresh retrieval; a serious authentication compromise
could expose secrets within the identities/permissions sec accepts. Backups aid
recovery but cannot undo secret disclosure. Treat maintenance continuity and
patchability as major factors, not just resource consumption.

## What a migration would involve

### 1. Inventory and freeze the intended contract

Before implementing, enumerate actual consumers from configuration and the live
Zitadel instance. Earlier discussion assumed one project, but source configuration
showed distinct project IDs for sec/fleet and Life; do not collapse this distinction
without checking the deployed state.

Record clients, redirects/logout URLs, scopes, grants, role mappings, audience
checks, signing algorithms, lifetimes, subject-based account bindings and recovery
methods. Export the existing Actions V1 `flatRolesClaim` script and triggers.
Include sec, every sec-agent, Life web/native, Open WebUI, oauth2-proxy and its
protected routes (including Trilium), fleet-edge, and any other issuer consumers
found at implementation time. The list here is a starting point, not an exhaustive
live inventory.

Choose final issuer, API audience identifiers, human/machine claim normalization,
and credential paths before writing integrations. Require exact issuer and
intended audience checks; do not make verification permissive to ease migration.

### 2. Deploy alongside Zitadel, without taking over its hostname

Use a distinct hostname and isolated production-like container for Rauthy first.
The inspected issuer construction is `{scheme}://{pub_url}/auth/v1/`, including
the path and trailing slash. Reusing `sso.joshuabell.xyz` later would still change
the issuer from Zitadel's bare origin; this is not a transparent DNS cutover.

Use discovery for token, userinfo and JWKS endpoints, not Zitadel-specific paths
such as `/oauth/v2/keys`. sec trims trailing slashes, but other consumers may
compare exactly. Preserve the advertised issuer rather than relying on every
consumer to normalize it identically.

Pin an assessed release; provision real runtime secrets, persistence and backups.
Do not promote the `/tmp/rs` test database or its credentials to production.
Select Hiqlite versus PostgreSQL based on verified restore/operations needs;
no production storage choice was made by the spike.

### 3. Provision users and applications

Implement the declarative contract above. Map human identities to application
accounts explicitly: new Rauthy subjects are not old Zitadel subjects, even when
email addresses match. Do not enable unsafe automatic email-based account linking
to bypass migration work. Password-hash import and passkey portability were not
established; plan a verified import or deliberate reset/re-enrollment procedure.

Configure human login clients, PKCE, MFA requirements, exact redirects, roles and
needed group restrictions. Verify app-specific token expectations before moving
users; human `roles` and machine `flatRolesClaim` are not interchangeable by default.

### 4. Implement and prove machine access to sec

Update the secrets-manager source and its Nix modules, then pin the tested revision
in the consuming configuration. Relevant existing touchpoints include:

- [sec configuration](../containers/sec/container.nix) and
  [service dependencies](../containers/sec/service.nix): issuer, audience/project,
  role extraction, discovery/JWKS handling, browser login and routing dependencies.
- [Shared sec-agent configuration](../hosts/_shared_assets/utilities/sec-agent.nix):
  replace the JWT-bearer machine-key contract with client credentials.
- Host installers, persistence declarations and recovery instructions: provision
  the new file before the first sec request, with correct ownership/mode.
- [Fleet-edge source](../flakes/fleet-edge): review Zitadel-specific settings,
  token acquisition/verification and role assumptions, not just issuer strings.
- [oauth2-proxy configuration](../hosts/h005/oauth2-proxy.nix): update issuer,
  client credential, scopes and human role/group claim mapping.

Prove the real sec server accepts intended tokens and rejects wrong issuer,
audience, subject/role, expiry and signature. Exercise replay behavior, renewal,
revoked credentials and least-privilege access. A populated hydrated cache must
not hide an inability to fetch fresh secrets.

If sec temporarily accepts two issuers to stage host migration, implement this as
an explicit bounded transition: separate trusted issuer/JWKS/audience policies
and tested subject/role mappings, not a signature-key union or relaxed checks.
Alternatively use a coordinated machine cutover window. Choose based on tested
capabilities; dual-issuer support was not implemented by this evaluation.

### 5. Cut over applications and hosts in controlled groups

Move browser apps individually where possible, checking existing data ownership,
roles, logout and re-login. Move one low-risk host's sec-agent before fleet-wide
changes. Verify a cold/new host can get its first secrets and join the tailnet
without relying on an already working cache or the retiring provider.

Expect new sessions and user re-authentication. Test secret rotation and revocation;
revoking a client secret does not necessarily invalidate already-issued JWTs at a
resource server doing local validation. Define acceptable token lifetime and any
required immediate-revocation mechanism rather than assuming it.

### 6. Acceptance, rollback and retirement

Acceptance requires:

- Real browser login and account linking for every affected app, including native
  callbacks where relevant; MFA and recovery are exercised, not just configured.
- Real sec UI access and machine retrieval, with both allowed and denied secret
  paths checked for representative high-/low-trust identities.
- Wrong-issuer/audience and invalid/revoked credential cases fail as intended.
- Provisioning changes and removals converge without resetting runtime user state.
- Cold restore from backups plus independent keys; emergency access works without
  either IdP, and normal access works again after recovery.
- No accidental public Hiqlite/PAM/management exposure or secret-bearing logs.

Before each cutover, keep a verified backup and the exact working provider and
consumer configurations. Preserve old Zitadel machine keys securely for the
rollback window. Restoring only DNS is insufficient: issuer, client IDs/secrets,
claim mappings and application account links may all have changed.

Rollback must restore the matching provider/consumer configuration and account
mapping state. Document what post-snapshot writes or newly created accounts would
need reconciliation; do not blindly overwrite application databases. Only after
acceptance remove temporary dual-issuer paths, old credentials, obsolete Zitadel
configuration and dependencies. Do not leave a permanent compatibility layer by
accident. Archive the required recovery material before retiring the old service.

## Sources and evidence boundaries

Primary references reviewed during the evaluation; recheck current versions and
policies before acting:

- [Rauthy v0.37.2](https://github.com/sebadob/rauthy/releases/tag/v0.37.2) and
  [versioned changelog](https://github.com/sebadob/rauthy/blob/v0.37.2/CHANGELOG.md).
- [Custom scopes and client claims](https://sebadob.github.io/rauthy/work/custom_scopes_attributes.html),
  [bootstrap documentation](https://sebadob.github.io/rauthy/config/bootstrap.html),
  and [0.37.2 bootstrap types](https://github.com/sebadob/rauthy/blob/v0.37.2/src/data/src/migration/bootstrap/types.rs).
  The live documentation can describe a different version.
- [0.37.2 token construction](https://github.com/sebadob/rauthy/blob/v0.37.2/src/service/src/token_set.rs),
  [client group admission](https://github.com/sebadob/rauthy/blob/v0.37.2/src/data/src/entity/clients.rs#L1687-L1701),
  and [client API fields](https://github.com/sebadob/rauthy/blob/v0.37.2/src/api_types/src/clients.rs).
- [PAM overview](https://sebadob.github.io/rauthy/work/pam.html),
  [versioned PAM user model](https://github.com/sebadob/rauthy/blob/v0.37.2/book/src/work/pam_users.md),
  and [PAM/NSS implementation](https://github.com/sebadob/rauthy-pam-nss).
- [Rauthy public security audit](https://raw.githubusercontent.com/sebadob/rauthy/main/assets/security_audit_report_v0.32.pdf)
  and [security/support policy](https://github.com/sebadob/rauthy/security/policy).
- Rauthy advisories: [refresh-token client binding](https://github.com/sebadob/rauthy/security/advisories/GHSA-7qh2-3hc5-2vqp),
  [process-abort DoS](https://github.com/sebadob/rauthy/security/advisories/GHSA-wx92-7mmw-5x82),
  [authorization-code redirect binding](https://github.com/sebadob/rauthy/security/advisories/GHSA-55g7-fq48-7mr4).
- Zitadel [assurance claims](https://help.zitadel.com/security-compliance/certifications-and-compliance),
  [MFA advisory](https://github.com/zitadel/zitadel/security/advisories/GHSA-cfjq-28r2-4jv5),
  and [external-IdP intent advisory](https://github.com/zitadel/zitadel/security/advisories/GHSA-jh3m-cr2x-qp88).
- Contribution data: [Rauthy](https://api.github.com/repos/sebadob/rauthy/contributors?per_page=100),
  [Hiqlite](https://api.github.com/repos/sebadob/hiqlite/contributors?per_page=100),
  [Zitadel](https://github.com/zitadel/zitadel/graphs/contributors). These are mutable
  historical contribution views, not audits of maintainer availability.

Licensing was part of the original motivation, but free/open-source status and
operational security are separate questions. This evaluation did not produce a
complete version-by-version licensing review of both products and dependencies;
verify the selected release's license if that is a deciding requirement. Likewise,
we did not establish a full code-size comparison, current vulnerability inventory,
maintenance response-time SLA or comprehensive security audit of either release.
