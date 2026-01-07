- Create machine in zitadel and generate a key. Put that at /machine-key.json
- sudo chmod

## CLI

If `ringofstorms.secretsBao.enable = true`, you also get a `sec` helper.

It reads `/run/openbao/*` files, so it will `sudo` itself if needed.

- `sec <kv-path> [field]` reads a field (default: `value`) from KV v2.
- It reuses `/run/openbao/vault-agent.token` when available, otherwise it logs in via the same jwt auth mount path using `/run/openbao/zitadel.jwt`.

Example:

- `sec machines/home_roaming/test value`
