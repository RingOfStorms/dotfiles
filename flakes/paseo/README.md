# Paseo on bare-metal NixOS

This flake builds the pinned Paseo daemon plus a Nono provider launcher. Its NixOS module runs Paseo as an existing user rather than in a container. The daemon and provider isolation are separate: providers default to Nono, while explicitly trusted agent profiles can run directly with host-user access and receive Paseo tools.

## Outputs

- `packages.<system>.paseo` (`default`): pinned upstream Paseo with the patches in `patches/` and `procps` on the service PATH.
- `packages.<system>.nono`: pinned Nono CLI build.
- `nixosModules.default`: bare-metal NixOS module. Set `services.paseoBareMetal.enable = true`.
- `nixosModules.upstream`: upstream `services.paseo` module imported by the bare-metal module.
- `lib.mkProviderLauncher { pkgs, nonoPackage ? ... }`: fixed mandatory Nono launcher executable.

## Host configuration

```nix
inputs.paseo.url = "path:../../flakes/paseo";
inputs.paseo.inputs.nixpkgs.follows = "nixpkgs";

services.paseoBareMetal = {
  enable = true;
  user = "josh";
  home = "/home/josh";
  catalogWorkdir = "/home/josh/projects"; # Existing, writable project root used for global Settings catalogs.
  port = 6767;
  environmentFile = "/var/lib/secrets/paseo.env";
};
```

The module sets a boot-starting `services.paseo` unit that survives logout and binds only to `127.0.0.1` by default (use `http://localhost:6767` on the host). On lio, it binds to `0.0.0.0` so both localhost and the tailnet IP work; only `tailscale0` permits incoming port 6767, not the LAN. Use `http://100.64.0.1:6767` on the tailnet. The lio config advertises this URL via `baseUrl`. `PASEO_HOME` remains `~/.paseo`. `catalogWorkdir` must be an existing writable directory listed in `projects`; it is used for global Settings model discovery, while workspace discovery uses the selected workspace cwd. Global discovery is still wrapped by Nono with only that exact project directory as `--workdir` and `--allow`. Existing project directories are never created, chowned, or chmodded. The service gets a minimal PATH; provider binaries are fixed store paths behind the Nono launcher. `inheritUserEnvironment = false` keeps host-wide CLI aliases and user PATH from changing normal shell behavior.

When `proxy.domain` is set, the daemon allowlists that host, trusts loopback for forwarded proto, permits only the matching browser origin and uses the HTTPS URL as `app.baseUrl` unless `baseUrl` is explicitly set. The host reverse proxy remains responsible for TLS and access controls. Do not expose workspace service subdomains: they are unauthenticated.

## Security boundary

Paseo runs as the existing host user with the normal home, git identity, SSH agent, `~/.omp`, and XDG defaults. Its daemon terminals remain ordinary host terminals by design; Nono wraps provider processes only. Do not expose `paseo` on a wildcard workspace-service hostname.

The package exposes only the built-in OpenCode and OMP providers. Other built-ins, custom/derived providers, plugins, and provider-side ACP filesystem/terminal operations remain disabled. OpenCode servers and OMP RPC processes default to `nono run`; catalog probes always use Nono. The launcher selects the existing Nono profile by trusted provider ID and requires the daemon's absolute launcher path and exact session cwd. Missing profiles fail closed for sandboxed launches. Both launch modes retain the pinned runtime and protected environment settings.

The selected profiles are the user's existing files: OpenCode uses `~/.config/nono/profiles/opencode.json`; OMP uses `~/.config/nono/profiles/omp.json`. They are not modified by Nix. Their current grants are broader than the per-agent workdir: OpenCode allows read/write access to `~/.opencode`, `~/.config/opencode`, `~/.cache/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.local/share/opentui`, and `$TMPDIR`, and read access to the configured Tempus/Okta paths. OMP allows read/write `~/.omp`, all of `~/.cache`, and `$TMPDIR`, plus read-only `~/.gitconfig`. Both allow outbound networking and set `workdir.access` to `readwrite`. The launcher adds only the exact agent cwd; it does not grant all of `/home/josh`.

By default, the Nix-packaged OpenCode executable starts under the existing `~/.config/nono/profiles/opencode.json` profile without changing it. Its existing `~/.config/opencode` grant covers the operator-managed `~/.config/opencode/paseo-1.x.json`; the package runtime is in the Nix store and remains unchanged. Paseo does not overwrite either `opencode.json` or the user's Nono profiles.

### Enable Paseo tools for a trusted agent profile

1. Deploy the updated flake, then open **Settings → your host → Agents → Agent profiles**.
2. Create or edit an **OMP** or **OpenCode** profile. Under its feature settings, turn **Nono sandbox** off and save. Give it an obvious name such as **Trusted OMP — host access**.
3. Enable **Enable Paseo tools** in the host settings.
4. Start a **new agent** using that profile. Existing agents keep the sandbox mode with which they started; applying a profile with a different mode is rejected. Resuming an agent preserves its saved mode.

The saved setting is `featureValues.nonoSandbox: false`. Missing values default to `true`; only a boolean `false` opts out. It is a per-agent launch decision, not an environment-variable override or a change to the user's Nono JSON profiles. Sandboxed agents never receive the Paseo tool catalog or injected MCP servers, even when the host tools toggle is enabled. Unsandboxed agents use OMP's native host-tool RPC or OpenCode's native bridge, subject to the normal host tools setting. OpenCode still uses the separate 1.x configuration described below.

**Unsandboxed means host-user authority**, including Paseo tools that create terminals, worktrees, agents, and schedules. This is not a restricted orchestration-only mode. The tools toggle does not install orchestration skill files; use the separate skills installer if desired. No existing profile is opted out automatically.

### Operator-managed OpenCode 1.x config

Paseo's pinned SDK requires OpenCode 1.15.10. The host's OpenCode 2.x server is incompatible, and its v2 config is rejected by 1.15.10 (`agents` and `commands` are unrecognized). Do not convert or overwrite `~/.config/opencode/opencode.json`. The module selects the distinct operator-owned `~/.config/opencode/paseo-1.x.json` using OpenCode's `OPENCODE_CONFIG` file mechanism. A package patch prevents the 1.x process from loading or writing the host's default global config and global plugin/command directories; XDG and `~/.omp` remain at their normal locations. The daemon boots without this file, but OpenCode cannot list Settings models until you create a valid v1 config at `~/.config/opencode/paseo-1.x.json` using the no-clobber instructions below.

Create the separate file only after inspecting the host config. Use a no-clobber creation command so an existing `paseo-1.x.json` is never overwritten; review the result and edit it manually before starting an OpenCode agent:

```sh
umask 077
( set -o noclobber; jq --arg model 'h001/air-gpt-6-luna' '{
  "$schema": "https://opencode.ai/config.json",
  autoupdate: false,
  share: "disabled",
  enabled_providers: ["h001"],
  disabled_providers: ["openai", "opencode", "openrouter"],
  model: $model,
  provider: { h001: .provider.h001 },
  plugin: [],
  mcp: {}
}' ~/.config/opencode/opencode.json > ~/.config/opencode/paseo-1.x.json )
```

This copies only the current `h001` provider entry and selected model into a new v1-shaped config. Inspect it: OpenCode 1.x differs from 2.x, so do not copy the complete host configuration or assume every nested option is compatible. The source `~/.config/opencode/opencode.json` is read only.

### First-time setup on lio

Inspect `/home/josh/.paseo` before switching; during migration it held only `cli-client-id`. Activation does not write OpenCode/OMP/Nono user config, create `~/.config/paseo` config directories, or change project ownership. Existing `~/.config/nono/profiles/{opencode,omp}.json`, `~/.omp/agent/config.yml`, `models.yml`, databases, and sessions remain user-managed and active; `OMP_PROFILE`, `PI_CONFIG_DIR`, and XDG defaults remain untouched.

For local testing use `http://localhost:6767`; the lio host also accepts direct tailnet access at `http://100.64.0.1:6767`. Normal host `opencode` and `omp` commands are unchanged.

### Remove the old lio container

After a successful NixOS switch, stop and destroy the old container (this does not remove `/var/lib/paseo` or host project directories):

```sh
sudo systemctl stop container@paseo.service
sudo nixos-container destroy paseo
```

If the guest is already absent, the commands may report it was not found. Old `/var/lib/paseo` and `/var/lib/paseo-projects` are no longer used; archive/remove them separately only after confirming they contain nothing you want.
