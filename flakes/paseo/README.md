# paseo

Patched [Paseo](https://github.com/getpaseo/paseo) daemon, a pinned
[nono](https://github.com/always-further/nono) build, and a NixOS module that
runs Paseo in an ephemeral container with every provider process (OpenCode,
omp) confined by nono to its agent's worktree.

## Outputs

- `packages.<system>.paseo` (`default`): upstream Paseo plus the patches in
  `patches/` and `procps` on the server's PATH (see `flake.nix`).
- `packages.<system>.nono`: nono CLI built with a rust-overlay toolchain.
- `nixosModules.container`: host-side module, options under
  `ringofstorms.paseo`.
- `nixosModules.upstream`: the unmodified upstream `services.paseo` module
  (the container module imports it in the guest).
- `lib.toolsModule { common, ros_neovim, hostConfig, primaryUser }`: guest
  module that gives the container the host primary user's shell, git, tmux,
  neovim, etc. (system-level, read from the host's evaluated Home Manager
  config).

## Host usage

```nix
# hosts/<host>/flake.nix
inputs.paseo.url = "path:../../flakes/paseo";
inputs.paseo.inputs.nixpkgs.follows = "nixpkgs";

# hosts/<host>/paseo.nix
{ config, constants, inputs, pkgs, ... }:
{
  imports = [ inputs.paseo.nixosModules.container ];
  ringofstorms.paseo = {
    enable = true;
    uid = 983;
    gid = 983;
    containerIp = "10.0.0.12";
    containerIp6 = "fc00::12";
    hostAddress = "10.0.0.1";
    hostAddress6 = "fc00::1";
    secretFile = "/var/lib/secrets/paseo.env";
    extraHostnames = [ constants.host.overlayIp ];
    tailnet = {
      enable = true;
      domains = [ "net.example.com" "~example.com" ];
    };
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
    extraGuestModules = [
      (inputs.paseo.lib.toolsModule {
        inherit (inputs) common ros_neovim;
        hostConfig = config;
        inherit (constants.host) primaryUser;
      })
    ];
  };
}
```

The host needs NAT for `ve-*` (and nftables if `tailnet.enable`). Nothing is
bound on the host; the daemon listens on `containerIp:port`.

Pick `uid`/`gid` values that are free on the host: NixOS never changes the id
of an existing user, and an id another account already has would give that
account ownership of the bind mounts (h001 uses 960 because 983 was taken).

### Behind a host reverse proxy (`proxy.domain`)

Setting `proxy.domain = "paseo.example.com"` makes the daemon accept that
hostname, trust `hostAddress` as a proxy (so `X-Forwarded-Proto` counts),
allow the `https://paseo.example.com` origin, and use that URL as
`app.baseUrl`. The vhost (TLS, ACLs) stays in the host config. It must send
these headers:

```nix
services.nginx.virtualHosts."paseo.example.com".locations."/" = {
  proxyPass = "http://<containerIp>:<port>";
  proxyWebsockets = true;
  recommendedProxySettings = false; # it sends `Host $host`, which cannot be overridden
  extraConfig = ''
    proxy_set_header Host $host:443;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_buffering off;
  '';
};
```

Why `Host $host:443`: the served web UI embeds
`{listen: <Host header>, useTls: <req.protocol == https>}` and the app only
auto-connects when `listen` parses as `host:port`. Without the port it shows
the manual add-host screen. The daemon ignores the port when it matches
`daemon.hostnames`. Its WebSocket same-origin check compares `Origin` with
`https://<Host>` exactly, though, so `https://paseo.example.com` fails against
`paseo.example.com:443`. That is why the module lists the origin in
`daemon.cors.allowedOrigins`. Browsers still get a 403 from any other origin.

### `ringofstorms.paseo` options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Declare the container. |
| `name` | `"paseo"` | Container name; host veth is `ve-<name>`. |
| `port` | `6767` | Daemon port inside the container. |
| `uid`, `gid` | required | Pinned `paseo` user/group on host and guest. |
| `containerIp`, `containerIp6` | required | Guest addresses. |
| `hostAddress`, `hostAddress6` | required | Host side of the veth. |
| `dataDir` | `/var/lib/paseo` | Host dir mounted as the guest home `/var/lib/paseo`. |
| `projectsDir` | `/var/lib/paseo-projects` | Host dir for clones/worktrees. |
| `projectsRoot` | `/srv/paseo-projects` | Guest mount of `projectsDir`; `worktrees.root`. |
| `secretFile` | required | Host EnvironmentFile; must set `PASEO_PASSWORD_BCRYPT`. |
| `extraHostnames` | `[ ]` | Extra accepted hostnames (also in guest `NO_PROXY`). |
| `proxy.domain` | `null` | HTTPS reverse-proxy name; derives hostnames, trusted proxy, CORS origin, `app.baseUrl` (otherwise `http://<containerIp>:<port>`). |
| `tailnet.enable` | `false` | Masquerade guest→tailnet and add a resolved DNS delegate. |
| `tailnet.interface` | `tailscale0` | Host tailnet interface. |
| `tailnet.dnsServer` | `100.100.100.100` | Delegate DNS server. |
| `tailnet.domains` | `[ ]` | Delegate domains (`net.example.com`, `~example.com`). |
| `package` | this flake's `paseo` | Paseo daemon. |
| `opencodePackage` | `pkgs.opencode` | Must speak the OpenCode 1.x HTTP API (Paseo 0.9 SDK). |
| `ompPackage` | required | omp package, or `null` to drop the omp provider. |
| `nonoPackage` | this flake's `nono` | Sandbox used by `paseo-nono-launch`. |
| `extraGuestModules` | `[ ]` | Extra guest NixOS modules (e.g. `lib.toolsModule`). |
| `extraSettings` | `{ }` | Merged into the daemon's `config.json`. |

## What is declarative and what is not

Declarative (rewritten on every start): the daemon `config.json` (with the
password hash injected from `secretFile`), the service unit, and the empty
directories nono/Landlock need to exist.

**Not** declarative: OpenCode, omp, and nono configuration. They live in the
persistent home (host `dataDir`, guest `/var/lib/paseo`), are created and
edited by hand, take effect on the next provider launch, and are never touched
by a rebuild or restart:

| File (guest path) | Template |
| --- | --- |
| `/var/lib/paseo/.config/nono/profiles/paseo.json` | `examples/nono/paseo.json` |
| `/var/lib/paseo/.config/nono/profiles/opencode.json` | `examples/nono/opencode.json` |
| `/var/lib/paseo/.config/opencode/opencode.json` | `examples/opencode/opencode.json` |
| `/var/lib/paseo/.omp/agent/config.yml` | `examples/omp/config.yml` |
| `/var/lib/paseo/.omp/agent/models.yml` | `examples/omp/models.yml` |

Every provider starts through `paseo-nono-launch`, which runs
`nono run --profile $HOME/.config/nono/profiles/paseo.json` with the agent's
worktree (`PASEO_AGENT_CWD`, or `~/opencode-home` for agent-less launches) as
the read-write workdir. If `paseo.json` is missing the launcher exits with an
error naming the path; it never falls back to running unsandboxed.
`PASEO_UNSANDBOXED=1` in the provider environment is the explicit opt-out.

nono resolves a profile's `extends` names against sibling files in the same
directory first, so `paseo.json`'s `extends: ["opencode"]` picks up the
`opencode.json` next to it. That file is the `always-further/opencode` pack
policy (nono-packs tag `opencode-v0.0.6`); nono won't install packs without a
TTY, so keep it there rather than relying on the registry.

### OpenCode 1.x config schema

The container runs nixpkgs OpenCode (1.15.10) because Paseo speaks the 1.x
HTTP API; 1.x rejects unknown top-level keys. When porting a 2.x
`opencode.json`:

- `agents` → `agent`
- `commands` → `command`
- `disabled` → `disable` (per agent)
- `subagent` → `subtask`
- no `provider/model#variant` references: use the bare model and set its
  `options` (e.g. `reasoningEffort`) on the model entry.

The example keeps only the LiteLLM (`h001`) provider with three models; add
more under `provider.h001.models`. Paseo injects its bridge plugin through
`OPENCODE_CONFIG_CONTENT`, which OpenCode merges on top of this file. The
examples' LiteLLM URL `http://h001.net.joshuabell.xyz:8094/v1` works on every
host. On h001 it resolves to h001's own tailnet address, and the host
delivers that locally: packets from `ve-*` go to a local address on a trusted
interface, with no masquerade involved.

## First-time setup

On the host, from a checkout of this repo (`dataDir` = `/var/lib/paseo`):

```sh
ex=flakes/paseo/examples
home=/var/lib/paseo
sudo install -d -m 0700 -o paseo -g paseo \
  $home/.config $home/.config/nono $home/.config/nono/profiles \
  $home/.config/opencode $home/.omp $home/.omp/agent
sudo install -m 0600 -o paseo -g paseo $ex/nono/paseo.json $ex/nono/opencode.json $home/.config/nono/profiles/
sudo install -m 0600 -o paseo -g paseo $ex/opencode/opencode.json $home/.config/opencode/
sudo install -m 0600 -o paseo -g paseo $ex/omp/config.yml $ex/omp/models.yml $home/.omp/agent/
```

`install` overwrites; skip any file you already maintain. Then log OpenCode
into GitHub Copilot (stored in the persistent home):

```sh
sudo nixos-container run paseo -- runuser -u paseo -- env HOME=/var/lib/paseo sh -c 'cd /var/lib/paseo/opencode-home && exec paseo-nono-launch opencode auth login --provider github-copilot'
```

Migrating from another host (e.g. lio) instead: copy its
`/var/lib/paseo/.config/opencode`, `/var/lib/paseo/.omp/agent/*.yml`, and
`/var/lib/paseo/.config/nono/profiles` into the same paths, keeping
`paseo:paseo` ownership, `0700` directories, and `0600` files.

### h001

Run on h001 after the first switch, so the `paseo` user (uid/gid 960) and
`/var/lib/paseo` exist. Either use the examples, from a checkout at
`~/.config/nixos-config`, with the commands above. Or copy lio's live
configs, run from lio, where the ssh user must be able to `sudo` on h001:

```sh
# on lio: stream the live configs (sudo on h001 must work non-interactively,
# otherwise copy the tarball over and extract it there)
sudo tar -C /var/lib/paseo -cf - \
    .config/opencode/opencode.json .omp/agent/config.yml .omp/agent/models.yml \
    .config/nono/profiles/paseo.json .config/nono/profiles/opencode.json \
  | ssh h001 'sudo tar -C /var/lib/paseo --no-same-owner --no-same-permissions -xf -'

# on h001: fix ownership and modes
sudo chown -R paseo:paseo /var/lib/paseo/.config /var/lib/paseo/.omp
sudo chmod 0700 /var/lib/paseo/.config/opencode /var/lib/paseo/.config/nono/profiles /var/lib/paseo/.omp/agent
sudo chmod 0600 /var/lib/paseo/.config/opencode/opencode.json /var/lib/paseo/.omp/agent/*.yml /var/lib/paseo/.config/nono/profiles/*.json
```

Then run the copilot login above with `sudo nixos-container run paseo ...` on
h001, and restart the container so the daemon starts with the configs present:
`sudo systemctl restart container@paseo`. The web UI is at
`https://paseo.joshuabell.xyz` for tailnet clients only, once h003 serves the
DNS record.
