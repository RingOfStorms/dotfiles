# containers — floating services

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
  block. `containers deploy` writes it to `/var/lib/fleet-containers/nginx/<name>.conf` and
  reloads nginx. Raw ports (`tcpPorts`/`udpPorts`) are opened at runtime in
  the nftables `temp-ports` set and re-applied after each firewall reload.

```
containers/
  flake.nix          host module, lib, inventory, `fleet` package (from `flakes/fleet-agent`)
  host-module.nix    what each container host needs (one rebuild)
  lib.nix            mkNixosContainer, mkPodmanService
  minecraft/         a nixos-kind service
  hello-nixos/       test service, nixos kind: nginx splash page on :8081
  hello-podman/      test service, podman kind: nginx splash page on :8082
  examples/whoami/   a podman-kind template (not deployed: no service.nix at top level)
```

## One-time host setup

1. Check idmapped mounts on the host (bcachefs is a DKMS module, so check
   every host):

   ```sh
   nix run git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers -- check-idmap h003
   ```

   Both `/srv/containers` and `/nix/var/nix` must print `OK`. If either
   fails, nspawn services with `privateUsers = "pick"` will not start on that
   host. Use another host, or set `privateUsers = "no"` for that service and
   pin its UIDs.

2. In the host flake: `inputs.containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers";`
   and add `inputs.containers.nixosModules.default` to the modules. Rebuild once.
   This also installs the `fleet` CLI on the host (`ringofstorms.containers.package`, aliased as `cnt = "fleet containers"`).
   Non-container hosts add `inputs.fleet-agent` (`flakes/fleet-agent`), which `fleet.mkHost` imports automatically to run the bare-metal `:9101` status/metrics/log agent (`ringofstorms.fleetAgent`).

   Options (all optional):

   ```nix
   ringofstorms.containers.nginx.enable = true;              # nginx + include dir (off by default)
   ringofstorms.fleetAgent = { enable = true; listen = "100.64.0.13:9101"; };  # read-only GET /status.json & /logs.json for fleet-edge
   ringofstorms.containers.privateNetwork.enable = false;    # NAT/forward for ve-* (privateNetwork containers)
   ringofstorms.containers.privateNetwork.externalInterface = "enp1s0";
   ```

   For a host that is itself a router with `filterForward` (h003), keep
   services on the host network (the default) or enable `privateNetwork`,
   which puts accept rules for `ve-*` at the top of the forward chain.

## The `fleet containers` (`cnt`) CLI

```sh
nix run git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=containers -- containers <cmd>
# or install: inputs.containers.packages.${system}.fleet (aliased as `cnt = "fleet containers"`)
```

It reads the inventory (`containers/*/service.nix` + `hosts/fleet.nix`) from the
**pushed** repo and runs everything over ssh with `sudo`. To try unpushed
changes, use `--repo git+file:///home/josh/.config/nixos-config` (the hosts
must be able to fetch that ref, so pair it with `deploy --local`).

| command | what it does |
|---|---|
| `containers status <svc>` | one service in detail: state, on-boot, memory, restarts, firewall ports, the nginx site on the host, and its data dirs with sizes and owners (what backup/move copy) |
| `containers ls` / `containers ls --all` | each service: kind, the host the registry binds it to, the host where a copy runs, state, uptime, memory. Flags stray copies and copies on several hosts |
| `containers watch` | same, refreshed every 5s (`-n secs`, `q` quits) |
| `containers logs <svc>` | follow the journal inside the container (`--unit` for the nspawn unit, `-n`, `--no-follow`) |
| `containers deploy <svc>` | create or update from the latest pushed definition on its host (`--host`, `--rev`, `--local` builds here and `nix copy`s) |
| `containers stop <svc>` | **blocking** `systemctl stop`; returns when the container is down, and stays stopped across reboots |
| `containers start` / `restart <svc>` | start, or stop+start |
| `containers attach <svc>` | the service console (`attach` in service.nix); `shell` for root shell |
| `containers backup <svc>` | asks where to save (default `~/backups`) and, if running, whether to stop it; then hook, stop, tar `/srv/containers/<svc>` to this machine, start again (`-o file\|dir`, `--live`, `-y`) |
| `containers restore <svc> <file> --host h` | unpack a backup on a host (`--force` renames existing data) |
| `containers move <svc> --to h` | final restic backup on the source, restore on the target, deploy + route health, restore check, first backup on the target, then commit the move to the placement registry and retire the source. A failure before the commit undoes the target, drops the reservation and restarts the source |
| `containers restore-check <svc> [--snapshot ID]` | restore a `svc:<svc>` snapshot to a scratch dir on its host: SQLite `integrity_check`, PG dumps complete |
| `containers health <svc>` | every route answers on its host (backend and nginx) |
| `containers destroy <svc>` | uninstall (data kept; `--purge` deletes it). `--host` on a host the registry does not bind removes that stray copy and leaves the row; the bound copy, or a row a move still holds, needs `--force` (the bound copy's row is then removed, revision-guarded) |
| `containers check-idmap <host>` | the idmap test above |
| `containers routes [svc]` | declared routes from the inventory: fqdn, proto, port, exposure, auth, via, and the registry-bound host (`-` when unplaced). Unconverted services show as `nginx string` |
| `containers audit [host...] [--stdin]` | read-only: runs `ss -ltnupH` on each host (default: all container hosts) and lists every non-loopback listener as `declared` (a route, `tcpPorts`/`udpPorts` of a service the registry binds to that host), `host` (small allowlist in `flakes/fleet-agent/internal/containers/routes.go`: 22, 80, 443, 8443, 53, tailscale 41641/udp, dhcp, mdns; plus host daemons the host module declares in `/etc/fleet-containers/host-listeners`, e.g. the status endpoint at its configured address; plus, matched by process name rather than port, tailscaled's dynamic sockets on tailnet/wildcard addresses and systemd-resolved LLMNR on 5355) or `UNDECLARED` (incl. ports of `exposure = "local"` routes, and `proto = "http"` backend ports found on a non-loopback address — those must stay on `127.0.0.1`, nginx is the only thing allowed to expose them). Needs root on the remote host to see process names; non-root users get `sudo -n` (fails fast instead of hanging if it needs a password). If sudo there needs a password, plain ssh can't prompt (no TTY): run it on the host itself and feed the file in with `--stdin` (exactly one host): `sudo ss -ltnupH > /tmp/<host>.ss && cnt audit <host> --stdin < /tmp/<host>.ss`, or collect the file with `ssh -t`. Empty `--stdin` input (or input with no listeners) is an error, so a failed collection never looks like a clean host. With a machine key it also prints `== routing (h005)`: fleet-edge's comparison of the DNS, edge vhost, TCP stream and WAN forward layers against the registry (diagnostic only; omitted without a key). Otherwise exits 0 |
| `containers port open <svc> <port>/<tcp\|udp> --for <dur> [--from <host\|cidr>]... [--iface tailnet\|lan\|any] [--host h]` | open a port temporarily (see [Temporary ports](#temporary-ports-cnt-port)) |
| `containers port ls [host...]` / `port close <svc> <port>/<proto> [--from ...] [--iface ...]` | list / close them early |
| `containers expose <svc>[.<route>] --exposure tailnet\|lan\|public --for DUR\|forever [--reason T]` | widen one http route on its host for a while. tailnet/lan: `--for` required, max 24h; the host reverts it at expiry (transient timer, plus `fleet-containers-expose-expire` at boot and every minute). `public`: fleet-edge on h005 adds the public CNAME and pushes an o002 runtime vhost (default 8h, any duration ≥ 1m or `forever`; h005 owns the expiry). Public expose (and `--revoke` of one) signs with this machine's key (`/machine-key.json`, root-only), so run `sudo fleet containers expose ...`: the `cnt` alias does not expand under sudo. `expose --list [host...]` / `expose --revoke <svc>`; `deploy` drops an override; `routes` and `audit` show them |

The host module adds the shell alias `cnt = "fleet containers"`.

### Where a service runs

**Placement is runtime state.** The placement registry in fleet-edge on h005
is the only record of which host a service belongs to; `service.nix` has no
`host`. `cnt` resolves every command as `--host` > registry row > discovery.
`cnt place` shows the rows, `cnt place <svc> --host <h>` records a first
placement, `cnt place <svc> --set <h>` moves the binding, `cnt place <svc>
--adopt` adopts the one copy discovery finds, `cnt place --verify` checks every
bound service against what the hosts actually run.

Everything that has to follow a service reads the registry, not Nix: the
tailnet and LAN DNS answers, the public CNAME set, the o002 vhosts and TCP
streams, the h005 WAN forwards, and `:80`/`:443` admission on the bound host.
fleet-edge reconciles them on startup, every 30 s and after every registry
write, so a move or a first deploy needs no Nix edit and no rebuild. An
unplaced service has no row and therefore no DNS name, no edge vhost or
stream, and no forward; that is how a service is offline (`minecraft`).

Registry-backed resolution needs root plus the machine key on an allowlisted
caller (`sudo fleet containers …`; the `cnt` alias does not expand under
sudo). Otherwise `cnt` resolves by discovery alone: a key it cannot read, or a
registry that fails the request, prints one "placement registry not
consulted" warning, and a mutating command that falls through to discovery
says so too. With no machine key at all (a dev box) the fallback is silent.
`--dry-run` never probes, so it needs `--host` (and `move --dry-run` needs
`--from` when there is no binding).

The CLI still checks where a service **actually** runs: it lists units on each
host from systemd *and* from disk
(`/etc/systemd-mutable/system/container@*.service` and
`/nix/var/nix/gcroots/fleet-containers/*`), so a stopped, disabled or
unloaded service is still found.

- `containers ls` shows the registry's host next to the host that runs a copy,
  and flags a copy the registry does not bind (`!! placed on h001: this is a
  stray copy`).
- A command with no `--host` uses the registry's host when there is a row (and
  refuses when that host did not answer: silence is not absence). With no row
  it probes **every** container host (`containerHosts` in `flake.nix`, plus
  every host the registry knows), adopts the copy when exactly one is
  installed, and **refuses** when there are several or none, saying which
  `cnt place` form records the answer.
  `--host h` is the escape hatch for one command, and a first deploy needs it:
  a successful `cnt deploy <svc> --host h` then records the binding itself
  (reserve, then commit — unforced, like every write this command makes). A
  deploy takes minutes, so a move may have reserved the row meanwhile: that
  reservation is left exactly as it is, and the warning names the move holding
  it before naming the command to run by hand: `cnt place <svc> --set <h>`. If
  the write fails for any other reason, the deploy stands and the same warning
  names the command.
- When the bound host is **unreachable** every mutating command is refused
  (silence is not absence). The escape hatch, in order of preference:
  `cnt place <svc> --set <new> --force` moves the binding off a dead host —
  the destination has to be running the service, so deploy it there with
  `--host` first if the commit is refused. `cnt place <svc> --recover --force`
  settles a *fenced* row (a move that stopped mid-flight, state `stale`); it
  does not move a committed binding.
- A **fenced** row that names no host at all — a `stale` reservation, or a
  first placement whose move has not committed — refuses every mutating
  command before `--host` or discovery is considered: the move still owns the
  name, so placing the service anywhere is a guess between the two hosts it
  just touched. The refusal names the device holding the move, the destination
  and the state. `cnt place <svc> --recover` settles it by asking both ends
  (add `--force` when one does not answer), and
  `cnt place <svc> --set <host> --force` overrides it. Reads and `stop` still
  work.
- `start` and `restart` resolve like a deploy, not like a read: on a host that
  still holds a leftover copy they refuse when the registry binds the name
  elsewhere (that copy would answer the same name). `stop`, `status`, `logs`,
  `attach`, `shell` and `online` keep the local fast path.
- New container host: import the module there *and* add it to
  `containerHosts`, or discovery never probes it and `move --to` it is
  refused.
- `move` records itself in the placement registry: it reserves the destination
  before touching any host, commits after the restore check and first backup,
  and retires the source just before uninstalling it. A row another client has
  taken over (a `--force`, a second move) stops it with both hosts untouched,
  and `cnt place <svc> --recover` settles that. A commit whose answer is lost
  is confirmed only by a row that still carries the move's token; a row
  committed with no token (no previous binding) could be anyone's, so the move
  stops with both hosts untouched and the token kept, and a re-run finishes it
  (the switch uninstalls the source) only with `--force`.

### nginx at runtime

With `ringofstorms.containers.nginx.enable`, host nginx has
`include /var/lib/fleet-containers/nginx/*.conf;` in its http block (plus a
default `_` vhost returning 444). On deploy the CLI writes the service's
`nginx` block from `service.nix` (with `@OVERLAY_IP@` / `@LAN_IP@` filled in from
`hosts/fleet.nix`) to `<svc>.conf`, runs `nginx -t`, and reloads nginx. If the check or
reload fails, the previous `<svc>.conf` is put back and the rejected one is
kept as `<svc>.conf.broken`. Removing the block from `service.nix` (or `destroy`/`move`) deletes
the file and reloads. No host rebuild is involved.

All `cnt` subcommands accept `--help` or `-h` without loading inventory or
contacting hosts; these flags also work before the subcommand. Arguments
after `--` are passed through rather than interpreted as CLI help.

### Routes

`routes` in `service.nix` replaces the `nginx` string. A service sets
either `routes` or `nginx`, not both (`nginx` stays as the escape hatch for
unconverted services); `tcpPorts`/`udpPorts` may coexist.

```nix
routes.web = {
  port = 8300;               # required, backend port on 127.0.0.1
  name = "secrets";          # default: service name for `web`, else "<svc>-<route>"
  proto = "http";            # http (default) | tcp | udp
  exposure = "public";       # local (default) | tailnet | lan | public
  auth = "native-oidc";      # native-oidc | native | oauth2-proxy | none; required unless local
  # groups = [ "notes" ];     auth = "oauth2-proxy" only: zitadel roles (any of)
  # bypass = [ "/api/" ];     auth = "oauth2-proxy" only: ungated path prefixes
  # via = [ "edge" ];        # public only; default [ "edge" ] for http, required for tcp/udp
  # allow = [ "lio" ];  health = "/healthz";
  # http knobs: websockets = true; maxBody = "100m"; buffering = true;
  #   timeouts = "60s"; forwardedProto = "https"; extraConfig = "";  (inside location /)
  # publicWithoutAuth = false;  needed for public + auth = "none"
};
```

`lib.nix` fills defaults and throws on: unknown keys, http knobs or `name`
on tcp/udp, missing auth on a non-local route, public + `auth = "none"`
without `publicWithoutAuth`, `via` on a non-public route, duplicate names.
The inventory also carries computed `fqdn` (`<name>.joshuabell.xyz`) and
`url` per http route.

On deploy, every http route with exposure != `local` becomes an **internal**
`server {}` in `<svc>.conf` (:80/:443 v4+v6, wildcard cert, proxy to
`127.0.0.1:<port>`, `X-Forwarded-Proto https`, the exposure ACL). A public
`via = edge` route also gets an **edge** server on `:8443` that answers only
o002 and is the only place forwarded headers are trusted. tcp/udp routes with
exposure != `local` are added to the ports file like `tcpPorts`. `local`
produces nothing.

`:80`/`:443` admission is runtime too: deploy writes the route's sources as
`web`/`weblan` lines in the service's ports file, and the host module refills
`@src`/`@src6`/`@src_lan` from those files, so a host admits web traffic only
for services it actually runs. Tailnet-wide HTTP routes are admitted from
both `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. Routes with an `allow` list
instead admit only those hosts' `overlayIp` and optional `overlayIp6`
inventory addresses; missing IPv6 addresses never widen admission to the
whole /48.

`auth = "oauth2-proxy"` routes (any exposure; sso-proxy is public via o002,
so a public or `cnt expose`d gated route works off the tailnet too) are gated
by the fleet oauth2-proxy on h005 (`hosts/h005/oauth2-proxy.nix`): nginx
`auth_request`s `http://100.64.0.3:4180/oauth2/auth?allowed_groups=...`,
sends a 401 to `https://sso-proxy.joshuabell.xyz/oauth2/start`, proxies
`/oauth2/` and passes `X-Auth-Request-{User,Email,Groups}`. Every generated
server, gated or not, removes `_oauth2_proxy*` cookies before the backend.

ssh logs in as each host's `user` from `hosts/fleet.nix` (override for all hosts
with `--ssh-user` / `CONTAINERS_SSH_USER`; `root` skips sudo). `--dry-run` prints
the remote scripts.

Updating: commit + push, then `containers deploy <svc>`. nspawn containers whose
only change is the system closure switch in place
(`switch-to-configuration test`); changes to the container settings (binds,
ports) restart them.

### Temporary ports (`cnt port`)

`cnt port open <svc> <port>/<tcp|udp> --for <dur>` opens a port for at most
24h with no rebuild. The only state is an element in an nft set of
`inet nixos-fw` (`cnt-tmp`, or `cnt-tmp4`/`cnt-tmp6` with `--from`). Each
element has a timeout and the comment `svc=<svc>`. The kernel expires it,
and a firewall reload empties the sets, so they fail closed. Open and close
are logged with `logger -t cnt-port`.

- `--iface tailnet` (default) is tailscale0. `lan` needs
  `ringofstorms.containers.lanInterface` on the host and is refused without
  it. `any` means every interface and prints a warning.
- `--from` (repeatable) takes a fleet host name (its `overlayIp`, plus
  `overlayIp6` if the inventory has one) or an IP/CIDR.
- The command refuses an http-route backend port of any service on that host
  unless `--force-backend` is given. It answers "already open (declared)"
  for ports the service already declares. It warns but continues when
  nothing listens. It fails if the service isn't installed on the host.
- `cnt port ls [host...]` lists the elements with their service and time
  left. `cnt port close` takes the same `--from`/`--iface` as the open.
  `--dry-run` prints the script.
- The host module asserts `networking.nftables.enable`.

## Adding a service

Create `containers/<name>/` with `service.nix`, `flake.nix` and (for
nixos) the guest config.

`service.nix` is plain data:

```nix
{
  name = "atuin";
  kind = "nixos";               # or "podman"
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
  attach = null;                # command for `containers attach`
  requires = [ ];               # host capabilities, e.g. [ "nfs-h004" "intel-qsv" ]
}
```

`service.nix` describes the service, never where it runs. The first
`sudo fleet containers deploy <name> --host <h>` places it; after that the
registry knows the host and plain `cnt deploy <name>` follows it.

`requires` names must appear in the target host's
`ringofstorms.containers.capabilities`. `deploy` and `move` refuse (before
anything is stopped) on a host that lacks one.

**nixos kind** `flake.nix` (keep nixpkgs on nixos-25.11; extra-container issue #40):

```nix
outputs = { extra-container, nixpkgs, ... }:
  let containersLib = import ../lib.nix; in
  extra-container.lib.eachSupportedSystem (system: {
    packages.default = extra-container.lib.buildContainers {
      inherit system nixpkgs;
      config = containersLib.mkNixosContainer {
        service = import ./service.nix;
        config = import ./container.nix;
        # specialArgs = { ... };  privateNetwork = false;  privateUsers = "pick";
        # guestNixpkgs = <26.05 nixpkgs>;  guest only; host-side eval stays 25.11
        # binds = [ { host = "/nfs/x"; container = "/media"; } ];  not backed up
        # devices = [ "/dev/dri" ];  capabilities = [ "CAP_NET_ADMIN" ];
      };
    };
  });
```

The container shares the host network by default. Services should bind
`127.0.0.1` and be fronted by the host nginx; only bind `0.0.0.0` for raw
ports listed in `tcpPorts`. The guest firewall is disabled (the host firewall
is what counts). Guest-side timers and services work normally. Host-side
units cannot be defined from here; that is what `containers` and the host module do.

**podman kind**: see `examples/whoami/`. `podman.image`, `ports`
(`"hostPort:containerPort"` binds 127.0.0.1; prefix an address for others),
`environment`, `extraArgs`, `cmd`.

Notes:

- Every persist key is created empty (root-owned, 0755) on first deploy. The
  guest's own tmpfiles/StateDirectory fixes ownership inside the namespace.
  Never `chown` them on the host to a host user.
- Secrets: put them in a persist dir (generated on first boot, as minecraft
  does) or copy them in once with `nixos-container run`.

## Nightly restic (fleet-backup)

With `ringofstorms.containers.backup.enable = true` and an `environmentFile`
(RESTIC_REPOSITORY, RESTIC_PASSWORD, backend creds; normally a sec-agent
secret wired through `configChanges`), the host runs `fleet-backup.service`
nightly (`backup.schedule`, default 03:00). For every service installed on
that host it runs the `backupHook` (if running), makes SQLite `.backup`
copies, and snapshots `/srv/containers/<svc>` with tags `fleet` and
`svc:<name>`. History and retention follow the tag, not the host, so a
moved service continues its series. Enabled on: h001. Not on h003 (no
services) or joe (no restic secret yet).

On success each service gets a stamp
`/var/lib/fleet-containers/backup-last/<svc>`
(`time=<RFC3339> snapshot=<id> host=<h>`). The status endpoint reports it as
`lastBackup` and fleet-edge shows the age per service, flagged **stale** after
36h. SQLite `.backup` copies keep the live file's owner and mode (they replace
it on restore). One run per service at a time (flock in the staging dir).

```sh
sudo systemctl start fleet-backup                 # run now (all, then prune)
sudo systemctl start fleet-backup-svc@puzzles     # one service, no prune (what move uses)
cnt restore-check puzzles                         # latest svc:puzzles snapshot, scratch dir
sudo fleet-restic snapshots --tag svc:puzzles     # restic with the host's creds
sudo fleet-restic restore latest --tag svc:puzzles --target /tmp/r
```

## Backup

```sh
containers backup minecraft            # asks: directory [~/backups], stop it? [y/N]
containers backup minecraft -y -o /mnt/nas/   # no questions (scripts, cron)
```

The archive is `/srv/containers/<svc>` with numeric owners, xattrs and ACLs,
taken while the service is stopped (after the backupHook, e.g. a SQL dump).
It restores on any host.

If the service is running, `backup` asks before stopping it (it is started
again afterwards); answering no cancels, `--live` copies without stopping.
If it is already stopped it is backed up as is, without asking, and its
backupHook is skipped (it needs the service running). Without a terminal
(cron, pipes) nothing is asked: the directory is `~/backups` and a running
service is only stopped with `--yes`. The directory is created if missing.

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
containers stop minecraft                         # if running there
containers restore minecraft minecraft-h003-2026-10-08T0400.tar.zst --host h003 --force
containers deploy minecraft
```

`--force` renames the existing data to `<dir>.pre-restore-<epoch>` rather
than deleting it. By hand: stop, move `/srv/containers/<svc>` aside,
`sudo tar --numeric-owner -xpf backup.tar.gz -C /srv/containers`, start.

## Moving a service to another host

Data goes through the shared restic repository, so the service keeps its
`svc:<name>` history and every move is also a restore test. Downtime is the
stop + backup + restore + first boot. Routing follows the placement registry,
so nothing in Nix is edited and no host is rebuilt.

1. Both hosts have `ringofstorms.containers.backup` enabled (same repo); the
   target passes `containers check-idmap <target>` and offers the service's
   `requires` capabilities.
2. `sudo fleet containers --dry-run move minecraft --from h003 --to h001`
   prints the plan (every remote script, in order). Then
   `sudo fleet containers move minecraft --to h001`:
   1. **reserve** the destination in the placement registry. The row stays
      routed to the source; a row another client holds stops the move here,
      before any host is touched. The token is saved under
      `$XDG_STATE_HOME/fleet-containers/moves/<svc>.json`, and the lease is
      renewed as the move advances.
   2. **preflight**: target has the host module, `fleet-backup` and the
      capabilities, and no running unit or data of the service; the source
      has fleet-backup and the data. A refusal here changes nothing.
   3. **final backup** on the source: backupHook, blocking stop,
      `fleet-backup-svc@<svc>`; the snapshot id comes from the fresh stamp
      (an old stamp is never accepted).
   4. **restore** that snapshot onto the target (the SQLite `.backup` copies
      replace the excluded live files), then the live PostgreSQL cluster
      dirs (excluded from restic) are copied from the stopped source and
      verified by manifest (paths, types, owners, modes, sizes).
   5. **deploy** on the target, then **health**: every route answers on the
      backend (2xx/3xx on its `health` path, otherwise any status below 500)
      and, for http routes with an fqdn, through the target's nginx.
   6. **restore check**: the same snapshot restored to a scratch dir on the
      target; every SQLite db must pass `PRAGMA integrity_check`, every PG
      dump must be non-empty, valid gzip and a complete pg_dump (custom format:
      `PGDMP` header). A service whose hook runs pg_dump must have one.
   7. **first backup** on the target (its stamp must be from the target).
   8. **commit** the destination: DNS, o002 vhosts and streams, and WAN
      forwards follow it on fleet-edge's next reconcile pass.
   9. **retire** the source (a rollback onto it now needs `--force`), then
      **switch**: uninstall on the source, data renamed
      `<svc>.moved-<date>` (fleet-backup skips names with a dot).

   A failure before the commit uninstalls the target, moves its data aside
   as `<svc>.failed-move-<time>`, drops the reservation (restoring the prior
   binding) and starts the source again if it was running (a stopped service
   stays stopped). If the move no longer owns the row (taken over, or
   ownership cannot be confirmed) it leaves both hosts alone; settle that with
   `cnt place <svc> --recover`. Re-running is safe: the target is marked
   (`/var/lib/fleet-containers/move-<svc>`) until the first backup finishes,
   and a re-run clears such leftovers first; data on the target without that
   marker is refused, never overwritten. The source remembers it was running
   (`move-<svc>.was-running`) across an interrupted run, and a re-run resumes
   with the saved token (or `--resume-token`).
3. Check `cnt place <svc> --verify` and `cnt audit`.
4. When happy, delete `/srv/containers/<svc>.moved-*` on the old host.

## Start, stop and reboots

`stop` blocks until the service is down and removes its boot-time link, so
it stays stopped across reboots until you `start`, `restart` or `deploy` it.
A service you did not stop (running, or crashed) is still enabled and starts
again on boot; crashes in between restart via `Restart=on-failure`.

### Storage guards

A host can tie services to network storage with
`ringofstorms.containers.guards.<name>` (see host-module.nix):
`fleet-guard-<name>.service` probes each mount (fs type and a sentinel file,
every check SIGKILLed after 12 s so a hung NFS mount can't wedge it) every
30 s and exits on the first failure. The listed units are `BindsTo=` the
guard, so they stop with it and can't start while it is down. When the guard
is back, it starts each listed unit that still has its boot link and has no
hold marker in `/run/fleet-containers/hold/`. `stop`, `move` and `backup`
write that marker; `start`, `restart` and `deploy` clear it. A stopped
service therefore stays stopped when storage comes back.

## Design notes

- Nix declares service identity and routes; only h005's runtime registry
  declares placement. Discovery reports copies, not a second authority.
- Runtime firewall sets start empty. Deployment fills admission on the host
  running the service; nginx checks exposure and the actual transport peer.
  Edge peers must never inherit internal tailnet access.
- Low-trust LAN drops precede NixOS port accepts in a separate input chain.
  LAN SSH is an outage fallback, not an exemption from trust restrictions.
- Boot-time exposure expiry cannot reload nginx: a unit ordered before nginx
  that waits for nginx would deadlock. A separate running timer reloads it.
- Storage guards and stop/backup/move share the hold lock, so recovery cannot
  restart a service between its stop decision and hold-marker write.
- Certificate push targets are independent of placement, allowing a host to
  terminate TLS before its first service arrives. The router uses dedicated,
  forced-command keys rather than fleet-wide root SSH credentials.

## Troubleshooting

- `containers logs <svc> --unit` shows nspawn errors (bad bind path, idmap
  unsupported: `Failed to set up id mapped mount`).
- `journalctl -u container@<svc>` on the host. `machinectl` lists running
  containers.
- nginx refused a site: the previous file is restored (so the old route keeps
  working across later reloads) and the rejected one is left as
  `/var/lib/fleet-containers/nginx/<svc>.conf.broken`.
- Ports opened by containers: `sudo nft list set inet nixos-fw temp-ports`.
  Source files: `/var/lib/fleet-containers/ports/`.

## Practice services: hello-nixos and hello-podman

Two throwaway twins for trying the workflow; both serve the stock "Welcome
to nginx!" page. hello-nixos runs nginx inside an nspawn container on port
8081; hello-podman runs `nginx:alpine` on 8082. Each persists `/data`
(empty) so you can drop a marker file in `/srv/containers/<svc>/data` and
watch it follow a move. `cnt place` shows where each is bound.

```sh
cnt deploy hello-nixos && cnt deploy hello-podman
curl http://<host>:8081/ http://<host>:8082/
cnt status hello-podman
cnt stop hello-nixos            # stays down after a reboot
cnt backup hello-podman
cnt move hello-nixos --to lio   # the move records itself in the registry
cnt destroy hello-podman --purge
```
