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
| `containers move <svc> --to h` | final restic backup on the source, restore on the target, deploy + route health, restore check, first backup on the target, then commit the move to the placement registry and retire the source. A failure before the commit undoes the target, drops the reservation and restarts the source |
| `containers restore-check <svc> [--snapshot ID]` | restore a `svc:<svc>` snapshot to a scratch dir on its host: SQLite `integrity_check`, PG dumps complete |
| `containers health <svc>` | every route answers on its host (backend and nginx) |
| `containers destroy <svc>` | uninstall (data kept; `--purge` deletes it). `--host` on a host the registry does not bind removes that stray copy and leaves the row; the bound copy, or a row a move still holds, needs `--force` (the bound copy's row is then removed, revision-guarded) |
| `containers check-idmap <host>` | the idmap test above |
| `containers routes [svc]` | declared routes from the inventory: fqdn, proto, port, exposure, auth, via, and the registry-bound host (`-` when unplaced) |
| `containers audit [host...] [--stdin]` | read-only: runs `ss -ltnupH` on each host (default: all container hosts) and lists every non-loopback listener as `declared` (a route, `tcpPorts`/`udpPorts` of a service the registry binds to that host), `host` (small allowlist in `flakes/fleet-agent/internal/containers/routes.go`: 22, 80, 443, 8443, 53, tailscale 41641/udp, dhcp, mdns; plus host daemons the host module declares in `/etc/fleet-containers/host-listeners`, e.g. the status endpoint at its configured address; plus, matched by process name rather than port, tailscaled's dynamic sockets on tailnet/wildcard addresses and systemd-resolved LLMNR on 5355) or `UNDECLARED` (incl. ports of `exposure = "local"` routes, and `proto = "http"` backend ports found on a non-loopback address — those must stay on `127.0.0.1`, nginx is the only thing allowed to expose them). Needs root on the remote host to see process names; non-root users get `sudo -n` (fails fast instead of hanging if it needs a password). If sudo there needs a password, plain ssh can't prompt (no TTY): run it on the host itself and feed the file in with `--stdin` (exactly one host): `sudo ss -ltnupH > /tmp/<host>.ss && cnt audit <host> --stdin < /tmp/<host>.ss`, or collect the file with `ssh -t`. Empty `--stdin` input (or input with no listeners) is an error, so a failed collection never looks like a clean host. With a machine key it also prints `== routing (h005)`: fleet-edge's comparison of the DNS, edge vhost, TCP stream and WAN forward layers against the registry (diagnostic only; omitted without a key). Otherwise exits 0 |
| `containers port open <svc> <port>/<tcp\|udp> --for <dur> [--from <host\|cidr>]... [--iface tailnet\|lan\|any] [--host h]` | open a port temporarily (see [Temporary ports](#temporary-ports-cnt-port)) |
| `containers port ls [host...]` / `port close <svc> <port>/<proto> [--from ...] [--iface ...]` | list / close them early |
| `containers expose <svc>[.<route>] --exposure tailnet\|lan\|public --for DUR\|forever [--reason T]` | widen one http route on its host for a while. tailnet/lan: `--for` required, max 24h; the host reverts it at expiry (transient timer, plus `fleet-containers-expose-expire` at boot and every minute). `public`: fleet-edge on h005 adds the public CNAME and pushes an o002 runtime vhost (default 8h, any duration ≥ 1m or `forever`; h005 owns the expiry). Public expose (and `--revoke` of one) signs with this machine's key (`/machine-key.json`, root-only), so run `sudo fleet containers expose ...`: the `cnt` alias does not expand under sudo. `expose --list [host...]` / `expose --revoke <svc>`; `deploy` drops an override; `routes` and `audit` show them |
| `containers expose --reset <svc>` | clear the fleet-edge override API row and every host-local override. A host whose revert still owes the nginx reload is revoked again, which retries the reload; the final re-read counts a pending reload as remaining state. Unreachable hosts or remaining state are reported as errors |

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
- On a `net.private` service a host port would reach nothing (the app is
  in the guest netns), so `open` adds a temporary DNAT from the host port to
  the guest IP instead: an element in a map of `ip cnt-port` (`cnt-fwd`,
  `cnt-fwd4` with `--from`, and `cnt-fwd-any`/`cnt-fwd4-any` for
  `--iface any`; template `flakes/fleet-agent/internal/containers/cnt-port.nft`,
  loaded by the first such open). Same timeout, `svc=<svc>` comment,
  `--iface`/`--from` scoping and fail-closed reload; never from guests, and
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
  with the last one. The kernel expires it, and a guest firewall reload or
  restart empties the set (fail closed). The open refuses a guest that
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
  backupHook = "runuser -u postgres -- pg_dumpall > /var/lib/postgresql/dumpall.sql";
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

## Nightly restic (fleet-backup)

With `ringofstorms.containers.backup.enable = true` and an `environmentFile`
(RESTIC_REPOSITORY, RESTIC_PASSWORD, backend creds; normally a sec-agent
secret wired through `configChanges`), the host runs `fleet-backup.service`
nightly (`backup.schedule`, default 03:00). For every service installed on
that host it runs the `backupHook` (if running), makes SQLite `.backup`
copies, and snapshots `/srv/containers/<svc>` with tags `fleet` and
`svc:<name>`. History and retention follow the tag, not the host, so a
moved service continues its series. Enabled on h001, lio and h003 (one
shared repository); not on joe, so a service there has no nightly snapshot
and `move` refuses it as source or target.

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

`restore` targets the host the registry binds the service to; `--host` is
needed only for an unplaced service or to restore somewhere else on purpose.
It refuses while the service runs there. `--force` renames the existing data
to `<dir>.pre-restore-<epoch>` rather than deleting it. By hand: stop, move
`/srv/containers/<svc>` aside,
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
