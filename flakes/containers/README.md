# flakes/containers — floating services

One place for self-hosted apps that run on any fleet host **without a host
`nixos-rebuild`**. Each app (or suite) gets its own directory. Two kinds:

| kind     | runtime                         | use when                                   |
|----------|---------------------------------|--------------------------------------------|
| `nixos`  | extra-container → systemd-nspawn | the app has a NixOS module                 |
| `podman` | a podman systemd unit            | there is only an OCI image                 |

Both use the same model:

- **Ephemeral root.** Everything in the container is thrown away on each
  start. Only the dirs listed in `persist` survive.
- **Data at `/srv/containers/<name>/<key>`** on the host, the same path on
  every host.
- **Private UIDs + idmapped binds.** nspawn (`privateUsers = "pick"`) or podman
  (`--userns=auto`) gives the container its own UID range. Data dirs are
  bind-mounted with `idmap`, so files on the host have the *same numeric
  owners the container sees* (postgres = 71, etc.). There is no host UID
  ledger, and data moves between hosts with a plain `tar --numeric-owner`.
- **nginx stays on the host.** Each service can ship an nginx `server {}`
  block. `boxes deploy` writes it to `/var/lib/boxes/nginx/<name>.conf` and
  reloads nginx. Raw ports (`tcpPorts`/`udpPorts`) are opened at runtime in
  the nftables `temp-ports` set and re-applied after each firewall reload.

```
flakes/containers/
  flake.nix          host module, lib, inventory, `boxes` package
  host-module.nix    what each host needs (one rebuild)
  lib.nix            mkNixosContainer, mkPodmanService
  boxes/             Go CLI
  minecraft/         a nixos-kind service
  examples/whoami/   a podman-kind template (not deployed: no service.nix at top level)
```

## One-time host setup

1. Check idmapped mounts on the host (bcachefs is a DKMS module, so check
   every host):

   ```sh
   nix run git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers -- check-idmap h003
   ```

   Both `/srv/containers` and `/nix/var/nix` must print `OK`. If either
   fails, nspawn services with `privateUsers = "pick"` will not start on that
   host. Use another host, or set `privateUsers = "no"` for that service and
   pin its UIDs.

2. In the host flake: `inputs.containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers";`
   and add `inputs.containers.nixosModules.default` to the modules. Rebuild once.
   This also installs the `boxes` CLI on the host (`boxes.package`).

   Options (all optional):

   ```nix
   boxes.nginx.enable = true;              # nginx + include dir (off by default)
   boxes.privateNetwork.enable = false;    # NAT/forward for ve-* (privateNetwork containers)
   boxes.privateNetwork.externalInterface = "enp1s0";
   ```

   For a host that is itself a router with `filterForward` (h003), keep
   services on the host network (the default) or enable `privateNetwork`,
   which puts accept rules for `ve-*` at the top of the forward chain.

## The `boxes` CLI

```sh
nix run git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers -- <cmd>
# or install: inputs.containers.packages.${system}.boxes
```

It reads the inventory (`services/*/service.nix` + `hosts/fleet.nix`) from the
**pushed** repo and runs everything over ssh with `sudo`. To try unpushed
changes, use `--repo git+file:///home/josh/.config/nixos-config` (the hosts
must be able to fetch that ref, so pair it with `deploy --local`).

| command | what it does |
|---|---|
| `boxes ls` / `boxes ls --all` | each service: kind, declared host, host where it runs, state, uptime, memory. Flags services on the wrong host or on several hosts |
| `boxes watch` | same, refreshed every 5s (`-n secs`, `q` quits) |
| `boxes logs <svc>` | follow the journal inside the container (`--unit` for the nspawn unit, `-n`, `--no-follow`) |
| `boxes deploy <svc>` | create or update from the latest pushed definition on its host (`--host`, `--rev`, `--local` builds here and `nix copy`s) |
| `boxes stop <svc>` | **blocking** `systemctl stop`; returns when the container is down |
| `boxes start` / `restart <svc>` | start, or stop+start |
| `boxes attach <svc>` | the service console (`attach` in service.nix); `shell` for root shell |
| `boxes backup <svc>` | run hook, stop, tar `/srv/containers/<svc>` to this machine, start again (`-o file`, `--live`) |
| `boxes restore <svc> <file> --host h` | unpack a backup on a host (`--force` renames existing data) |
| `boxes move <svc> --to h` | stop, stream data, deploy on target, remove from source |
| `boxes destroy <svc>` | uninstall (data kept; `--purge` deletes it) |
| `boxes check-idmap <host>` | the idmap test above |

ssh logs in as each host's `user` from `hosts/fleet.nix` (override for all hosts
with `--ssh-user` / `BOXES_SSH_USER`; `root` skips sudo). `--dry-run` prints
the remote scripts.

Updating: commit + push, then `boxes deploy <svc>`. nspawn containers whose
only change is the system closure switch in place
(`switch-to-configuration test`); changes to the container settings (binds,
ports) restart them.

## Adding a service

Create `flakes/containers/<name>/` with `service.nix`, `flake.nix` and (for
nixos) the guest config.

`service.nix` is plain data:

```nix
{
  name = "atuin";
  kind = "nixos";               # or "podman"
  host = "h001";                # where it should run
  persist = {                   # key = path inside the container
    postgresql = "/var/lib/postgresql";
    nixos = "/var/lib/nixos";   # keep for nixos-kind: stable UID/GID map
  };
  tcpPorts = [ ];               # opened in the host firewall (raw ports only)
  udpPorts = [ ];
  nginx = ''                    # optional; @OVERLAY_IP@ / @LAN_IP@ substituted
    server {
      listen @OVERLAY_IP@:80;
      server_name atuin.joshuabell.xyz;
      location / { proxy_pass http://127.0.0.1:8888; }
    }
  '';
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";
  attach = null;                # command for `boxes attach`
}
```

**nixos kind** `flake.nix` (keep nixpkgs on nixos-25.11; extra-container issue #40):

```nix
outputs = { extra-container, nixpkgs, ... }:
  let boxes = import ../lib.nix; in
  extra-container.lib.eachSupportedSystem (system: {
    packages.default = extra-container.lib.buildContainers {
      inherit system nixpkgs;
      config = boxes.mkNixosContainer {
        service = import ./service.nix;
        config = import ./container.nix;
        # specialArgs = { ... };  privateNetwork = false;  privateUsers = "pick";
      };
    };
  });
```

The container shares the host network by default. Services should bind
`127.0.0.1` and be fronted by the host nginx; only bind `0.0.0.0` for raw
ports listed in `tcpPorts`. The guest firewall is disabled (the host firewall
is what counts). Guest-side timers and services work normally. Host-side
units cannot be defined from here; that is what `boxes` and the host module do.

**podman kind**: see `examples/whoami/`. `podman.image`, `ports`
(`"hostPort:containerPort"` binds 127.0.0.1; prefix an address for others),
`environment`, `extraArgs`, `cmd`.

Notes:

- Every persist key is created empty (root-owned, 0755) on first deploy. The
  guest's own tmpfiles/StateDirectory fixes ownership inside the namespace.
  Never `chown` them on the host to a host user.
- Secrets: put them in a persist dir (generated on first boot, as minecraft
  does) or copy them in once with `nixos-container run`.

## Backup

```sh
boxes backup minecraft                      # minecraft-h003-<date>.tar.zst in cwd
```

The archive is `/srv/containers/<svc>` with numeric owners, xattrs and ACLs,
taken while the service is stopped (after the backupHook, e.g. a SQL dump).
It restores on any host.

The archive is written to a hidden temp file next to the output and only
renamed into place after the remote `tar | zstd` pipeline (run with
`pipefail`) exits 0 and `zstd -t` passes. A failed backup leaves no file and
returns an error; the service is still restarted if it was running.

By hand on the host:

```sh
sudo systemctl stop container@minecraft     # blocks until down
sudo tar --numeric-owner --xattrs --acls -C /srv/containers -czf ~/minecraft-$(date +%F).tar.gz minecraft
sudo systemctl start container@minecraft
```

## Restore

```sh
boxes stop minecraft                         # if running there
boxes restore minecraft minecraft-h003-2026-10-08T0400.tar.zst --host h003 --force
boxes deploy minecraft
```

`--force` renames the existing data to `<dir>.pre-restore-<epoch>` rather
than deleting it. By hand: stop, move `/srv/containers/<svc>` aside,
`sudo tar --numeric-owner -xpf backup.tar.gz -C /srv/containers`, start.

## Moving a service to another host

Downtime is the stop + copy + first boot.

1. The target has the host module and passes `boxes check-idmap <target>`.
2. `boxes move minecraft --to h001`
   - checks the target is free (no running unit, no existing data dir)
   - runs the backupHook, then a blocking stop on the source
   - streams `/srv/containers/minecraft` source → target over ssh (through
     this machine; numeric owners kept)
   - verifies the copy: a digest of every path, type, owner and mode (plus
     regular-file sizes and symlink targets)
     must match on both hosts. A failure on either side (read, compress,
     decompress, extract) or a mismatch stops here, before deploy and
     before anything on the source is touched
   - deploys on the target (writes nginx site, opens ports, starts)
   - uninstalls on the source and renames its data to `minecraft.moved-<date>`
3. Set `host = "h001";` in `service.nix`, commit, push.
4. Point any outside routing at the new host (e.g. the `computerboyz` vhost
   in `hosts/oracle/o002/nginx.nix` proxies to h003's overlay IP; WAN
   port-forwards on the router).
5. When happy, delete `/srv/containers/<svc>.moved-*` on the old host.

If step 2 fails during the copy or the deploy, the service is stopped on the source with
its data untouched: `boxes start <svc> --host <source>`.

## Troubleshooting

- `boxes logs <svc> --unit` shows nspawn errors (bad bind path, idmap
  unsupported: `Failed to set up id mapped mount`).
- `journalctl -u container@<svc>` on the host. `machinectl` lists running
  containers.
- nginx refused a site: the file is left as
  `/var/lib/boxes/nginx/<svc>.conf.broken`, and the previous config keeps serving.
- Ports opened by boxes: `sudo nft list set inet nixos-fw temp-ports`.
  Source files: `/var/lib/boxes/ports/`.
