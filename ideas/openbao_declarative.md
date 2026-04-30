# OpenBao: Declarative Self-Initialization (research notes)

Captured from research done on 2026-04-29 while debugging an
`openbao-apply-config.service` failure caused by OpenBao 2.5.3 disabling
the `sys/generate-root/*` endpoints by default (CVE-2026-5807 /
HCSEC-2026-08).

This file is **not a plan to migrate** — it's a record of what self-init
actually is, why it doesn't fit our current setup, and what would have
to change if we ever wanted to adopt it. The current production fix
deployed on h001 is the dual-listener approach (see
`hosts/h001/mods/openbao/openbao-server.nix`).

## Status / TL;DR

- **Decision (2026-04-29):** Stay with current setup + dual-listener
  fix. Self-init is real and shipping (since OpenBao 2.4.0) but the
  migration cost outweighs the wins for our setup.
- **Hard blockers** for adopting it on h001 today:
  1. Self-init is strictly first-start-only; will not run on an
     already-initialized instance.
  2. Self-init refuses to run on Shamir-sealed instances (which is
     what `storage.file` + on-disk key share gets you, even though it
     feels "auto-unsealed" from systemd's perspective).
- The OSS-recommended pattern is "self-init for the bootstrap, then
  a real IaC tool for day-2 reconciliation" — i.e. self-init does NOT
  replace `openbao-apply-config`, it would only replace the *bootstrap*.

## 1. Background: what we have today (h001)

- OpenBao 2.5.3, `storage.file` at `/var/lib/openbao`
- Sealed with **Shamir** (1-of-1), one key share at
  `/bao-keys/openbao-unseal-1`
- `openbao.service` — the server itself
- `openbao-auto-unseal.service` (oneshot) — reads the share file,
  POSTs to `sys/unseal` on startup
- `openbao-apply-config.service` (oneshot) — the day-2 reconciler:
  uses `bao operator generate-root` to mint an ephemeral root token
  from the unseal share, applies declarative state (policies, auth
  methods, JWT roles, secrets-engine mounts, KV stub keys), then
  revokes the token
- Public exposure: nginx terminates TLS for `sec.joshuabell.xyz`
  and proxies to `127.0.0.1:8200`
- Other hosts (h003, joe, juni, gp3, lio, oren, ...) reach
  OpenBao via vault-agent, get rendered secrets to
  `/var/lib/openbao-secrets/...`

## 2. What "auto-unseal" means in OpenBao vs what we have

What we call "auto-unseal" today is **Shamir + on-disk key share +
systemd oneshot** — operationally hands-free, but architecturally the
instance is still a Shamir-sealed instance.

What OpenBao calls "auto-unseal" is a different thing: a
[`seal` stanza](https://openbao.org/docs/configuration/seal/) in the
server config that delegates barrier-key wrapping to an external
mechanism. Supported seal types:

- `pkcs11` — HSM
- `awskms`, `azurekeyvault`, `gcpckms`, `ocikms` — cloud KMS
- `kmip` — KMIP server
- `static` — a literal key in config or a file (added in 2.4.0)
- `transit` — wrap via another OpenBao instance
- `alicloudkms`

With any of these, no Shamir shares exist; on startup OpenBao calls
the configured seal mechanism to unwrap the barrier key and unseals
itself. `bao operator init` outputs **recovery keys** instead of
unseal keys (used for sensitive operations like generate-root after
init).

The internal predicate self-init checks is
`core.SealAccess().RecoveryKeySupported()` — true only when one of
the above `seal` stanzas is configured. **Our current "shamir + on-disk
key" returns false**, so self-init refuses to run.

## 3. The `static` seal type

OpenBao 2.4.0 (Aug 2025, PR #1425) added a `static` seal type
specifically for the "I want a key on disk" homelab case:

> Add **static key unseal mechanism** to allow auto-unseal in
> environments with explicit trust chaining.

```hcl
seal "static" {
  current_key_id = "key-2026-01"
  # one of:
  current_key      = "<base64-32-bytes>"
  # current_key_file = "/bao-keys/openbao-static-seal.key"
}
```

Functionally similar to what we have today (key on disk, root-owned,
used to unseal at boot), but **architecturally** OpenBao counts this
as auto-unseal. So `static` seal:

- Eliminates `openbao-auto-unseal.service` — bao server unseals itself
- Returns true from `RecoveryKeySupported()` — unlocks self-init
- Has key-rotation semantics (`previous_key_id`/`previous_key`) for
  rolling the seal key without downtime

This is the seal type we'd use if we ever migrated.

## 4. Self-init feature reference

- **Introduced:** OpenBao 2.4.0 (Aug 28 2025), PR
  [#1506](https://github.com/openbao/openbao/pull/1506)
- **Docs:** https://openbao.org/docs/configuration/self-init/
- **Profile system (used by self-init for templating):**
  https://openbao.org/docs/concepts/profiles/

### Config schema

Top-level `initialize "<group>"` blocks containing one or more
`request "<name>"` blocks:

```hcl
initialize "<group_name>" {
  request "<request_name>" {
    operation = "update"        # create | read | update | delete | list | scan | sudo
    path      = "sys/mounts/kv" # NO leading /v1/
    data      = { ... }         # request body
    # Optional:
    token         = "<token>"   # default: ephemeral root, revoked after run
    allow_failure = false
    headers       = { ... }
    when          = true        # set false to skip
  }
}
```

Names match `^[A-Za-z_][A-Za-z0-9_-]*$` and are unique across the
whole file. Multiple `initialize` blocks allowed.

### Sensitive value handling

Inside `data`, any field can be replaced with a templated lookup:

```hcl
data = {
  oidc_discovery_url = {
    eval_source     = "env"
    eval_type       = "string"
    env_var         = "ZITADEL_DISCOVERY_URL"
    require_present = true
  }
  jwt_validation_pubkeys = {
    eval_source = "file"
    eval_type   = "[]string"
    path        = "/run/secrets/zitadel-pubkey.pem"
  }
}
```

This is the **only** place such templating is supported — not in
day-2 API calls.

### Worked example matching our schema

(Hypothetical — would only run on a fresh, auto-unsealed instance.)

```hcl
initialize "secret-engines" {
  request "mount-kv" {
    operation = "update"
    path      = "sys/mounts/kv"
    data = {
      type    = "kv"
      options = { version = "2" }
    }
  }
}

initialize "jwt-auth" {
  request "enable-jwt" {
    operation = "update"
    path      = "sys/auth/zitadel-jwt"
    data      = { type = "jwt" }
  }
  request "configure-jwt" {
    operation = "update"
    path      = "auth/zitadel-jwt/config"
    data = {
      oidc_discovery_url = "https://sso.joshuabell.xyz"
      bound_issuer       = "https://sso.joshuabell.xyz"
    }
  }
  request "role-host-gp3" {
    operation = "update"
    path      = "auth/zitadel-jwt/role/host-gp3"
    data = {
      role_type       = "jwt"
      user_claim      = "sub"
      bound_audiences = ["344379162166820867"]
      token_policies  = ["machine-base", "machines-low-trust", "host-gp3"]
      token_ttl       = "1h"
    }
  }
}

initialize "policies" {
  request "machines-hightrust" {
    operation = "update"
    path      = "sys/policies/acl/machines-hightrust"
    data = {
      policy = <<-EOT
        path "kv/data/machines/high-trust/*" { capabilities = ["read"] }
      EOT
    }
  }
}
```

## 5. The two hard blockers

Both blockers are in `command/server.go`'s `Initialize` function (PR
#1506). Verbatim:

```go
// Initialize performs declarative self-initialization of a production-mode
// OpenBao core. This will exit early if there is no configuration for this
// or if the core is already initialized.
func (c *ServerCommand) Initialize(core *vault.Core, config *server.Config) error {
    if len(config.Initialization) == 0 {
        return nil
    }

    if !core.SealAccess().RecoveryKeySupported() {
        return errors.New("self-initialization requires auto-unseal as there is no way to persist the Shamir's keys")
    }

    ctx := namespace.RootContext(context.Background())

    // Fast path skipping self-initialization if already initialized.
    inited, err := core.Initialized(ctx)
    if err != nil {
        return fmt.Errorf("unable to check core initialization status: %w", err)
    }
    if inited {
        // We refuse to rerun self-initialization as it is a highly privileged
        // way of sidestepping authentication. ...
        return nil
    }
    ...
}
```

### Blocker 1: First-start-only

Author cipherboy on PR #1506 explicitly defended this:

> "explicitly states this is one-time. I don't really want to weaken
> the security model; it would be hard to detect if self-initialization
> was finished except by some other sentinel besides barrier/seal.
> This leads to a problem where, if an existing cluster is upgraded
> with a config that does self-init, it could modify things again,
> which Would Be Bad (TM)."

And the docs reinforce it:

> "The `initialize` stanza specifies various configurations for OpenBao
> to initialize itself **once, on initial startup**. **To repeat the
> operation, remove all storage and re-initialize from scratch.**"

There is **no internal sentinel** for "self-init has finished" separate
from "the storage barrier exists." Once OpenBao has been
`bao operator init`-ed (via self-init OR manually), `inited` is
permanently true unless you wipe `/var/lib/openbao`.

For our existing initialized instance: **adding `initialize` blocks is
a no-op forever.**

### Blocker 2: Requires real auto-unseal

> "self-initialization requires auto-unseal as there is no way to
> persist the Shamir's keys"

Self-init runs as part of the same call that initializes the barrier,
which (for Shamir) returns the unseal shares to the operator on stdout
of `bao operator init`. With self-init there's no operator to receive
them, so OpenBao refuses. The workaround is to use one of the seal
types from §3 (e.g. `static`).

### Other practical limit: no day-2 reconciliation

CHANGELOG, docs, and PR description all converge on:

> "It is suggested to put the **minimal necessary configuration** in
> this and use **a proper IaC platform like OpenTofu** to perform
> further configuration of the instance."

So self-init replaces the **bootstrap**, not day-2 ops. Anything that
changes after first start (new policy, new mount, new JWT role, KV
seeds) still needs an out-of-band reconciler — i.e. our
`openbao-apply-config` would shrink but not disappear.

## 6. Hypothetical fresh-start migration plan

Recorded for future reference. **Not approved for execution.**

### Target end-state

- `seal "static"` block with key at `/bao-keys/openbao-static-seal.key`
- `initialize` stanzas in the server config that bootstrap on day 0:
  - kv-v2 mount at `kv/`
  - jwt auth method at `zitadel-jwt/` + config
  - all baseline policies (`machine-base`, `machines-high-trust`,
    `machines-low-trust`, per-host `host-<name>`)
  - all baseline JWT roles
  - **a long-lived admin token** with policy
    `sys/policy + sys/auth + sys/mounts + kv/* + identity/*`,
    written to `/bao-keys/openbao-admin-token` via a self-init
    `request` that puts it through `eval_source = "file"` (or a
    post-init systemd oneshot that mints+stores it once)
- `openbao-apply-config` rewritten to read the admin token from
  `/bao-keys/openbao-admin-token` instead of calling
  `bao operator generate-root`
- `openbao-auto-unseal.service` deleted (static seal handles it)
- Drop the dual-listener trick from `openbao-server.nix` — the
  `default` listener can keep the post-CVE-2026-5807 default
  (generate-root disabled) since we never call it

### Net architectural changes

- **Removed:** `openbao-auto-unseal.service`, the `listener.admin`
  block, the `/bao-keys/openbao-unseal-*` files
- **Added:** `seal "static"` block, `initialize` blocks, the
  `/bao-keys/openbao-static-seal.key` file, the
  `/bao-keys/openbao-admin-token` file
- **Modified:** `openbao-apply-config` to use a static admin token

### Migration cost (the reason we didn't do it)

1. **Wipe `/var/lib/openbao`.** All KV data is destroyed.
2. **Re-stash every secret currently held.** Roughly the entries
   visible in past apply-config runs:
   - `kv/machines/by-host/gp3/hass_token`
   - `kv/machines/high-trust/atuin-key-josh_2026-03-15`
   - `kv/machines/high-trust/github_read_token_2026-03-15`
   - `kv/machines/high-trust/headscale_auth_2026-03-15`
   - `kv/machines/high-trust/linode_rw_domains_2026-03-15`
   - `kv/machines/high-trust/litellm_public_api_key_2026-03-15`
   - `kv/machines/high-trust/nix2gitforgejo_2026-03-15`
   - `kv/machines/high-trust/nix2github_2026-03-15`
   - `kv/machines/high-trust/nix2nix_2026-03-15`
   - `kv/machines/high-trust/oauth2_proxy_key_file_2026-03-15`
   - `kv/machines/high-trust/openrouter_2026-03-15`
   - `kv/machines/high-trust/openwebui_env_2026-03-15`
   - `kv/machines/high-trust/us_chi_wg_2026-03-15`
   - `kv/machines/high-trust/vaultwarden_env_2026-03-15`
   - `kv/machines/high-trust/zitadel_master_key_2026-03-15`
   - `kv/machines/low-trust/headscale_auth_lowtrust_2026-03-15`
   - `kv/machines/low-trust/rustdesk_password`
   - `kv/machines/low-trust/rustdesk_server_key`
3. **Re-bootstrap Zitadel ↔ OpenBao trust** — audience IDs,
   pubkeys, JWT validation config; possibly re-issue Zitadel keys.
4. **Re-onboard every consumer host** (h003, joe, juni, gp3, lio,
   oren, h001 itself, …). Each runs vault-agent against this
   OpenBao; their auth roles, JWT trust, and rendered secret
   paths all need to come up cleanly.
5. **Plan downtime / fallback.** Rough estimate: 3–5h of focused
   work, plus risk of subtle vault-agent / role-binding regressions
   on consumer hosts.

### What we'd actually win

- One fewer systemd unit (`openbao-auto-unseal`)
- Drop the dual-listener trick
- Drop the CVE-2026-5807 attack surface entirely (we'd never call
  generate-root)
- Cleaner architecture aligned with where OpenBao OSS is heading

### What we wouldn't win

- Day-2 reconciliation **still requires** `openbao-apply-config`
  (or OpenTofu) — self-init is a bootstrap-only feature
- We'd still have a long-lived powerful credential on disk (admin
  token instead of unseal share); equivalent risk surface, just
  different shape

## 7. Cost / risk / value snapshot

| Aspect | Stay (current + dual listener) | Migrate (static seal + self-init + admin token) |
|---|---|---|
| Systemd units for openbao | server + auto-unseal + apply-config | server + apply-config |
| Listener count | 2 (loopback admin + public default) | 1 (public default) |
| CVE-2026-5807 surface | none publicly (admin listener loopback-only) | none (we never call generate-root) |
| Day-2 reconciliation | apply-config + generate-root | apply-config + admin token |
| Secret on disk | unseal share | seal key + admin token |
| Migration cost | 0 | ~3–5h, plus consumer-host churn |
| Reversibility | trivial | hard (would need another wipe to revert) |
| Aligns with OSS direction | partially (dual listener is a workaround) | yes |

## 8. Open questions / future revisit triggers

Revisit this doc if any of these change:

- **OpenBao adds reconciliation/idempotency to self-init** — would
  remove blocker 1 and make adoption strictly an upgrade.
- **OpenBao formalizes a "shamir + key-on-disk" mode** that satisfies
  `RecoveryKeySupported()` — would remove blocker 2 without needing
  to migrate to static seal.
- **We're rebuilding h001 from scratch** for an unrelated reason
  (e.g. impermanence migration per `ideas/impermanence_everywhere.md`,
  hardware swap, or a different host taking over the openbao role).
  At that point the migration cost collapses since we're already
  re-stashing secrets and re-onboarding hosts.
- **A second CVE forces another listener-config workaround** that
  makes the dual-listener pattern noticeably uglier.
- **We add many more consumer hosts** such that re-onboarding cost
  stops being trivial-per-host.

## Key references

- PR #1506 — declarative self-initialization:
  https://github.com/openbao/openbao/pull/1506
- PR #1425 — static seal:
  https://github.com/openbao/openbao/pull/1425
- PR #2912 — CVE-2026-5807 / HCSEC-2026-08, generate-root disabled
  by default: https://github.com/openbao/openbao/pull/2912
- Self-init docs:
  https://openbao.org/docs/configuration/self-init/
- Profile system docs (templating):
  https://openbao.org/docs/concepts/profiles/
- Seal docs (incl. static):
  https://openbao.org/docs/configuration/seal/
- HashiCorp advisory thread for the CVE:
  https://discuss.hashicorp.com/t/hcsec-2026-08-vault-vulnerable-to-denial-of-service-via-unauthenticated-root-token-generation-rekey-operations/77345
- Current production fix: see `hosts/h001/mods/openbao/openbao-server.nix`
  (`listener.admin` block, loopback-only with
  `disable_unauthed_generate_root_endpoints = false`)
