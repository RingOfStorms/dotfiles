# Paseo on bare-metal NixOS

This flake builds the pinned Paseo daemon plus a mandatory Nono provider launcher. Its NixOS module runs Paseo as an existing user rather than in a container. The daemon and provider isolation are separate: the daemon inherits normal host identity/filesystem access, while every provider launch is forced through Nono.

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
  proxy.domain = "paseo.example.com";
  environmentFile = "/var/lib/secrets/paseo.env";
};
```

The module sets a boot-starting `services.paseo` unit that survives logout and binds only to `127.0.0.1` by default (use `http://localhost:6767` on the host). On lio, it binds to `0.0.0.0` so both localhost and the tailnet IP work; only `tailscale0` permits incoming port 6767, not the LAN. Use `http://100.64.0.1:6767` on the tailnet or `https://paseo.joshuabell.xyz` through the existing tailnet-only nginx proxy. `PASEO_HOME` remains `~/.paseo`. `catalogWorkdir` must be an existing writable directory listed in `projects`; it is used for global Settings model discovery, while workspace discovery uses the selected workspace cwd. Global discovery is still wrapped by Nono with only that exact project directory as `--workdir` and `--allow`. Existing project directories are never created, chowned, or chmodded. The service gets a minimal PATH; provider binaries are fixed store paths behind the Nono launcher. `inheritUserEnvironment = false` keeps host-wide CLI aliases and user PATH from changing normal shell behavior.

When `proxy.domain` is set, the daemon allowlists that host, trusts loopback for forwarded proto, permits only the matching browser origin and uses the HTTPS URL as `app.baseUrl`. The host reverse proxy remains responsible for TLS and access controls. Serve only an exact, tailnet-filtered hostname: workspace service subdomains are unauthenticated and must not resolve to Paseo's vhost.

## Security boundary

Paseo runs as the existing host user with the normal home, git identity, SSH agent, `~/.omp`, and XDG defaults. Its daemon terminals remain ordinary host terminals by design; Nono wraps provider processes only. Do not expose `paseo` on a wildcard workspace-service hostname.

The mandatory package policy exposes only the built-in OpenCode and OMP providers. Every OpenCode server and OMP RPC process is started as `nono run`; other built-ins, custom/derived providers, plugins, provider-side ACP filesystem/terminal operations, provider-facing Paseo tools, and MCP injection are disabled. The launcher selects only the existing profile by a trusted provider ID and requires the daemon's absolute launcher path and exact session cwd. Missing profiles fail closed. There is no unsandboxed opt-out.

The selected profiles are the user's existing files: OpenCode uses `~/.config/nono/profiles/opencode.json`; OMP uses `~/.config/nono/profiles/omp.json`. They are not modified by Nix. Their current grants are broader than the per-agent workdir: OpenCode allows read/write access to `~/.opencode`, `~/.config/opencode`, `~/.cache/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.local/share/opentui`, and `$TMPDIR`, and read access to the configured Tempus/Okta paths. OMP allows read/write `~/.omp`, all of `~/.cache`, and `$TMPDIR`, plus read-only `~/.gitconfig`. Both allow outbound networking and set `workdir.access` to `readwrite`. The launcher adds only the exact agent cwd; it does not grant all of `/home/josh`.

The Nix-packaged OpenCode executable starts under the existing `~/.config/nono/profiles/opencode.json` profile without changing it. Its existing `~/.config/opencode` grant covers the operator-managed `~/.config/opencode/paseo-1.x.json`; the package runtime is in the Nix store and remains unchanged. Paseo does not overwrite either `opencode.json` or the user's Nono profiles.

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
