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
- **Private network.** With `net.private` (every inventory service) a
  container gets a fixed address of its own and nginx proxies to it; see
  [Private networking](#private-networking).

Host SSH allow-lists are generated separately from inventory `overlayIp`
and `overlayIp6`; both must include lio. Low-trust IPv6 peers are dropped
before NixOS port accepts, just like low-trust LAN IPv4 peers. h005's own
HTTP exclusions and admission, OAuth auth-request clients, fleet-agent
pollers, and nginx edge peers also carry both address families.

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
   ringofstorms.containers.nginx.enable = true;           # nginx + include dir (default true)
   ringofstorms.containers.privateNetwork.enable = true;  # host side for net.private nixos guests (default false)
   ringofstorms.containers.backup.enable = true;          # nightly restic, see below (default false)
   ringofstorms.containers.lanInterface = "enp3s0";       # enables `cnt port open --iface lan`
   ringofstorms.fleetAgent.listen = "100.64.0.13:9101";   # status/logs for fleet-edge; default on, at the overlay IP
   ```

   A host that runs a `net.private` nixos service needs `privateNetwork.enable`
   (h001, h003 and lio have it); without it the ports-file `guest`, `noinet`,
   `allow` and `dnat` lines are skipped with a warning. On a host with
   `networking.firewall.filterForward` (h003) the module also adds nixos-fw
   forward accepts for `ve-*` egress, DNATed flows into `ve-*` and podman
   `net.uses`; fleet-net has already dropped what must not pass.

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
| `containers restore <svc> --extra all\|/configured/path [--snapshot ID] [--repo REST_REPO] [--into /absolute/scratch] --host h` | restore declared extra paths (latest by default); uses deleting sync, so choose dedicated scratch when using `--into` |
| `containers move <svc> --to h` | pre-sync extra paths, final restic backup on the source, restore on the target, copy excluded PostgreSQL clusters from the stopped source, deploy + route health, restore check and first target backup; then commit placement and retire source. Backups must be enabled. Pre-commit rollback restarts the source and keeps synced extra data for retry |
| `containers restore-check <svc> [--snapshot ID] [--repo REST_REPO]` | restore a `svc:<svc>` snapshot to scratch on its host: SQLite `integrity_check`, PG dump completeness; no PostgreSQL import or application test |
| `containers health <svc>` | every route answers on its host (backend and nginx) |
| `containers destroy <svc>` | uninstall (data kept; `--purge` deletes it). `--host` on a host the registry does not bind removes that stray copy and leaves the row; the bound copy, or a row a move still holds, needs `--force` (the bound copy's row is then removed, revision-guarded) |
| `containers check-idmap <host>` | the idmap test above |
| `containers routes [svc]` | declared routes, registry-bound host (`-` when unplaced), NET (`host` or private IP), and DNS/EDGE from fleet-edge's routing/override APIs (`-` offline) |
| `containers audit [host...] [--stdin]` | read-only: runs `ss -ltnupH` on each host (default: all container hosts) and lists every non-loopback listener as `declared` (a route, `tcpPorts`/`udpPorts` of a service the registry binds to that host), `host` (small allowlist in `flakes/fleet-agent/internal/containers/routes.go`: 22, 80, 443, 8443, 53, tailscale 41641/udp, dhcp, mdns; plus host daemons the host module declares in `/etc/fleet-containers/host-listeners`, e.g. the status endpoint at its configured address; plus, matched by process name rather than port, tailscaled's dynamic sockets on tailnet/wildcard addresses and systemd-resolved LLMNR on 5355) or `UNDECLARED` (incl. ports of `exposure = "local"` routes, and `proto = "http"` backend ports found on a non-loopback address — those must stay on `127.0.0.1`, nginx is the only thing allowed to expose them). Needs root on the remote host to see process names; non-root users get `sudo -n` (fails fast instead of hanging if it needs a password). If sudo there needs a password, plain ssh can't prompt (no TTY): run it on the host itself and feed the file in with `--stdin` (exactly one host): `sudo ss -ltnupH > /tmp/<host>.ss && cnt audit <host> --stdin < /tmp/<host>.ss`, or collect the file with `ssh -t`. Empty `--stdin` input (or input with no listeners) is an error, so a failed collection never looks like a clean host. With a machine key it also prints `== routing (h005)`: fleet-edge's comparison of the DNS, edge vhost, TCP stream and WAN forward layers against the registry (diagnostic only; omitted without a key). Otherwise exits 0 |
| `containers port open <svc> <port>/<tcp\|udp> --for <dur> [--from <host\|cidr>]... [--iface tailnet\|lan\|any] [--host h]` | open a port temporarily (see [Temporary ports](#temporary-ports-cnt-port)) |
| `containers port ls [host...]` / `port close <svc> <port>/<proto> [--from ...] [--iface ...]` | list / close them early |
| `containers expose <svc>[.<route>] --exposure tailnet\|lan\|public --for DUR\|forever [--reason T]` | widen one http route on its host for a while. tailnet/lan: `--for` required, max 24h; the host reverts it at expiry (transient timer, plus `fleet-containers-expose-expire` at boot and every minute). `public`: fleet-edge on h005 adds the public CNAME and pushes an o002 runtime vhost (default 8h, any duration ≥ 1m or `forever`; h005 owns the expiry). Public expose (and `--revoke` of one) signs with this machine's key (`/machine-key.json`, root-only), so run `sudo fleet containers expose ...`: the `cnt` alias does not expand under sudo. `expose --list [host...]` / `expose --revoke <svc>`; `deploy` drops an override; `routes` and `audit` show them |
| `containers expose --reset <svc>` | clear the fleet-edge override API row and every host-local override, including interrupted/orphan directories. Retry an owed nginx reload up to three times and re-read to confirm; pending reloads and unreachable hosts return non-zero, never clean |

`cnt move` carries tailnet/LAN overrides to the destination with their original
deadline (the clock does not restart) before removing the source. Public
overrides must be revoked first.
LAN DNS follows the bound host's unexpired LAN override on the next reconcile
pass (30 seconds); expiry removes the additional LAN answer.

The host module adds the shell alias `cnt = "fleet containers"`.

### Where a service runs

**Placement is runtime state.** The placement registry in fleet-edge on h005
is the only record of which host a service belongs to; `service.nix` has no
`host`. `cnt` resolves every command as `--host` > registry row > discovery.
`cnt place` shows the rows, `cnt place <svc> --host <h>` records a first
placement, `cnt place <svc> --set <h>` moves the binding, `cnt place <svc>
--adopt` adopts the one copy discovery finds, `cnt place --verify` checks every
bound service against what the hosts actually run. Row states, tokens,
revisions, the sweep and the API are in `flakes/fleet-edge/README.md`
(Placement registry).

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
  refused. Give it a Zitadel machine user in `fleet.global.overrideWriters`
  (`hosts/fleet.nix`) too: registry writes are authenticated per machine, so
  `sudo fleet containers …` run on a host that is not listed cannot record or
  change a placement.
- `move` records itself in the placement registry: it reserves the destination
  before touching any host, commits after the restore check and first backup,
  and retires the source just before uninstalling it. A row another client has
  taken over (a `--force`, a second move) stops it with both hosts untouched,
  and `cnt place <svc> --recover` settles that. A commit whose answer is lost
  is confirmed only by a row that still carries the move's token; a row
  committed with no token (no previous binding) could be anyone's, so the move
  stops with both hosts untouched and the token kept, and a re-run finishes it
  (the switch uninstalls the source) only with `--force`.
- **A placement is not a lease.** `/srv/containers` is per host, not shared,
  so after a failed move two hosts can both hold valid data dirs. The registry
  says which copy is authoritative; it never cleans up the other one.
- **`net.uses` across hosts** is resolved from both services' registry hosts
  at deploy time: a same-host pair talks over the private network, a
  cross-host pair through the callee host's overlay IP. When a move changes
  that, the caller's egress rule follows its next deploy and the callee's
  nginx `allow` the callee's next deploy (the move itself refreshes only the
  callee's ports file); `cnt audit` flags the drift in between.
- `restore` writes to the bound host unless `--host` says otherwise, and
  refuses while the service is running there.
- **Bootstrap.** `sudo fleet containers place --import [--force]` is the
  one-time way to fill an empty registry: it binds every service discovery
  finds on exactly one host, with every host answering, and the registry
  accepts only a copy that is installed and active. Everything else (a silent
  host, two copies, a stopped unit) is printed as skipped with the reason and
  left unplaced. Nothing is ever seeded from Nix.

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

`routes` in `service.nix` declares every HTTP, TCP and UDP entry point (the
old free-form `nginx` string is rejected). `tcpPorts`/`udpPorts` may coexist
on a host-network service; a `net.private` nixos service must use tcp/udp
routes instead (they get DNAT).

```nix
routes.web = {
  port = 8300;               # required, backend port (guest IP when net.private, else 127.0.0.1)
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
`server {}` in `<svc>.conf` (:80/:443 v4+v6, wildcard cert, proxy to the
guest IP on `net.private` (`10.233.<index>.2`, podman `10.89.250.<100+index>`)
or `127.0.0.1` on the host network, `X-Forwarded-Proto https`, the exposure
ACL). A public `via = edge` route also gets an **edge** server on `:8443`
that answers only o002 and is the only place forwarded headers are trusted.
tcp/udp routes with exposure != `local` are added to the ports file: like
`tcpPorts` on the host network, as a `dnat` line on `net.private`. `local`
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
24h with no rebuild. Host-network ports use an element in an nft set of
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
- On a `net.private` service a host port would reach nothing (the app is
  in the guest netns), so `open` adds a temporary DNAT from the host port to
  the guest IP instead: an element in a map of `ip cnt-port` (`cnt-fwd`,
  `cnt-fwd4` with `--from`, and `cnt-fwd-any`/`cnt-fwd4-any` for
  `--iface any`; template `flakes/fleet-agent/internal/containers/cnt-port.nft`,
  loaded by the first such open). Same timeout, `svc=<svc>` comment,
  `--iface`/`--from` scoping; never from guests, and
  a declared tcp/udp route on the same port wins. IPv4 only: v6 `--from`
  sources are dropped with a note (all-v6 is refused). It refuses a port a
  host process listens on beyond loopback (the forward would shadow it).
  Established connections outlive the close/expiry, as with host ports.
- A NixOS guest's own firewall admits only its declared ports, so the open
  also adds `<proto> . <port>` to the guest's `cnt-guest` set in its
  `inet nixos-fw`. The rule is `cnt-guest.nft`, which lib.nix adds to every
  private NixOS guest. The open enters the guest's netns with
  `nsenter -t $(machinectl show -p Leader --value <svc>) -n nft`. The rule
  admits the port only on `eth0` (the veth from the host) and only from
  outside 10.233.0.0/16. DNAT keeps the client's address, so the host itself
  and other guests never reach a temporary port. The guest element lasts
  as long as the longest live forward of that port, and close deletes it
  with the last one. The kernel expires it. After a host firewall reload,
  `fleet-containers-port-restore` restores live forwards with their remaining
  TTL from `/var/lib/fleet-containers/port-fwd`; its minute sweep also restores
  guest elements after a guest firewall restart. Close removes saved entries;
  move/destroy remove the source's forwards and state before firewall restart.
  Expired state is pruned, never extended. The open refuses a guest that
  isn't running or has no `cnt-guest` set, and it removes the host forward
  again if adding the guest element fails. A set is missing when the guest
  keeps the iptables firewall: lib.nix enables nftables in private guests
  with `mkDefault`, and arr sets `networking.nftables.enable = false` for
  its iptables loopback guard, so `cnt port open arr` is refused. A guest
  deployed before this change needs a redeploy. Podman services have no
  guest firewall, so their DNAT is enough.
- `cnt port ls [host...]` lists the elements with their service, guest
  (`TO`, forwards only) and time left. `cnt port close` takes the same
  `--from`/`--iface` as the open and removes host ports and forwards alike.
  `--dry-run` prints the script.
- The host module asserts `networking.nftables.enable`.

## Private networking

`net = { private = true; index = N; }` in `service.nix` gives a service its
own network namespace with a fixed address. Every inventory service uses it;
without `net`, a service shares the host network.

**Addresses.** `index` is chosen by hand and never derived from the name, so
a rename cannot move an address. Each kind has its own index space, unique
fleet-wide within the kind (the inventory eval throws on a duplicate); never
reuse a retired index (12 was beszel).

| kind | index | guest address | host side |
|---|---|---|---|
| `nixos` | 1-254 | `10.233.<index>.2` on veth `ve-<name>` | `10.233.0.1` on every veth (point-to-point /32 routes) |
| `podman` | 1-154 | `10.89.250.<100+index>` (static `--ip`) on the shared `fleet-noinet` bridge | `10.89.250.1`, the bridge gateway |

The address is the same on every host, so a move changes nothing. Podman
static IPs start at .101 to stay clear of the gateway and of podman's dynamic
IPAM, which hands out .2 upward. A private nixos service name is at most 11
characters (the veth is `ve-<name>`), and it may not set `tcpPorts`/`udpPorts`:
declare tcp/udp routes, which get DNAT.

**Guest side.** A nixos guest gets `privateNetwork`, resolves through the
host's resolved stub on `10.233.0.1:53` (the same split-horizon answers as the
host), and keeps its own firewall on, admitting only its route ports. Its
`container.nix` binds `fleetNet.bindAddress` (`0.0.0.0` when private,
`127.0.0.1` otherwise). Postgres and other internal daemons stay on the
guest's own loopback.

**Veth up before the guest boots.** nixos-containers only configures
`ve-<name>` after the guest is ready, which stalls guest units that need the
network at boot. A udev rule starts `fleet-veth@ve-<name>` the moment nspawn
creates the veth; it reads `/etc/nixos-containers/<name>.conf` and sets
`10.233.0.1/32` plus the guest's /32 route. No networkd is needed (dhcpcd
denies `ve-*`; NetworkManager hosts mark `ve-*` unmanaged). The container's
own postStart does the same idempotently, so a host without the hook still
works, late. Its journal is the evidence when a guest has no network.

**Host side** (`privateNetwork.enable`; tables `inet fleet-net` and
`ip fleet-net-nat`, templates in `flakes/fleet-agent/internal/containers/`):

- `ve-*` is not trusted. A guest may reach the host only for DNS on
  `10.233.0.1:53` and its declared `net.uses`/`net.egress`; host loopback
  services are unreachable. No IPv6 to the host or out.
- No guest reaches another guest directly, nor LAN, tailnet, link-local or
  other private ranges, beyond its declared exceptions. Traffic routed *to* a
  guest (a LAN or tailnet host using this host as next hop) is dropped unless
  it is a DNATed route, a reply, or a declared `net.uses`/`net.egress` flow,
  so nothing bypasses the nginx ACLs.
- NAT: `10.233.0.0/16` is masqueraded out of every non-`ve` interface.
  tcp/udp routes are `dnat <proto> <port> <guest ip>` lines in the ports
  file, loaded into the `fleet-net-nat` maps after every firewall reload;
  prerouting and output DNAT local-destination traffic on that port to the
  guest. Public routes match on any interface, `lan` routes only from the
  host's LAN subnets (and tailnet peers), tailnet routes only from real
  tailnet peers: arriving on `tailscale0` from `100.64.0.0/10` and not the
  edge (o002), or a declared local `net.uses` caller. DNAT never applies to
  packets from a guest interface (`ve-*`, `podman*`, `fleet-noinet`), so one
  container cannot reach another through a route on the host's bridge
  address. DNAT ports never touch `temp-ports` and do not show in `ss`.
- **Local-user guard.** On the host itself only root and nginx may open new
  connections to `10.233.0.0/16` and `10.89.250.0/24` (replies and
  established flows pass), so a local user cannot curl a guest past nginx.
  Backups, health checks and the output DNAT all run as root.
- The ports-file lines `guest <ve>`, `noinet <ve>` and `allow …` fill the
  `@guests`, `@noinet` and `@egress` sets; every set is flushed and refilled
  on each run, so a redeploy or a removed ports file drops stale entries.
  Malformed lines are skipped (fail closed).

**No internet.** `internet = false` blocks every new outbound connection
beyond the declared exceptions; published ports and routes still work. A
nixos service needs `net.private` for it: the ports file carries
`noinet ve-<name>`, the host drops new forwarded connections from that veth,
and DNS on the host stays allowed. A podman service joins `fleet-noinet`,
whose `inet fleet-noinet` table drops every new connection from the bridge;
it gets DNS only with `net.uses`. `cnt online <svc> [--for 30m] [--off]`
lifts that for an `internet = false` podman service for a while (the
container IP goes into `@online` with a timeout; a restart or firewall reload
also ends it). A private podman service must set `internet = false` (the
eval throws otherwise): the bridge has no internet path, so its exceptions
and `cnt online` are its only ways out.

**Exceptions.**

- `uses = [ "<svc>.<route>" ]` reaches another service's route, both ways.
  The caller's egress allows the callee's nginx: `10.233.0.1`/`10.89.250.1`
  and this host's overlay IP on 80/443 when the callee is on the same host
  (split DNS answers with the host's overlay IP), else the callee host's
  overlay IP; a tcp/udp route goes to its DNAT port. The callee admits the
  caller in its vhost (the caller's guest IP on the same host, else the
  caller host's overlay IP, since cross-host packets leave masqueraded) and in
  its ports file (`web` lines for every host discovery finds the caller on;
  `cnt deploy`, `move` and `destroy` refresh the callees' ports files, ports
  only). Public routes need no `uses`.
- `egress = [ "10.12.14.181:9010/tcp" ]` allows one fixed LAN/tailnet
  endpoint.
- Both are ports-file `allow <guest> <ipv4> <proto> <port>` lines. `<guest>`
  is `ve-<name>` for nixos and the static `10.89.250.x` IP for podman, whose
  services share one bridge and are told apart by source address; the podman
  lines fill `fleet-noinet @allow` and `nixos-fw @podman-egress` (plus the
  fleet-net/nat `*_src` sets where `privateNetwork` is on), so they work on a
  host without `privateNetwork` too. A podman `net.uses` also opens the
  bridge's aardvark DNS on `10.89.250.1:53` so route names resolve.

**Audit.** A private service's route ports belong to the guest, so a host
listener on one, loopback included, is `STALE` in `cnt audit` (an old
host-network instance or a port leak), unless a host-network service on the
same host declares that port too.

**Moving a service onto the private network:** set `net`, bind
`fleetNet.bindAddress` in `container.nix`, `cnt deploy`. The container
restarts on the veth, vhost and ports file switch to the guest IP, and the old
host port goes away with the old instance. A caller of a tailnet/lan route
needs `uses` before it goes private (nginx then sees its guest IP), and the
callee has to be deployed first so its ACL admits that IP. Rollback: drop
`net` and redeploy. Check with the route through edge and tailnet, `ss` on
the host, `cnt audit`, egress from the guest, and a refused
`curl 10.233.0.1:<loopback port>`.

The podman default bridge `podman0` (a non-private podman service with
internet) gets the same guest-in/forward isolation: internet and published
ports only.

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
  net = { private = true; index = 3; };  # see Private networking; omit for the host network
  internet = true;              # false: no outbound connections beyond net.uses/net.egress
  tcpPorts = [ ];               # host-network only: opened in the host firewall (raw ports)
  udpPorts = [ ];
  routes.web = {
    port = 8888;
    exposure = "tailnet";
    auth = "native";
  };
  secrets = [ ];                # file names under fleet.global.secretsDir
  backup.hooks.pre = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";
  attach = null;                # command for `containers attach`
  requires = [ ];               # host capabilities, e.g. [ "nfs-h004" "intel-qsv" ]
}
```

`service.nix` describes the service, never where it runs. The first
`sudo fleet containers deploy <name> --host <h>` places it; after that the
registry knows the host and plain `cnt deploy <name>` follows it.

Public native-auth routes can declare `loginPaths = [ "/api/auth/login" ];`:
o002 adds a 6 requests/minute per-IP login zone (burst 5, HTTP 429), retains
the global zone, and logs failures for service-specific fail2ban jails.
Vaultwarden, Immich and Jellyfin are wired; Jellyfin belongs to the `arr` jail.
The login log is created/repaired by tmpfiles as `nginx:nginx 0640` before
nginx and fail2ban start. All o002 receiver config tests run as nginx, not root;
the file-backed login jails use polling. Expected jails: `fleet-login-arr`
(Jellyfin), `fleet-login-immich`, `fleet-login-vaultwarden`, plus `sshd`.
`secrets` lists hydrated secret file names (not paths). Deploy/move check every
file on the target before installing/stopping anything; missing grants refuse
the operation. Nix also rejects undeclared hydrated-secret bind mounts.

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
        # specialArgs = { ... };  privateUsers = "pick";
        # guestNixpkgs = <26.05 nixpkgs>;  guest only; host-side eval stays 25.11
        # binds = [ { host = "/nfs/x"; container = "/media"; } ];  not backed up
        # devices = [ "/dev/dri" ];  capabilities = [ "CAP_NET_ADMIN" ];
      };
    };
  });
```

With `net.private` the guest has its own network namespace (see
[Private networking](#private-networking)): services bind
`fleetNet.bindAddress` (`0.0.0.0`) and the guest firewall admits only the
route ports. Without it the container shares the host network: services bind
`127.0.0.1` (only `0.0.0.0` for raw ports in `tcpPorts`) and the guest
firewall is disabled, since the host firewall is what counts. Either way the
host nginx fronts HTTP. Guest-side timers and services work normally.
Host-side units cannot be defined from here; that is what `containers` and
the host module do.

**podman kind**: see `examples/whoami/`. `podman.image`, `ports`
(`"hostPort:containerPort"` binds 127.0.0.1; prefix an address for others),
`environment`, `extraArgs`, `cmd`. With `net.private` the container runs on
the `fleet-noinet` bridge at its static IP and nginx proxies there.

Notes:

- Every persist key is created empty (root-owned, 0755) on first deploy. The
  guest's own tmpfiles/StateDirectory fixes ownership inside the namespace.
  Never `chown` them on the host to a host user.
- Secrets: put them in a persist dir (generated on first boot, as minecraft
  does) or copy them in once with `nixos-container run`.

## LLM router

OMP's per-computer `~/.omp/agent/models.yml` can use
`https://llm.joshuabell.xyz/v1` with provider ID `litellm`. LiteLLM model IDs
are prefixed with their configured upstream name; update saved model selections
if an upstream is renamed. Nix no longer manages OMP's `models.yml`,
`config.yml`, or `mcp.json`; edit them locally on each computer. On the first
switch, the previous Home Manager-managed model catalog and MCP config are
copied into writable files; existing local files are left untouched.
The host flakes pin the shared OMP module: after pushing its change, run
`nix flake update omp-flake --flake ./hosts/<host>` before deploying each host.
Shared shell LLM utilities use `https://llm.joshuabell.xyz` and append `/v1`
themselves. The `lio` CLI aliases bypass proxies for `llm.joshuabell.xyz`.

Shell utilities (`llm_chat`, `gcpropose`, and tmux AI names) share the tier
defaults in `ringofstorms.llm`: `fast` uses `copilot-claude-haiku-5.5` with
`reasoning_effort: low`; `smart` uses `copilot-claude-opus-5.5` with
`reasoning_effort: medium`.

The Open WebUI container still targets the separate legacy `litellm` service
and keeps its existing image model ID; update that setting if moving it to
`llm-router`.

`llm-router/container.nix` declares an array of upstreams. Each entry has a
unique `name`, `type` (`litellm`, `copilot`, or `openrouter`), and either
`base_url` or `base_url_env`, the name of an environment variable holding the
API root. Add another entry with a different name to use a second LiteLLM
server. Public model IDs use `<name>-<model>` for LiteLLM and Copilot and
`<name>/<model>` for OpenRouter. Names are stable client-facing namespaces.
If two upstreams produce the same public model ID, the router excludes that
ID and reports the affected upstreams as errors in `/health`.

Outside Nix, run `llm-router --upstreams upstreams.json`. The file is a JSON
array, for example:

```json
[
  { "name": "first", "type": "litellm", "base_url": "https://first.example/v1", "api_key_env": "FIRST_KEY" },
  { "name": "second", "type": "litellm", "base_url": "https://second.example/v1", "api_key_env": "SECOND_KEY" }
]
```

LiteLLM sends no authorization header unless `api_key_env` is set; OpenRouter
requires it. Copilot uses device login unless `api_key_env` is set.

Before deploying, add `LITELLM_UPSTREAM_URL` and `LITELLM_UPSTREAM_URL_2`
to the existing `litellm-env` secret EnvironmentFile with the upstream API
roots. Both configured LiteLLM upstreams are unauthenticated, so omit
`api_key_env` for them. If an upstream needs a key, set `api_key_env` to the
name of a variable in the EnvironmentFile, not the key itself. OpenRouter uses
`OPENROUTER_API_KEY`; Copilot uses its device-login token. Add any additional
LAN destinations to `llm-router/service.nix`'s `net.egress`.

Discovery exposes one entry per public model ID, not per upstream deployment.
Requests use the upstream's shared model name, and the upstream chooses its
deployment. Duplicate deployment metadata uses the lowest token limits,
common capability flags/parameter sets, and highest published costs. Unknown
limits stay unknown. `/model/info` serializes that common parameter set
directly; missing or disjoint deployment parameter lists produce `[]`, not
inferred defaults. Lists, individual model lookup and health counts use the
same grouped catalog.

### Dependency updates

`llm-router/src` uses only the Go standard library. The deployed binary is
built with Go 1.27.4, pinned in `llm-router/container.nix` with the official
source hash; `src/go.mod` requires that release. Remove the patch override
once the guest's nixpkgs supplies an equal or newer security release.

Update `guestpkgs` in `llm-router/flake.lock` for supported NixOS 26.05
runtime packages and CA certificates. Keep the separate host-side nixpkgs
pin on 25.11 for extra-container compatibility (issue #40); this evaluator
does not choose the router's Go compiler or the host OS running the container.
Build the container, run the Go tests with the selected compiler, and scan
the built binary with `govulncheck -mode=binary` before deploying it with
`fleet containers deploy llm-router --host h001 --rev <full-revision>`.

## Nightly restic (fleet-backup)

### Architecture and current coverage

`ringofstorms.containers.backup.enable = true` enables the **client** tier:
`fleet-backup.service` runs at `backup.schedule` (03:00 by default, persistent,
up to 15 minutes random delay). The client runs on h001, h003 and lio; h005
uses the same client for its `fleet-edge` host subject. Joe is not enabled.
There is no shared client B2 key, shared repository or client-side prune.

A **subject** is one floating service or one named host-data set. Every subject
has its own `svc-<name>` repository and credentials. The current target is
h004: clients write to `rest:http://100.64.0.17:8000/svc-<name>/`, stored as
`/data/backups/svc-<name>`. rest-server's private-repository login restricts
each client credential to its own path; append-only access refuses snapshot
and repository-key deletion. It does not prevent a client writing bad data,
consuming space, or reading data it already has credentials for. h004 runs
no containers and owns local retention. Its root can read held repositories.

h004's `/data/backups` is a dedicated bcachefs subvolume, kept `0700` and
owned by `restic:restic` while the target is enabled, separate from the NFS
export root. Only `svc-*` repositories and the `.htpasswd` stub belong there;
unexpected entries keep rest-server down. The archive migration moved the
old `l001`/`o001` rsync trees to `/data/rsync-archive`, **not** into subject
repositories. Retain those archives when resolving the guard; do not delete
them or treat `latest` as a new backup tier. See the [h004 archive inventory](INVENTORY.md#h004-nas-data-and-older-host-archives).

Only h004's **pusher** holds its new B2 application key, scoped to `svc-` in
the backup bucket. For offsite-enabled subjects it copies the B2 retention
set from the local repository into a separate B2 `svc-<name>/` repository,
then prunes, measures and checks that copy. Local and B2 repositories use
the same per-subject restic password. There is no cross-subject deduplication;
an empty offsite repository requires a full first upload.

**Status recorded 2026-11-13:** all 16 enabled B2 subjects, including Immich
and Minecraft, passed retention-set completeness and sampled-read checks;
the follow-on job ended successfully at 15:26 CST. An `offsite` policy flag
alone is intent, not completed coverage, and a successful check covers only
the retention set at its own `checkedAt` time, not a full restore.

- `h001-archives` (`/home/luser/backups`) is deliberately h004-only, accepted
  2026-11-12. Originals remain on h001; legacy B2 history remains until the
  separate legacy-deletion gate. Losing both h001 and h004 afterwards loses
  those archives.
- `litellm`, `llm-router`, `searx`, `hello-nixos` and `hello-podman` declare
  `backup.enable = false` by the user's disposable-data decision on
  2026-11-13. That does not delete existing snapshots. The backup-driven
  `cnt move` path is unavailable for disabled subjects; deliberately redeploy
  disposable services rather than assuming a restore-based move will work.
- Joe/LocalAI has no reported h004 repository and is not enrolled as a backup
  client. A low-trust client can only be admitted explicitly to its own
  append-only repositories; it can never be a target/pusher. h004's
  `ringofstorms.backup.target.lowTrustClients` alone is insufficient: the
  Headscale ACL in `hosts/oracle/o002/headscale.nix` currently denies
  low-trust outbound access. Admission needs a reviewed, narrow Joe-source
  rule for h004:8000 and the required h005/auth endpoints, not a broad
  low-trust → trusted-network allow. No such network change is made here.
  Joe is confirmed tagged `lowtrust` in Headscale. h005's firewall also drops
  low-trust HTTPS, and Joe does not accept tailnet DNS; enrollment needs an
  intentional h005 API exception plus hostname resolution preserving TLS,
  not only the h004 storage rule.
  Preserve custom models, hand-edited YAML and voice packs when deciding
  coverage: no blanket `models`/`backends` exclusion has been approved.
  Low-trust history is marked by `writtenBy: low` in backup metadata and shown
  in the CLI and both backup views. It is a conservative possible-origin
  warning, not a claim that every snapshot was written on Joe; an absent
  marker means unknown, never verified high trust. The marker persists across
  moves, rollbacks, retirement, clears and unavailable measurements. The target
  keeps `written-by.json` separately from `stats.json`, so history never
  invents a held repository, size or fresh measurement. It cannot waive the
  user's trust decision for a restore onto a high-trust host.
- Container backup enablement does **not** cover workstation homes, arbitrary
  bind mounts or whole host disks. The [dated inventory](INVENTORY.md) records
  known originals, archives and copies without authorizing deletion.

### Subject declarations and consistent data

Service backup configuration is plain data in `service.nix`:

```nix
backup = {
  enable = true;                  # default; false must be the only field
  exclude = [ "cache" ];          # patterns relative to /srv/containers/<svc>
  # hooks.pre / hooks.post are optional guest shell commands; see the dump example above.
  extraPaths = [ {
    path = "/srv/bulk/example/media";
    requires = "bulk";            # must also be in the service's requires
    exclude = [ "thumbnails" ];   # relative to this extra path
    sentinel = "/srv/bulk/example/media/.present"; # optional regular file
    # mount = "/srv/bulk";        # optional exact mountpoint check
  } ];
};
```

`backup.hooks.pre` replaces the obsolete `backupHook` field. Hooks, if used,
must be non-empty command strings. Extra paths are explicit local source
paths: they must exist, must not be NFS/CIFS/SSHFS/autofs/9p-backed, and must
pass their declared mount/sentinel checks. Do not back up the NAS through a
client's mount; back up data on its owning host. Names/paths/excludes are
validated, unsafe roots and hydrated-secret trees are rejected, and declared
source paths may not overlap across subjects. Excludes are non-empty relative
patterns without `..`.

Non-container data uses `ringofstorms.backup.subjects.<name> = { paths =
[ "/absolute/local/path" ]; exclude = [ "relative-pattern" ]; hooks = {
pre = "host command"; post = "host command"; }; };`. Paths must be non-empty,
and the subject name may not collide with a container. Host hooks run as root
on the host. Declaring a host subject enables the client by default; register
its host ownership in h005's `backup.hostSubjects` so the machine-token API
can authorize it. Host subjects do **not** get automatic SQLite copies:
write a pre-hook online backup, include the copy and exclude the live DB and
its WAL/SHM. h005's `fleet-edge` subject does this for `metrics.db` and also
includes its placement, policy, credential, metrics and forward state.

For installed, enabled services the nightly client runs pre-hooks if active,
makes owner/mode-preserving SQLite `.backup` copies under
`/var/lib/fleet-backup/staging/<svc>/sqlite/<svc>/…`, and backs up the service
root, staging copies and declared extra paths with tags `fleet` and
`svc:<name>`. Live SQLite files/sidecars and raw PostgreSQL clusters are
excluded; PostgreSQL dumps are the snapshot recovery source. A stopped
service's hook is skipped, so check the age of its existing dump. Dotted
`.moved-*`/`.retired-*` roots and uninstalled data are not nightly subjects.
Staging copies beside live data are not another backup tier.

Immich includes `/srv/bulk/immich/media` (excluding `thumbs` and
`encoded-video`, with `upload/.immich` sentinel); Paperless includes its media
(excluding `documents/thumbnails`, with `media.lock` sentinel) and consume
queue. The snapshot does not include everything under `/srv/bulk`, and
`svc-arr` does not include h004's `/data/nixarr` media library.

On success a container host writes
`/var/lib/fleet-containers/backup-last/<subject>` with `time`, `snapshot`,
`host`, `target` and `repo`. Non-container clients default to
`/var/lib/fleet-backup/backup-last`. fleet-agent reports the stamp as
`lastBackup`; fleet-edge flags container backup age stale after 36 hours.
One flock per subject serializes nightly and move backups. A success stamp
is local-target backup evidence, not an offsite completion claim.

### Credentials, policy and retention

h005 fleet-edge generates subject credentials on first need. A client uses
its root-only machine key to obtain a Zitadel machine token for
`/api/backup/<subject>/credentials`; it is authorized only while placement
binds that service to the host, while the host is the reserved move
destination, or for an explicitly registered host subject. REST username is
`svc-<name>`; the repository password and HTTP password are separate values.
Target logins/held repo keys are delivered separately to the target.

`fleet containers backup-creds <subject>` caches credentials root-only under
`/var/lib/fleet-backup/creds/<subject>.env`. Target resolution caches policy
under `/var/lib/fleet-backup/target.json`. An unreachable API may use cached
state; no usable cache means failure, never a guessed repository. A credential
403 or 404 removes that subject's cache. Move preflights require a **fresh** fetch.
Do not print credential files, put passwords in repository URLs or commit
them. `RESTIC_REPOSITORY` needs the `rest:` prefix, with no userinfo.

Use the authenticated h005 `/backup/?tab=credentials` UI to export all subject credentials
to the password manager outside the fleet; newly generated passwords make
the export banner stale. Export UI state is not confirmation that an external
copy has been saved. Import restores missing credentials after h005 recovery;
differing existing values need an explicit overwrite choice. REST-password
rotation (UI or `backup-policy rotate`) revokes HTTP access once targets have
applied the revision, and moves rotate it on placement commit. It does not
rotate the repository encryption password or revoke already copied plaintext.
The [break-glass runbook](sec/README.md#break-glass-kit-and-cold-restore)
lists the separate application keys and pusher keys needed for recovery.

Policy is runtime state on h005, not per-service Nix placement. Every subject
inherits unset values from `default`:

| Field | Meaning |
|---|---|
| `target` | Enabled, non-stale target ID, or `none` to stop new backups |
| `offsite` | Copy through that target's pusher; rejected for a non-pusher target |
| `retentionLocal` | `short`, `standard` or `long` (default `standard`) |
| `retentionB2` | Same presets, or `local` to follow local retention (default) |

| Preset | Keep daily / weekly / monthly / yearly |
|---|---|
| `short` | 3 / 2 / 1 / none |
| `standard` | 7 / 5 / 12 / 3 |
| `long` | 14 / 8 / 24 / 5 |

Target-side `forget --prune --group-by ""` applies retention per repository,
not per host/path group. Clients never prune. Turning policy off does not
delete a repository or stop target-side retention. The target uses cached
policy and a `long` fallback when a preset is unavailable. The B2 pusher
requires a policy reply no older than 30 minutes, otherwise it copies/clears
nothing. Heartbeats refresh target policy/credentials every 5 minutes;
h004's local prune runs at 06:00 (+ up to 30 minutes), local stats hourly,
and offsite copy at 07:30. See [h004 operations](../hosts/h004/readme.md#backup-target-and-offsite-pusher).

**Clear is deletion, not turn-off.** An authorized writer queues a typed,
audited `local`, `b2` or `both` clear for the target to execute. Local clear
reinitializes an empty repo with the existing subject password only if the
subject still targets that host. B2 clear deletes the subject prefix and
turns off offsite policy; `both` clears local first. Do not use clear to retire
historical archives without a separate deletion decision.

The pusher computes the expected B2 keep-set on the **local** repository,
matches copied snapshots by `(.original // .id)` plus
`time,hostname,paths,tags,tree`, and runs a sampled
`check --read-data-subset` (100M by default). Results are in h004
`/var/lib/fleet-backup-target/offsite-b2.json` as `complete`, `missing`,
`checkedAt`; `b2-stats.json` supplies `lastCopied` and sizes. A sample is not
a full-data restore test. Repository size, process disk reads and copied
pack counts do not prove the required snapshot set is complete.

### Operator commands

Run client commands on the subject's authorized host; `sudo fleet containers`
uses the machine key (`cnt` does not expand under `sudo`).

```sh
sudo systemctl start fleet-backup                     # all local subjects, never prune
sudo systemctl start fleet-backup-svc@puzzles         # one subject
sudo fleet containers backup-resolve puzzles         # target/repo, not credentials
sudo fleet containers backup-creds puzzles           # cache file path, not key contents
sudo fleet-restic --subject puzzles snapshots --tag svc:puzzles
sudo fleet-restic --subject puzzles restore latest --tag svc:puzzles --target /tmp/puzzles-restore
sudo fleet containers restore-check puzzles          # restored SQLite + PG dump checks
```

Policy reads/writes use a configured writer's machine key (not an arbitrary
subject client). Supported forms are:

```sh
sudo fleet containers backup-policy list
sudo fleet containers backup-policy set puzzles target=h004 offsite=true local=standard b2=local
sudo fleet containers backup-policy rotate puzzles
# Destructive example, not a health check: prompts for "clear svc-puzzles b2".
sudo fleet containers backup-policy clear puzzles b2
```

New local repositories require an explicit init as `restic` after the target
has received the subject password; no `backup-init` CLI exists. **[INFERENCE]**
The following transient unit mirrors the module's `LoadCredential` pattern;
it has not been executed as part of this docs cleanup. The held key is an env
file containing `RESTIC_PASSWORD=…`, not a bare `--password-file` value.

```sh
# On h004, only for a deliberately provisioned new subject with no existing repo.
restic_bin=$(command -v restic) || exit 1
sudo systemd-run --wait --collect --uid=restic --gid=restic \
  -p PrivateTmp=yes -p RequiresMountsFor=/data -p ConditionPathIsMountPoint=/data \
  -p LoadCredential=repo:/var/lib/fleet-backup-target-keys/repo-keys/svc-NEW_SUBJECT \
  /bin/sh -eu -c 'umask 077; . "$CREDENTIALS_DIRECTORY/repo"; export RESTIC_PASSWORD; exec "$1" -r "$2" init' \
  init "$restic_bin" /data/backups/svc-NEW_SUBJECT
```

Do not reinitialize an existing repo or treat a policy row as a stored backup.
Existing history can be seeded by an explicit `restic copy`; copying chunker
parameters when initializing helps future deduplication but does not copy
history. The pusher initializes missing B2 destinations from the local repo's
chunker parameters. Local clear is the only automatic local reinitialization,
and only for a subject that still targets that host.

`fleet-restic --subject <name> [-r <rest:http(s)://…>] <restic args>` requires
the subject and accepts only REST repositories; pass wrapper flags **before**
the restic subcommand. It resolves the subject's target unless `-r` is given,
but still fetches/caches credentials from h005. It is not a general B2 wrapper
or an API-independent disaster path. Scratch restores contain staged SQLite
copies rather than replacing live files; explicitly overlay copies from the
**restored snapshot**, not live-host staging, before running the app.

### Remaining coverage and legacy retirement

The obsolete direct-B2 proposal has been folded into this runbook. Remaining
coverage decisions are not implied by container enablement:

- Lio's `/home/josh` and `/mnt/nvme1tb` need an explicitly inventoried host
  subject before an impermanence re-image. Candidate irreplaceable paths
  from the old notes are `Documents`, `projects`, `Pictures`, `Desktop`,
  `.ssh`, `.gnupg` and `.config/nixos-config` under `/home/josh`, plus selected
  critical `/mnt/nvme1tb` paths. Review regenerable caches, build outputs,
  `node_modules`, `.direnv`, `.venv`, Steam/OCI caches and Trash for exclusions;
  do not assume all Downloads, VM images or ISO files are disposable.
- O002's Headscale state under `/persist/var/lib/headscale` needs an off-host
  subject and a SQLite online-copy hook. Persistence alone is not a backup.
- Life still declares internal restic and pgBackRest jobs in addition to
  `svc-life`; their independent destination and health have not been verified
  here. Preserve them until their recovery role is established.
- Fleet-edge implements minute-polled, deduplicated alerts for placed-service
  health, missing/stale backup stamps and certificate expiry. Push delivery
  is not configured (`alerts.ntfyUrl` is empty), and no backup `OnFailure`
  or external dead-man configuration was found. That monitor does not cover
  generic host subjects or pusher completeness; a dashboard age warning is
  not an active recovery/notification guarantee.

**P6 is retirement of future legacy writes and the shared credential; P6b
is deletion of legacy B2 history.** On 2026-11-13 h001 was switched: legacy
`restic-backups-h001` timer/service are absent and inactive, and
`fleet-backup.timer` is active. Sec's old-secret active registry fields/grants
and hydrated copies on h001/h003 were removed; two encrypted historical
tombstone versions remain in Sec. No hydrated copy was found on h004, h005
or o002. Lio still has its root-only old file (sudo unavailable during the
survey); juni, oren and gp3 were unreachable over SSH. Clean those hosts
with administrator access and revoke the old B2 key through the user's
Backblaze account; no account-admin credential is available to automate it.
P6 is not fully closed. The user confirmed password-manager
saves of the old `restic_h001_env` and new `restic_b2_h004` entries on
2026-11-13; the latest fleet-edge subject-password export is still essential
and is not included in either env entry. The seven-day wait was waived on
2026-11-13; legacy deletion is still deferred until B2-only recovery and the
requested h001 → h003 restore/move proof. Preserve a restricted recovery key,
password and safely identified legacy URL until deletion is authorized.
`7f023d4a` is a repository label, **not a verified object prefix**. Pre-cutover
media/history is not automatically equivalent to new snapshots, and no
archive deletion is authorized by this documentation cleanup. The temporary
[closeout checklist](BACKUP-PLAN.md) remains while these pending gates need
tracking; this runbook and the dated inventory preserve the enduring context.

## Backup

```sh
containers backup minecraft            # asks: directory [~/backups], stop it? [y/N]
containers backup minecraft -y -o /mnt/nas/   # no questions (scripts, cron)
```

The archive is `/srv/containers/<svc>` with numeric owners, xattrs and ACLs,
taken while the service is stopped (after `backup.hooks.pre`, e.g. a SQL dump).
It restores on any host.

If the service is running, `backup` asks before stopping it (it is started
again afterwards); answering no cancels, `--live` copies without stopping.
If it is already stopped it is backed up as is, without asking, and its
pre-hook is skipped (it needs the service running). Without a terminal
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

`restore` targets the host the registry binds the service to; `--host` is
needed only for an unplaced service or to restore somewhere else on purpose.
It refuses while the service runs there. `--force` renames the existing data
to `<dir>.pre-restore-<epoch>` rather than deleting it. By hand: stop, move
`/srv/containers/<svc>` aside,
`sudo tar --numeric-owner -xpf backup.tar.gz -C /srv/containers`, start.

The archive command covers the service root, **not** `backup.extraPaths`.
Recover separately declared media paths with the implemented extra-path flow:

```sh
# Run where the subject is placed (h001 here); a move destination needs a live reservation.
sudo fleet containers restore immich --extra all --host h001 --into /srv/recovery/immich
sudo fleet containers restore-check immich --host h001 --snapshot SNAPSHOT_ID --repo rest:http://100.64.0.17:8000/svc-immich/
```

`restore --extra all|/configured/path` defaults to the latest subject snapshot;
use `--snapshot ID` and optional `--repo rest:http(s)://…` to pin a source.
`--host` names the destination executing the restore. `--into /absolute/scratch`
maps an extra path to `<scratch>/<absolute/source/path>` (for example,
`/srv/recovery/immich/srv/bulk/immich/media`). It disables the preexisting-data
guard but sync still deletes files absent from the snapshot: use a dedicated
scratch tree, never an important populated directory. Without `--into`, a
destination must be absent, empty, or carry `.cnt-sync-<svc>`; symlink and
non-directory destinations are refused. The sync preserves declared excludes
and its marker, and restores source-directory metadata.
Place REST `--repo` **after the subcommand**: global `--repo` before the command
selects the flake source instead. The current CLI has no ordinary
`restore <svc> --latest`, no non-extra snapshot-restore handler and no
cross-target newest-snapshot search. Use a plain restic scratch restore for
the service root, preserving numeric ownership, and overlay staged SQLite
copies before transferring recovered state to its live path.

### B2-only recovery, independent of h005/h004

On an isolated recovery host, recover the subject password and bucket key
from the password manager into root-only files without displaying contents.
Use plain `restic`, not the REST-only `fleet-restic` wrapper. For example,
with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` already supplied securely
to the recovery process and the subject password in `/run/keys/subject-password`:

```sh
sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY restic \
  -r s3:https://s3.us-west-002.backblazeb2.com/belljm-LoiuasdV3-system-backups/svc-sec \
  --password-file /run/keys/subject-password snapshots --tag svc:sec
sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY restic \
  -r s3:https://s3.us-west-002.backblazeb2.com/belljm-LoiuasdV3-system-backups/svc-sec \
  --password-file /run/keys/subject-password restore SNAPSHOT_ID --target /srv/recovery/sec
```

These commands do not read the source host, h004 or the fleet-edge API. Choose
and record a real snapshot ID from the listing; only the subject's actual
checked retention set is promised by a completion record. Do not restore
straight over live data. For Sec, explicitly copy the recovered snapshot's
`var/lib/fleet-backup/staging/sec/sqlite/sec/data/sec.db` over its recovered
`srv/containers/sec/data/sec.db`, preserving owner/mode, and retain `db.key`.

**PostgreSQL is not imported automatically.** The restic snapshot contains
dumps, not the excluded raw cluster. A disaster restore must prepare a clean,
compatible PostgreSQL recovery environment, resolve module-created
roles/databases versus dump contents, and import the dump before starting
the application. `pg_dumpall` SQL (including Zitadel's
`pgdumps/cnt-dumpall.sql.gz`) loads with `psql`; a custom-format `PGDMP` dump
uses `pg_restore`. There is no turnkey PostgreSQL cold-import command in
this CLI. `restore-check` checks SQLite integrity and PG dump completeness;
it does not load PostgreSQL or prove a working application. Verify an actual
login/data read after recovery, and apply the user's trust decision before
running any snapshot written by a low-trust host.

For h005 disaster recovery, the `fleet-edge` subject includes credentials
and policy, so the off-fleet export must bootstrap access. Restore into
scratch with plain restic, stop the affected fleet-edge units, recover their
state directories, and copy the snapshot's
`var/backup/fleet-edge/metrics-online.db` over the recovered `metrics.db`
before starting the metrics service. Preserve DynamicUser state ownership
semantics; do not treat the excluded live SQLite file as the backup.


## Moving a service to another host

Data goes through the **subject's** restic repository, so a service keeps its
`svc:<name>` history across hosts. The move pins the repository and snapshot
from its fresh final-backup stamp, not a newest-snapshot guess across targets.
Downtime is stop + backup + restore + first boot. Routing follows the
placement registry, so nothing in Nix is edited and no host is rebuilt.
A move tests restoration from the local backup target, not B2-only disaster
recovery; it also needs the surviving source for raw PostgreSQL clusters.

1. Both hosts have `ringofstorms.containers.backup` enabled, the subject has
   backups enabled and resolves to a target (not `none`), and the destination
   can freshly fetch its subject credentials after reservation. The target
   passes `containers check-idmap <target>` and offers the service's
   `requires` capabilities. Declared extra paths must be local and absent,
   empty, or carry `.cnt-sync-<svc>` from a prior extra-path restore/sync.
   There is no standalone `cnt sync` command; move and `restore --extra`
   provide this synchronization.
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
      Extra paths are pre-synced from the latest subject snapshot while the
      source keeps serving; the final stopped-source snapshot supplies the
      delta sync in the restore step.
   3. **final backup** on the source: `backup.hooks.pre`, blocking stop,
      `fleet-backup-svc@<svc>`; the snapshot ID and repository come from the
      fresh stamp (an old stamp is never accepted).
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
   Synced extra-path data is kept on rollback. Sync markers are removed if
   failure precedes the restore step, and retained once that step starts,
   allowing a deliberate retry without treating partial media as live data.

   **Why commit comes before retire.** The switch renames the source's data,
   after which routing can no longer just point back at it. So the commit
   lands only once the destination has proven it serves the data (health,
   restore check, first backup), and the source is retired and uninstalled
   only once routing has moved off it. A commit that fails takes the same undo
   path as any earlier failure, so no reservation is left behind; after the
   commit only an operator rolls back (`cnt place <svc> --recover`). A retire
   that hits a takeover stops before the switch; any other retire failure is
   a warning and the move finishes, since the destination is already live and
   the registry's sweep settles the source. A move renews its 30-minute lease
   between steps; one that dies without renewing is fenced as `stale`, never
   rolled back, because its source may already be stopped.
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
practice archive backup/restore. `cnt place` shows where each is bound.
Both services deliberately disable nightly backups, so `cnt move` is not
available for them in the current configuration; redeploy their disposable
state, or explicitly change backup policy/declarations before a restore-based
move exercise.

```sh
cnt deploy hello-nixos && cnt deploy hello-podman
curl http://<host>:8081/ http://<host>:8082/
cnt status hello-podman
cnt stop hello-nixos            # stays down after a reboot
cnt backup hello-podman
cnt destroy hello-podman --purge
```
